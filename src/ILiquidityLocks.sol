// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Liquidity Locks (draft ERC)
/// @notice One interface for any contract that locks pool liquidity (fungible pool tokens, or position NFTs): which
///         pool, how much, until when, for whom, and who collects the fees meanwhile, listed and summed per pool.
/// @dev The ERC-165 identifier is `type(ILiquidityLocks).interfaceId`.
interface ILiquidityLocks {
    struct LiquidityLock {
        address pool; // the v2-style pair or v3-style pool; the singleton pool manager for a v4-style position
        bytes32 poolId; // the pool's id in a singleton pool manager; zero otherwise
        address position; // the pool token, or the position manager (ERC-721) of a position
        uint256 positionId; // the position's token id; zero for pool tokens
        uint256 amount; // pool tokens held for the lock, or the position's liquidity; zero once released
        uint64 unlockAt; // the earliest time the liquidity may leave; type(uint64).max: never
        address beneficiary; // who receives the liquidity at release
        address feeRecipient; // who is paid a position's fees meanwhile; zero for pool tokens
    }

    event LiquidityLockCreated(
        uint256 indexed lockId,
        address indexed pool,
        bytes32 indexed poolId,
        address position,
        uint256 positionId,
        uint256 amount,
        uint64 unlockAt,
        address beneficiary,
        address feeRecipient
    );
    event LiquidityLockExtended(uint256 indexed lockId, uint64 unlockAt);
    event LiquidityLockReleased(uint256 indexed lockId, address to);
    event LiquidityLockFeesCollected(uint256 indexed lockId, address to, uint256 amount0, uint256 amount1);

    /// @notice The lock `lockId`. Reverts for an id never issued.
    function getLiquidityLock(uint256 lockId) external view returns (LiquidityLock memory);

    /// @notice Ids of every lock created for the pool, released or not, oldest first, from `start`, at most `limit`.
    function liquidityLocksOfPool(address pool, bytes32 poolId, uint256 start, uint256 limit)
        external
        view
        returns (uint256[] memory);

    /// @notice Liquidity of the pool held under locks not yet released: permanent, timed (including lapsed locks not
    ///         yet released), and the earliest unlock time among the timed ones (zero when there is none).
    function lockedLiquidity(address pool, bytes32 poolId)
        external
        view
        returns (uint256 permanent, uint256 timed, uint64 earliestUnlock);

    /// @notice Moves the lock's unlock time later. Its beneficiary only.
    function extendLiquidityLock(uint256 lockId, uint64 unlockAt) external;

    /// @notice Sends the lock's liquidity to its beneficiary, at or after `unlockAt`. Anyone may call.
    function releaseLiquidityLock(uint256 lockId) external;

    /// @notice Collects a locked position's fees for its fee recipient. Anyone may call.
    function collectLiquidityLockFees(uint256 lockId) external returns (uint256 amount0, uint256 amount1);
}
