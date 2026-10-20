// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {ILiquidityLocks} from "../../src/ILiquidityLocks.sol";

/// @notice A plain ERC-20 with a public mint. Stands for a pool's underlying tokens.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice A v2-style pair reduced to its pool token: an ERC-20 that is its own pool. It can be set to keep a share of
///         every transfer from what the recipient gets, as a pool token that takes a fee on transfer would, or to
///         charge the sender a share on top of what it sends.
contract MockPair is MockToken {
    uint256 public transferFeeBps;
    uint256 public senderFeeBps;

    function setTransferFeeBps(uint256 bps) external {
        transferFeeBps = bps;
    }

    function setSenderFeeBps(uint256 bps) external {
        senderFeeBps = bps;
    }

    function _move(address from, address to, uint256 amount) internal virtual override {
        uint256 fee = amount * transferFeeBps / 10_000;
        balanceOf[from] -= amount + amount * senderFeeBps / 10_000;
        balanceOf[to] += amount - fee;
    }
}

/// @notice A pool token that, once armed, calls a target with given calldata from inside each transfer, once, and keeps
///         the revert data of that call.
contract ReentrantPair is MockPair {
    address public target;
    bytes public reentry;
    bytes public lastError;
    bool private _inHook;

    /// @dev Lets `target` pull this token's own balance, so the call back can lock tokens as this contract.
    function arm(address target_, bytes calldata reentry_, uint256 ownBalance) external {
        target = target_;
        reentry = reentry_;
        balanceOf[address(this)] += ownBalance;
        allowance[address(this)][target_] = type(uint256).max;
    }

    function _move(address from, address to, uint256 amount) internal override {
        super._move(from, to, amount);
        if (target == address(0) || _inHook) return;
        _inHook = true;
        (bool ok, bytes memory err) = target.call(reentry);
        if (!ok) lastError = err;
        _inHook = false;
    }
}

/// @notice The pool lookup of a v3-style factory.
contract MockFactory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function setPool(address token0, address token1, uint24 fee, address pool) external {
        getPool[token0][token1][fee] = pool;
        getPool[token1][token0][fee] = pool;
    }
}

/// @notice A v3-style position manager: an ERC-721 of positions with `positions(tokenId)` and `collect`. As in the
///         original, anyone may add liquidity to a position, while removing liquidity and collecting fees need the
///         owner or an approved account. Fees are credited by the test with `accrueFees`.
contract MockPositionManager {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    address public immutable factory;
    uint256 public nextId = 1;
    mapping(uint256 => Position) private _positions;
    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    constructor(address factory_) {
        factory = factory_;
    }

    function mint(address to, address token0, address token1, uint24 fee, uint128 liquidity)
        external
        returns (uint256 id)
    {
        id = nextId++;
        _owners[id] = to;
        _positions[id] = Position(token0, token1, fee, liquidity, 0, 0);
    }

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
        )
    {
        Position storage p = _positions[tokenId];
        require(p.token0 != address(0), "no position");
        return (0, address(0), p.token0, p.token1, p.fee, -600, 600, p.liquidity, 0, 0, p.tokensOwed0, p.tokensOwed1);
    }

    function liquidityOf(uint256 tokenId) external view returns (uint128) {
        return _positions[tokenId].liquidity;
    }

    function increaseLiquidity(uint256 tokenId, uint128 liquidity) external {
        _positions[tokenId].liquidity += liquidity;
    }

    function decreaseLiquidity(uint256 tokenId, uint128 liquidity) external {
        require(_authorized(msg.sender, tokenId), "not approved");
        _positions[tokenId].liquidity -= liquidity;
    }

    /// @notice Test helper: credits fees to a position and funds the manager to pay them.
    function accrueFees(uint256 tokenId, uint128 owed0, uint128 owed1) external {
        Position storage p = _positions[tokenId];
        p.tokensOwed0 += owed0;
        p.tokensOwed1 += owed1;
        MockToken(p.token0).mint(address(this), owed0);
        MockToken(p.token1).mint(address(this), owed1);
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1) {
        require(_authorized(msg.sender, params.tokenId), "not approved");
        Position storage p = _positions[params.tokenId];
        uint128 a0 = p.tokensOwed0 < params.amount0Max ? p.tokensOwed0 : params.amount0Max;
        uint128 a1 = p.tokensOwed1 < params.amount1Max ? p.tokensOwed1 : params.amount1Max;
        p.tokensOwed0 -= a0;
        p.tokensOwed1 -= a1;
        (amount0, amount1) = (a0, a1);
        require(MockToken(p.token0).transfer(params.recipient, a0), "pay0");
        require(MockToken(p.token1).transfer(params.recipient, a1), "pay1");
    }

    function ownerOf(uint256 tokenId) public view returns (address o) {
        o = _owners[tokenId];
        require(o != address(0), "no token");
    }

    function approve(address to, uint256 tokenId) external {
        require(_owners[tokenId] == msg.sender || isApprovedForAll[_owners[tokenId]][msg.sender], "not owner");
        getApproved[tokenId] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_authorized(msg.sender, tokenId), "not approved");
        require(ownerOf(tokenId) == from, "not from");
        require(to != address(0), "zero to");
        delete getApproved[tokenId];
        _owners[tokenId] = to;
    }

    function _authorized(address spender, uint256 tokenId) private view returns (bool) {
        address o = ownerOf(tokenId);
        return spender == o || getApproved[tokenId] == spender || isApprovedForAll[o][spender];
    }
}

/// @notice A contract that reports a lock it does not hold. Emitting the events or answering the reads proves nothing
///         by itself; a reader's check of the position's owner catches it.
contract FakeLocker {
    ILiquidityLocks.LiquidityLock private _lock;

    constructor(ILiquidityLocks.LiquidityLock memory lock_) {
        _lock = lock_;
    }

    function getLiquidityLock(uint256) external view returns (ILiquidityLocks.LiquidityLock memory) {
        return _lock;
    }
}
