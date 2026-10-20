// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {ILiquidityLocks} from "./ILiquidityLocks.sol";

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice The parts of a v3-style position manager (an ERC-721 of positions) that the locker uses.
interface IPositionManager {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function factory() external view returns (address);
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice The pool lookup of a v3-style factory.
interface IPoolFactory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @title LiquidityLocker
/// @notice Reference implementation of the Liquidity Locks draft. Locks v2-style pool tokens (an ERC-20 that is its own
///         pool) and positions of the one v3-style position manager fixed at deployment, whose factory names each
///         position's pool. Per-pool sums and a min-heap of timed locks by unlock time make `lockedLiquidity` three
///         reads, however many locks a pool has. There is no owner, no upgrade, and no way for liquidity to leave other
///         than `releaseLiquidityLock`. v4-style positions are not handled.
/// @dev Not audited. A reference for the interface.
contract LiquidityLocker is ILiquidityLocks, IERC165 {
    uint64 public constant PERMANENT = type(uint64).max;

    struct PoolTotals {
        uint256 permanent;
        uint256 timed;
    }

    /// @notice The only position manager whose positions this locker accepts.
    IPositionManager public immutable positionManager;

    LiquidityLock[] private _locks; // index 0 is a sentinel, so lock ids start at 1
    mapping(address => mapping(bytes32 => uint256[])) private _byPool; // every lock id of a pool, oldest first
    mapping(address => mapping(bytes32 => PoolTotals)) private _totals; // over locks not yet released
    mapping(address => mapping(bytes32 => uint256[])) private _timedHeap; // timed locks held, min-heap on unlockAt
    mapping(uint256 => uint256) private _heapSlot; // lock id => index in its pool's heap plus one; 0 when not in it
    bool private _entered;

    error ZeroAmount();
    error ZeroBeneficiary();
    error ZeroFeeRecipient();
    error ZeroPositionId();
    error UnlockNotLater();
    error UnknownPool();
    error UnknownLock();
    error AlreadyReleased();
    error NotBeneficiary();
    error StillLocked(uint64 unlockAt);
    error ReleaseExceedsLock();
    error NotAPosition();
    error TransferFailed();
    error Reentrant();

    modifier nonReentrant() {
        _enter();
        _;
        _entered = false;
    }

    constructor(address positionManager_) {
        positionManager = IPositionManager(positionManager_);
        _locks.push(); // sentinel
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ILiquidityLocks).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ---------------------------------------------------------------- creating (specific to this locker)

    /// @notice Locks `amount` of a v2-style pool token, taken from the caller, which must have approved this locker.
    ///         The token is its own pool. The lock records what arrived, which differs from `amount` for a token
    ///         that takes a fee on transfer.
    function lockPoolTokens(address poolToken, uint256 amount, uint64 unlockAt, address beneficiary)
        external
        nonReentrant
        returns (uint256 lockId)
    {
        if (amount == 0) revert ZeroAmount();
        _checkTerms(unlockAt, beneficiary);
        uint256 before = IERC20(poolToken).balanceOf(address(this));
        _callToken(poolToken, abi.encodeCall(IERC20.transferFrom, (msg.sender, address(this), amount)));
        uint256 received = IERC20(poolToken).balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();
        lockId = _create(
            LiquidityLock({
                pool: poolToken,
                poolId: bytes32(0),
                position: poolToken,
                positionId: 0,
                amount: received,
                unlockAt: unlockAt,
                beneficiary: beneficiary,
                feeRecipient: address(0)
            })
        );
    }

    /// @notice Locks the caller's position `tokenId` of `positionManager`, which the caller must have approved. The
    ///         pool is the one the manager's factory names for the position's tokens and fee, never one the caller
    ///         names.
    function lockPosition(uint256 tokenId, uint64 unlockAt, address beneficiary, address feeRecipient)
        external
        nonReentrant
        returns (uint256 lockId)
    {
        if (tokenId == 0) revert ZeroPositionId();
        if (feeRecipient == address(0)) revert ZeroFeeRecipient();
        _checkTerms(unlockAt, beneficiary);
        positionManager.transferFrom(msg.sender, address(this), tokenId);
        if (positionManager.ownerOf(tokenId) != address(this)) revert TransferFailed();
        (address pool, uint128 liquidity) = _positionOf(tokenId);
        if (liquidity == 0) revert ZeroAmount();
        lockId = _create(
            LiquidityLock({
                pool: pool,
                poolId: bytes32(0),
                position: address(positionManager),
                positionId: tokenId,
                amount: liquidity,
                unlockAt: unlockAt,
                beneficiary: beneficiary,
                feeRecipient: feeRecipient
            })
        );
    }

    // ---------------------------------------------------------------- ILiquidityLocks: changes

    function extendLiquidityLock(uint256 lockId, uint64 unlockAt) external nonReentrant {
        LiquidityLock storage l = _held(lockId);
        if (msg.sender != l.beneficiary) revert NotBeneficiary();
        if (unlockAt <= l.unlockAt) revert UnlockNotLater();
        // A later time exists, so the lock was timed and sits in its pool's heap.
        uint256[] storage heap = _timedHeap[l.pool][l.poolId];
        l.unlockAt = unlockAt;
        if (unlockAt == PERMANENT) {
            _heapRemove(heap, lockId);
            PoolTotals storage t = _totals[l.pool][l.poolId];
            t.timed -= l.amount;
            t.permanent += l.amount;
        } else {
            _siftDown(heap, _heapSlot[lockId] - 1);
        }
        emit LiquidityLockExtended(lockId, unlockAt);
    }

    function releaseLiquidityLock(uint256 lockId) external nonReentrant {
        LiquidityLock storage l = _held(lockId);
        uint64 unlockAt = l.unlockAt;
        // A lock's time is a block timestamp by definition; a producer's seconds of drift do not matter to it.
        // forge-lint: disable-next-line(block-timestamp)
        if (unlockAt == PERMANENT || block.timestamp < unlockAt) revert StillLocked(unlockAt);
        uint256 amount = l.amount;
        address to = l.beneficiary;
        l.amount = 0;
        _totals[l.pool][l.poolId].timed -= amount;
        _heapRemove(_timedHeap[l.pool][l.poolId], lockId);
        if (l.positionId == 0) {
            // The whole amount goes out; the beneficiary gets what the token delivers. A token that takes more than
            // it sends would take from the other locks of the same token, so such a release reverts.
            uint256 before = IERC20(l.position).balanceOf(address(this));
            _callToken(l.position, abi.encodeCall(IERC20.transfer, (to, amount)));
            if (IERC20(l.position).balanceOf(address(this)) + amount < before) revert ReleaseExceedsLock();
        } else {
            IPositionManager(l.position).transferFrom(address(this), to, l.positionId);
        }
        emit LiquidityLockReleased(lockId, to);
    }

    function collectLiquidityLockFees(uint256 lockId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        LiquidityLock storage l = _held(lockId);
        if (l.positionId == 0) revert NotAPosition(); // a pool token's fees stay in the token
        address to = l.feeRecipient;
        IPositionManager.CollectParams memory params = IPositionManager.CollectParams({
            tokenId: l.positionId, recipient: to, amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        (amount0, amount1) = IPositionManager(l.position).collect(params);
        emit LiquidityLockFeesCollected(lockId, to, amount0, amount1);
    }

    // ---------------------------------------------------------------- ILiquidityLocks: reads

    function getLiquidityLock(uint256 lockId) external view returns (LiquidityLock memory) {
        if (lockId == 0 || lockId >= _locks.length) revert UnknownLock();
        return _locks[lockId];
    }

    function liquidityLocksOfPool(address pool, bytes32 poolId, uint256 start, uint256 limit)
        external
        view
        returns (uint256[] memory out)
    {
        uint256[] storage ids = _byPool[pool][poolId];
        if (start >= ids.length) return new uint256[](0);
        uint256 end = start + limit;
        if (end > ids.length || end < start) end = ids.length;
        out = new uint256[](end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = ids[start + i];
        }
    }

    function lockedLiquidity(address pool, bytes32 poolId)
        external
        view
        returns (uint256 permanent, uint256 timed, uint64 earliestUnlock)
    {
        PoolTotals storage t = _totals[pool][poolId];
        permanent = t.permanent;
        timed = t.timed;
        uint256[] storage heap = _timedHeap[pool][poolId];
        if (heap.length != 0) earliestUnlock = _locks[heap[0]].unlockAt;
    }

    // ---------------------------------------------------------------- internals

    function _create(LiquidityLock memory l) private returns (uint256 lockId) {
        lockId = _locks.length;
        _locks.push(l);
        _byPool[l.pool][l.poolId].push(lockId);
        if (l.unlockAt == PERMANENT) {
            _totals[l.pool][l.poolId].permanent += l.amount;
        } else {
            _totals[l.pool][l.poolId].timed += l.amount;
            uint256[] storage heap = _timedHeap[l.pool][l.poolId];
            heap.push(lockId);
            _heapSlot[lockId] = heap.length;
            _siftUp(heap, heap.length - 1);
        }
        emit LiquidityLockCreated(
            lockId, l.pool, l.poolId, l.position, l.positionId, l.amount, l.unlockAt, l.beneficiary, l.feeRecipient
        );
    }

    function _checkTerms(uint64 unlockAt, address beneficiary) private view {
        // forge-lint: disable-next-line(block-timestamp)
        if (unlockAt <= block.timestamp) revert UnlockNotLater();
        if (beneficiary == address(0)) revert ZeroBeneficiary();
    }

    /// @dev A lock that exists and still holds its liquidity.
    function _held(uint256 lockId) private view returns (LiquidityLock storage l) {
        if (lockId == 0 || lockId >= _locks.length) revert UnknownLock();
        l = _locks[lockId];
        if (l.amount == 0) revert AlreadyReleased();
    }

    function _positionOf(uint256 tokenId) private view returns (address pool, uint128 liquidity) {
        (,, address token0, address token1, uint24 fee,,, uint128 l,,,,) = positionManager.positions(tokenId);
        pool = IPoolFactory(positionManager.factory()).getPool(token0, token1, fee);
        if (pool == address(0)) revert UnknownPool();
        liquidity = l;
    }

    /// @dev Accepts tokens that return true and tokens that return nothing.
    function _callToken(address token, bytes memory data) private {
        if (token.code.length == 0) revert TransferFailed();
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _enter() private {
        if (_entered) revert Reentrant();
        _entered = true;
    }

    // A binary min-heap of lock ids on unlockAt, one per pool: its root is the earliest unlock time.

    function _heapRemove(uint256[] storage heap, uint256 lockId) private {
        uint256 i = _heapSlot[lockId] - 1;
        uint256 last = heap.length - 1;
        delete _heapSlot[lockId];
        if (i != last) {
            uint256 moved = heap[last];
            heap[i] = moved;
            _heapSlot[moved] = i + 1;
            heap.pop();
            _siftDown(heap, i);
            _siftUp(heap, i);
        } else {
            heap.pop();
        }
    }

    function _siftUp(uint256[] storage heap, uint256 i) private {
        while (i > 0) {
            uint256 parent = (i - 1) / 2;
            if (_unlockAtOf(heap[parent]) <= _unlockAtOf(heap[i])) break;
            _swap(heap, i, parent);
            i = parent;
        }
    }

    function _siftDown(uint256[] storage heap, uint256 i) private {
        uint256 n = heap.length;
        while (true) {
            uint256 c = 2 * i + 1;
            if (c >= n) break;
            if (c + 1 < n && _unlockAtOf(heap[c + 1]) < _unlockAtOf(heap[c])) ++c;
            if (_unlockAtOf(heap[i]) <= _unlockAtOf(heap[c])) break;
            _swap(heap, i, c);
            i = c;
        }
    }

    function _swap(uint256[] storage heap, uint256 i, uint256 j) private {
        (uint256 a, uint256 b) = (heap[i], heap[j]);
        heap[i] = b;
        heap[j] = a;
        _heapSlot[b] = i + 1;
        _heapSlot[a] = j + 1;
    }

    function _unlockAtOf(uint256 lockId) private view returns (uint64) {
        return _locks[lockId].unlockAt;
    }
}
