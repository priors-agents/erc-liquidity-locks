// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ILiquidityLocks} from "../src/ILiquidityLocks.sol";
import {LiquidityLocker} from "../src/LiquidityLocker.sol";
import {MockToken, MockPair, ReentrantPair, MockFactory, MockPositionManager, FakeLocker} from "./mocks/Mocks.sol";

contract LiquidityLockerTest is Test {
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

    uint64 constant NEVER = type(uint64).max;
    uint64 constant T = 1_800_000_000; // the tests start here
    uint64 constant IN_1D = T + 1 days;
    uint64 constant IN_30D = T + 30 days;
    uint64 constant IN_60D = T + 60 days;
    uint64 constant IN_90D = T + 90 days;
    uint24 constant FEE = 3000;

    LiquidityLocker locker;
    MockPair pair;
    MockPair otherPair;
    MockToken token0;
    MockToken token1;
    MockFactory factory;
    MockPositionManager pm;

    address v3Pool = makeAddr("v3Pool");
    address creator = makeAddr("creator");
    address beneficiary = makeAddr("beneficiary");
    address feeRecipient = makeAddr("feeRecipient");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(T);
        pair = new MockPair();
        otherPair = new MockPair();
        token0 = new MockToken();
        token1 = new MockToken();
        factory = new MockFactory();
        factory.setPool(address(token0), address(token1), FEE, v3Pool);
        pm = new MockPositionManager(address(factory));
        locker = new LiquidityLocker(address(pm));

        pair.mint(creator, 1_000_000e18);
        otherPair.mint(creator, 1_000_000e18);
        vm.startPrank(creator);
        pair.approve(address(locker), type(uint256).max);
        otherPair.approve(address(locker), type(uint256).max);
        pm.setApprovalForAll(address(locker), true);
        vm.stopPrank();
    }

    function _lockTokens(MockPair p, uint256 amount, uint64 unlockAt) internal returns (uint256) {
        vm.prank(creator);
        return locker.lockPoolTokens(address(p), amount, unlockAt, beneficiary);
    }

    function _mintPosition(uint128 liquidity) internal returns (uint256) {
        return pm.mint(creator, address(token0), address(token1), FEE, liquidity);
    }

    function _lockPosition(uint128 liquidity, uint64 unlockAt) internal returns (uint256 lockId, uint256 tokenId) {
        tokenId = _mintPosition(liquidity);
        vm.prank(creator);
        lockId = locker.lockPosition(tokenId, unlockAt, beneficiary, feeRecipient);
    }

    function _figures(address pool) internal view returns (uint256 permanent, uint256 timed, uint64 earliest) {
        return locker.lockedLiquidity(pool, bytes32(0));
    }

    /// @dev The check a reader makes before counting a lock: the locker holds what it reports.
    function _holds(address lockerAddr, uint256 lockId) internal view returns (bool) {
        ILiquidityLocks.LiquidityLock memory l = ILiquidityLocks(lockerAddr).getLiquidityLock(lockId);
        if (l.positionId == 0) return MockPair(l.position).balanceOf(lockerAddr) >= l.amount;
        (,,,,,,, uint128 liquidity,,,,) = MockPositionManager(l.position).positions(l.positionId);
        return MockPositionManager(l.position).ownerOf(l.positionId) == lockerAddr && liquidity >= l.amount;
    }

    // ------------------------------------------------------------- interface

    function test_supportsInterface() public view {
        assertTrue(locker.supportsInterface(type(ILiquidityLocks).interfaceId));
        assertTrue(locker.supportsInterface(0x01ffc9a7));
        assertFalse(locker.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------- creating

    function test_lockPoolTokens_recordsListsSumsAndEmits() public {
        vm.expectEmit(true, true, true, true, address(locker));
        emit LiquidityLockCreated(
            1, address(pair), bytes32(0), address(pair), 0, 1000e18, IN_30D, beneficiary, address(0)
        );
        uint256 id = _lockTokens(pair, 1000e18, IN_30D);

        assertEq(id, 1);
        ILiquidityLocks.LiquidityLock memory l = locker.getLiquidityLock(id);
        assertEq(l.pool, address(pair));
        assertEq(l.poolId, bytes32(0));
        assertEq(l.position, address(pair));
        assertEq(l.positionId, 0);
        assertEq(l.amount, 1000e18);
        assertEq(l.unlockAt, IN_30D);
        assertEq(l.beneficiary, beneficiary);
        assertEq(l.feeRecipient, address(0)); // a pool token's fees stay in the token
        assertEq(pair.balanceOf(address(locker)), 1000e18);
        assertEq(locker.liquidityLocksOfPool(address(pair), bytes32(0), 0, 10)[0], id);
        (uint256 permanent, uint256 timed, uint64 earliest) = _figures(address(pair));
        assertEq(permanent, 0);
        assertEq(timed, 1000e18);
        assertEq(earliest, IN_30D);
    }

    function test_lockPosition_takesThePoolFromThePositionManager() public {
        uint256 tokenId = _mintPosition(5e17);
        vm.expectEmit(true, true, true, true, address(locker));
        emit LiquidityLockCreated(1, v3Pool, bytes32(0), address(pm), tokenId, 5e17, NEVER, beneficiary, feeRecipient);
        vm.prank(creator);
        uint256 id = locker.lockPosition(tokenId, NEVER, beneficiary, feeRecipient);

        ILiquidityLocks.LiquidityLock memory l = locker.getLiquidityLock(id);
        assertEq(l.pool, v3Pool); // what the factory names for the position's tokens and fee
        assertEq(l.poolId, bytes32(0));
        assertEq(l.position, address(pm));
        assertEq(l.positionId, tokenId);
        assertEq(l.amount, 5e17);
        assertEq(l.unlockAt, NEVER);
        assertEq(l.feeRecipient, feeRecipient);
        assertEq(pm.ownerOf(tokenId), address(locker));
        // the locker gives no other account a way to move or reduce the position
        assertEq(pm.getApproved(tokenId), address(0));
        assertFalse(pm.isApprovedForAll(address(locker), creator));
        assertFalse(pm.isApprovedForAll(address(locker), beneficiary));
        (uint256 permanent, uint256 timed, uint64 earliest) = _figures(v3Pool);
        assertEq(permanent, 5e17);
        assertEq(timed, 0);
        assertEq(earliest, 0);
    }

    function test_lockPosition_ofAPoolTheFactoryDoesNotName_reverts() public {
        uint256 tokenId = pm.mint(creator, address(token0), address(token1), 500, 5e17); // no pool at this fee
        vm.prank(creator);
        vm.expectRevert(LiquidityLocker.UnknownPool.selector);
        locker.lockPosition(tokenId, IN_30D, beneficiary, feeRecipient);
    }

    function test_lockPoolTokens_recordsWhatArrived() public {
        pair.setTransferFeeBps(100); // the pool token keeps 1% of every transfer
        uint256 id = _lockTokens(pair, 1000e18, IN_30D);
        assertEq(locker.getLiquidityLock(id).amount, 990e18);
        assertEq(pair.balanceOf(address(locker)), 990e18);
        (, uint256 timed,) = _figures(address(pair));
        assertEq(timed, 990e18);
        assertTrue(_holds(address(locker), id));
    }

    function test_create_rejectsBadTerms() public {
        uint256 tokenId = _mintPosition(1);
        uint256 empty = _mintPosition(0);
        vm.startPrank(creator);
        vm.expectRevert(LiquidityLocker.ZeroAmount.selector);
        locker.lockPoolTokens(address(pair), 0, IN_30D, beneficiary);
        vm.expectRevert(LiquidityLocker.UnlockNotLater.selector);
        locker.lockPoolTokens(address(pair), 1, T, beneficiary);
        vm.expectRevert(LiquidityLocker.ZeroBeneficiary.selector);
        locker.lockPoolTokens(address(pair), 1, IN_30D, address(0));
        vm.expectRevert(LiquidityLocker.ZeroPositionId.selector);
        locker.lockPosition(0, IN_30D, beneficiary, feeRecipient);
        vm.expectRevert(LiquidityLocker.ZeroFeeRecipient.selector);
        locker.lockPosition(tokenId, IN_30D, beneficiary, address(0));
        vm.expectRevert(LiquidityLocker.ZeroBeneficiary.selector);
        locker.lockPosition(tokenId, IN_30D, address(0), feeRecipient);
        vm.expectRevert(LiquidityLocker.UnlockNotLater.selector);
        locker.lockPosition(tokenId, T - 1, beneficiary, feeRecipient);
        vm.expectRevert(LiquidityLocker.ZeroAmount.selector);
        locker.lockPosition(empty, IN_30D, beneficiary, feeRecipient);
        vm.stopPrank();

        pair.setTransferFeeBps(10_000); // nothing arrives
        vm.prank(creator);
        vm.expectRevert(LiquidityLocker.ZeroAmount.selector);
        locker.lockPoolTokens(address(pair), 1e18, IN_30D, beneficiary);
    }

    /// @dev Without the guard, the lock opened from inside the transfer would be counted twice: once by the inner call
    ///      and again in what the outer call sees arrive.
    function test_lockPoolTokens_aTokenThatCallsBackCannotOpenASecondLock() public {
        ReentrantPair hostile = new ReentrantPair();
        hostile.mint(creator, 100e18);
        vm.prank(creator);
        hostile.approve(address(locker), type(uint256).max);
        hostile.arm(
            address(locker),
            abi.encodeCall(LiquidityLocker.lockPoolTokens, (address(hostile), 100e18, IN_30D, beneficiary)),
            100e18
        );

        vm.prank(creator);
        uint256 id = locker.lockPoolTokens(address(hostile), 100e18, IN_30D, beneficiary);

        assertEq(bytes4(hostile.lastError()), LiquidityLocker.Reentrant.selector);
        assertEq(locker.liquidityLocksOfPool(address(hostile), bytes32(0), 0, 10).length, 1);
        assertEq(locker.getLiquidityLock(id).amount, 100e18);
        assertEq(hostile.balanceOf(address(locker)), 100e18);
        (, uint256 timed,) = _figures(address(hostile));
        assertEq(timed, 100e18);
    }

    function test_lockIds_startAtOne_andAreNeverReused() public {
        uint256 a = _lockTokens(pair, 1e18, IN_1D);
        (uint256 b,) = _lockPosition(1e17, IN_1D);
        vm.warp(IN_1D);
        locker.releaseLiquidityLock(a);
        uint256 c = _lockTokens(pair, 1e18, IN_30D);
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(c, 3);
        assertEq(locker.getLiquidityLock(a).amount, 0); // the released lock is still lock 1

        vm.expectRevert(LiquidityLocker.UnknownLock.selector);
        locker.getLiquidityLock(0);
        vm.expectRevert(LiquidityLocker.UnknownLock.selector);
        locker.getLiquidityLock(4);
    }

    // ------------------------------------------------------------- holding

    /// @dev Before `unlockAt`, nothing any account calls moves or reduces the liquidity of a lock.
    function testFuzz_nothingLeavesBeforeUnlockAt(address caller, uint32 elapsed, uint64 newUnlockAt) public {
        uint256 tokensLock = _lockTokens(pair, 1000e18, IN_30D);
        (uint256 positionLock, uint256 tokenId) = _lockPosition(5e17, IN_30D);
        uint256 permanentLock = _lockTokens(pair, 1e18, NEVER);
        pm.accrueFees(tokenId, 7, 9);
        vm.warp(T + uint64(elapsed) % 30 days);

        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(LiquidityLocker.StillLocked.selector, IN_30D));
        locker.releaseLiquidityLock(tokensLock);
        vm.expectRevert(abi.encodeWithSelector(LiquidityLocker.StillLocked.selector, IN_30D));
        locker.releaseLiquidityLock(positionLock);
        vm.expectRevert(abi.encodeWithSelector(LiquidityLocker.StillLocked.selector, NEVER));
        locker.releaseLiquidityLock(permanentLock);
        try locker.extendLiquidityLock(positionLock, newUnlockAt) {} catch {}
        try locker.collectLiquidityLockFees(positionLock) {} catch {}
        vm.stopPrank();

        assertEq(pair.balanceOf(address(locker)), 1001e18);
        assertEq(pm.ownerOf(tokenId), address(locker));
        assertEq(pm.liquidityOf(tokenId), 5e17);
        assertEq(pm.getApproved(tokenId), address(0));
        assertTrue(_holds(address(locker), tokensLock));
        assertTrue(_holds(address(locker), positionLock));
        assertTrue(_holds(address(locker), permanentLock));
    }

    function test_aLockKeepsItsFields_andItsAmountOnlyGoesToZeroAtRelease() public {
        (uint256 id, uint256 tokenId) = _lockPosition(5e17, IN_30D);
        ILiquidityLocks.LiquidityLock memory created = locker.getLiquidityLock(id);

        pm.increaseLiquidity(tokenId, 1e17); // anyone may add to a v3-style position
        pm.accrueFees(tokenId, 1, 1);
        locker.collectLiquidityLockFees(id);
        vm.prank(beneficiary);
        locker.extendLiquidityLock(id, IN_60D);

        ILiquidityLocks.LiquidityLock memory held = locker.getLiquidityLock(id);
        _assertSameParties(created, held);
        assertEq(held.amount, 5e17); // the figure locked: a floor under the position's 6e17
        assertEq(held.unlockAt, IN_60D);
        assertTrue(_holds(address(locker), id));

        vm.warp(IN_60D);
        locker.releaseLiquidityLock(id);
        ILiquidityLocks.LiquidityLock memory released = locker.getLiquidityLock(id);
        _assertSameParties(created, released);
        assertEq(released.amount, 0);
        assertEq(released.unlockAt, IN_60D);
    }

    function _assertSameParties(ILiquidityLocks.LiquidityLock memory a, ILiquidityLocks.LiquidityLock memory b)
        internal
        pure
    {
        assertEq(a.pool, b.pool);
        assertEq(a.poolId, b.poolId);
        assertEq(a.position, b.position);
        assertEq(a.positionId, b.positionId);
        assertEq(a.beneficiary, b.beneficiary);
        assertEq(a.feeRecipient, b.feeRecipient);
    }

    // ------------------------------------------------------------- extending

    function test_extend_onlyByTheBeneficiary_onlyLater() public {
        uint256 id = _lockTokens(pair, 1000e18, IN_30D);
        _lockTokens(pair, 1e18, IN_60D);

        vm.prank(stranger);
        vm.expectRevert(LiquidityLocker.NotBeneficiary.selector);
        locker.extendLiquidityLock(id, IN_90D);
        vm.prank(creator); // not even the account that locked it
        vm.expectRevert(LiquidityLocker.NotBeneficiary.selector);
        locker.extendLiquidityLock(id, IN_90D);

        vm.startPrank(beneficiary);
        vm.expectRevert(LiquidityLocker.UnlockNotLater.selector);
        locker.extendLiquidityLock(id, IN_30D);
        vm.expectRevert(LiquidityLocker.UnlockNotLater.selector);
        locker.extendLiquidityLock(id, IN_30D - 1);
        vm.expectEmit(true, false, false, true, address(locker));
        emit LiquidityLockExtended(id, IN_90D);
        locker.extendLiquidityLock(id, IN_90D);
        vm.stopPrank();

        assertEq(locker.getLiquidityLock(id).unlockAt, IN_90D);
        (, uint256 timed, uint64 earliest) = _figures(address(pair));
        assertEq(timed, 1001e18);
        assertEq(earliest, IN_60D); // the other lock is now the earliest
        vm.warp(IN_60D);
        vm.expectRevert(abi.encodeWithSelector(LiquidityLocker.StillLocked.selector, IN_90D));
        locker.releaseLiquidityLock(id);
    }

    function test_extend_toNever_makesTheLockPermanent() public {
        uint256 id = _lockTokens(pair, 1000e18, IN_30D);
        vm.prank(beneficiary);
        locker.extendLiquidityLock(id, NEVER);

        (uint256 permanent, uint256 timed, uint64 earliest) = _figures(address(pair));
        assertEq(permanent, 1000e18);
        assertEq(timed, 0);
        assertEq(earliest, 0);
        vm.prank(beneficiary);
        vm.expectRevert(LiquidityLocker.UnlockNotLater.selector); // nothing is later than never
        locker.extendLiquidityLock(id, NEVER);
        vm.warp(IN_30D);
        vm.expectRevert(abi.encodeWithSelector(LiquidityLocker.StillLocked.selector, NEVER));
        locker.releaseLiquidityLock(id);
    }

    function test_extend_aLapsedLock_beforeRelease_butNotAReleasedOne() public {
        uint256 id = _lockTokens(pair, 1000e18, IN_1D);
        uint256 gone = _lockTokens(pair, 1e18, IN_1D);
        vm.warp(IN_30D);
        locker.releaseLiquidityLock(gone);

        vm.startPrank(beneficiary);
        locker.extendLiquidityLock(id, IN_60D); // still held, so it can be locked again
        vm.expectRevert(LiquidityLocker.AlreadyReleased.selector);
        locker.extendLiquidityLock(gone, IN_60D);
        vm.expectRevert(LiquidityLocker.UnknownLock.selector);
        locker.extendLiquidityLock(99, IN_60D);
        vm.stopPrank();
        (, uint256 timed, uint64 earliest) = _figures(address(pair));
        assertEq(timed, 1000e18);
        assertEq(earliest, IN_60D);
    }

    // ------------------------------------------------------------- releasing

    function test_release_oneSecondEarlyReverts_thenAnyoneSendsItToTheBeneficiary() public {
        uint256 id = _lockTokens(pair, 1000e18, IN_30D);
        _lockTokens(pair, 500e18, IN_60D);

        vm.warp(IN_30D - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LiquidityLocker.StillLocked.selector, IN_30D));
        locker.releaseLiquidityLock(id);

        vm.warp(IN_30D);
        vm.expectEmit(true, false, false, true, address(locker));
        emit LiquidityLockReleased(id, beneficiary);
        vm.prank(stranger);
        locker.releaseLiquidityLock(id);

        assertEq(pair.balanceOf(beneficiary), 1000e18);
        assertEq(pair.balanceOf(stranger), 0);
        assertEq(pair.balanceOf(address(locker)), 500e18);
        assertEq(locker.getLiquidityLock(id).amount, 0);
        (, uint256 timed, uint64 earliest) = _figures(address(pair));
        assertEq(timed, 500e18);
        assertEq(earliest, IN_60D);

        vm.expectRevert(LiquidityLocker.AlreadyReleased.selector);
        locker.releaseLiquidityLock(id);
        vm.expectRevert(LiquidityLocker.UnknownLock.selector);
        locker.releaseLiquidityLock(99);
    }

    function test_release_ofAPosition_sendsTheNftToTheBeneficiary() public {
        (uint256 id, uint256 tokenId) = _lockPosition(5e17, IN_30D);
        vm.warp(IN_30D);
        vm.expectEmit(true, false, false, true, address(locker));
        emit LiquidityLockReleased(id, beneficiary);
        vm.prank(stranger);
        locker.releaseLiquidityLock(id);

        assertEq(pm.ownerOf(tokenId), beneficiary);
        assertEq(pm.liquidityOf(tokenId), 5e17);
        (uint256 permanent, uint256 timed, uint64 earliest) = _figures(v3Pool);
        assertEq(permanent + timed, 0);
        assertEq(earliest, 0);
    }

    function test_release_ofAFeeTakingPoolToken_sendsTheWholeAmount_andOtherLocksStayWhole() public {
        pair.setTransferFeeBps(100); // on from the lock to the release: the token keeps 1% of every transfer
        uint256 id = _lockTokens(pair, 1000e18, IN_30D);
        uint256 other = _lockTokens(pair, 500e18, IN_60D);
        assertEq(locker.getLiquidityLock(id).amount, 990e18);
        assertEq(locker.getLiquidityLock(other).amount, 495e18);

        vm.warp(IN_30D);
        vm.expectEmit(true, false, false, true, address(locker));
        emit LiquidityLockReleased(id, beneficiary);
        vm.prank(stranger);
        locker.releaseLiquidityLock(id);

        assertEq(pair.balanceOf(address(locker)), 495e18); // exactly the lock's 990 left the locker
        assertEq(pair.balanceOf(beneficiary), 980.1e18); // what the token delivered of the 990
        assertEq(pair.balanceOf(stranger), 0);
        assertEq(locker.getLiquidityLock(id).amount, 0);
        (, uint256 timed, uint64 earliest) = _figures(address(pair));
        assertEq(timed, 495e18);
        assertEq(earliest, IN_60D);
        assertTrue(_holds(address(locker), other));
    }

    function test_release_neverTakesFromOtherLocks() public {
        uint256 id = _lockTokens(pair, 1000e18, IN_30D);
        uint256 other = _lockTokens(pair, 1000e18, IN_60D);
        pair.setSenderFeeBps(100); // the token now takes 1% from its sender on top of what it sends

        vm.warp(IN_30D);
        vm.prank(stranger);
        vm.expectRevert(LiquidityLocker.ReleaseExceedsLock.selector);
        locker.releaseLiquidityLock(id);
        assertEq(pair.balanceOf(address(locker)), 2000e18);
        assertTrue(_holds(address(locker), other));

        pair.setSenderFeeBps(0); // once the token takes no more than it sends, the release goes through
        locker.releaseLiquidityLock(id);
        assertEq(pair.balanceOf(beneficiary), 1000e18);
        assertTrue(_holds(address(locker), other));
    }

    function test_release_ofAPermanentLock_neverSucceeds() public {
        uint256 id = _lockTokens(pair, 1000e18, NEVER);
        (uint256 positionLock,) = _lockPosition(5e17, NEVER);
        vm.warp(NEVER); // the last second there is
        vm.startPrank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(LiquidityLocker.StillLocked.selector, NEVER));
        locker.releaseLiquidityLock(id);
        vm.expectRevert(abi.encodeWithSelector(LiquidityLocker.StillLocked.selector, NEVER));
        locker.releaseLiquidityLock(positionLock);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- fees

    function test_collectFees_anyonePaysTheFeeRecipient_andTheLiquidityStays() public {
        (uint256 id, uint256 tokenId) = _lockPosition(5e17, IN_30D);
        pm.accrueFees(tokenId, 7e6, 9e6);

        vm.expectEmit(true, false, false, true, address(locker));
        emit LiquidityLockFeesCollected(id, feeRecipient, 7e6, 9e6);
        vm.prank(stranger);
        (uint256 amount0, uint256 amount1) = locker.collectLiquidityLockFees(id);

        assertEq(amount0, 7e6);
        assertEq(amount1, 9e6);
        assertEq(token0.balanceOf(feeRecipient), 7e6);
        assertEq(token1.balanceOf(feeRecipient), 9e6);
        assertEq(token0.balanceOf(stranger) + token1.balanceOf(stranger), 0);
        assertEq(token0.balanceOf(beneficiary) + token1.balanceOf(beneficiary), 0);
        assertEq(token0.balanceOf(address(locker)) + token1.balanceOf(address(locker)), 0);
        assertEq(pm.liquidityOf(tokenId), 5e17);
        assertEq(pm.ownerOf(tokenId), address(locker));
        assertEq(locker.getLiquidityLock(id).amount, 5e17);
    }

    function test_collectFees_ofPoolTokens_orAReleasedLock_reverts() public {
        uint256 id = _lockTokens(pair, 1000e18, IN_30D);
        vm.expectRevert(LiquidityLocker.NotAPosition.selector);
        locker.collectLiquidityLockFees(id);

        (uint256 positionLock,) = _lockPosition(5e17, IN_30D);
        vm.warp(IN_30D);
        locker.releaseLiquidityLock(positionLock);
        vm.expectRevert(LiquidityLocker.AlreadyReleased.selector);
        locker.collectLiquidityLockFees(positionLock);
        vm.expectRevert(LiquidityLocker.UnknownLock.selector);
        locker.collectLiquidityLockFees(99);
    }

    // ------------------------------------------------------------- reading

    function test_pages_listEveryLockOfThePool_releasedOrNot() public {
        for (uint64 i; i < 5; ++i) {
            _lockTokens(pair, 1e18, IN_1D + i); // ids 1 to 5
        }
        _lockTokens(otherPair, 1e18, IN_1D); // id 6, another pool
        vm.warp(IN_30D);
        locker.releaseLiquidityLock(1);

        uint256[] memory p = locker.liquidityLocksOfPool(address(pair), bytes32(0), 1, 2);
        assertEq(p.length, 2);
        assertEq(p[0], 2);
        assertEq(p[1], 3);
        p = locker.liquidityLocksOfPool(address(pair), bytes32(0), 0, type(uint256).max);
        assertEq(p.length, 5);
        assertEq(p[0], 1); // released, still listed
        assertEq(locker.liquidityLocksOfPool(address(pair), bytes32(0), 4, 10).length, 1);
        assertEq(locker.liquidityLocksOfPool(address(pair), bytes32(0), 5, 10).length, 0);
        p = locker.liquidityLocksOfPool(address(otherPair), bytes32(0), 0, 10);
        assertEq(p.length, 1);
        assertEq(p[0], 6);
        assertEq(locker.liquidityLocksOfPool(address(pair), bytes32(uint256(1)), 0, 10).length, 0);
    }

    function test_lockedLiquidity_splitsPermanentAndTimed_perPool() public {
        _lockTokens(pair, 100e18, NEVER);
        _lockTokens(pair, 30e18, IN_60D);
        uint256 soonest = _lockTokens(pair, 20e18, IN_30D);
        _lockTokens(otherPair, 7e18, IN_1D);
        _lockPosition(5e17, IN_90D);
        _lockPosition(2e17, NEVER);

        (uint256 permanent, uint256 timed, uint64 earliest) = _figures(address(pair));
        assertEq(permanent, 100e18);
        assertEq(timed, 50e18);
        assertEq(earliest, IN_30D);
        (permanent, timed, earliest) = _figures(address(otherPair));
        assertEq(permanent, 0);
        assertEq(timed, 7e18);
        assertEq(earliest, IN_1D);
        (permanent, timed, earliest) = _figures(v3Pool);
        assertEq(permanent, 2e17);
        assertEq(timed, 5e17);
        assertEq(earliest, IN_90D);
        (permanent, timed, earliest) = _figures(makeAddr("no locks"));
        assertEq(permanent + timed + earliest, 0);

        // a lapsed lock still held counts, with its time in the past, until it is released
        vm.warp(IN_30D + 1);
        (permanent, timed, earliest) = _figures(address(pair));
        assertEq(timed, 50e18);
        assertEq(earliest, IN_30D);
        locker.releaseLiquidityLock(soonest);
        (permanent, timed, earliest) = _figures(address(pair));
        assertEq(permanent, 100e18);
        assertEq(timed, 30e18);
        assertEq(earliest, IN_60D);
    }

    function test_lockedLiquidity_costDoesNotGrowWithThePoolsLocks() public {
        _lockTokens(pair, 1000e18, IN_90D);
        address griefer = makeAddr("griefer");
        pair.mint(griefer, 200);
        vm.startPrank(griefer);
        pair.approve(address(locker), 200);
        for (uint64 i; i < 200; ++i) {
            locker.lockPoolTokens(address(pair), 1, IN_1D + 200 - i, griefer); // each one earlier than the last
        }
        vm.stopPrank();

        uint256 g = gasleft();
        (, uint256 timed, uint64 earliest) = locker.lockedLiquidity(address(pair), bytes32(0));
        uint256 used = g - gasleft();
        assertEq(timed, 1000e18 + 200);
        assertEq(earliest, IN_1D + 1);
        assertLt(used, 15_000);
    }

    /// @dev Random locks, extensions, releases and waits in three pools; afterwards each pool's figures are those
    ///      computed from its locks one by one, and the locker holds exactly what its open locks say.
    function testFuzz_figuresMatchTheLocks_andWhatTheLockerHolds(uint8[24] memory ops, uint32[24] memory args) public {
        uint64 now_ = T;
        uint256 count;
        for (uint256 i; i < ops.length; ++i) {
            uint32 a = args[i];
            uint64 unlockAt = a % 7 == 0 ? NEVER : now_ + 1 + uint64(a % 120 days);
            uint256 op = ops[i] % 5;
            if (op == 0) {
                _lockTokens(a % 2 == 0 ? pair : otherPair, uint256(a % 1000) + 1, unlockAt);
                ++count;
            } else if (op == 1) {
                _lockPosition(uint128(a % 1000) + 1, unlockAt);
                ++count;
            } else if (op == 2 && count != 0) {
                uint256 id = 1 + uint256(a) % count;
                uint64 current = locker.getLiquidityLock(id).unlockAt;
                uint64 later = a % 5 == 0 || current > NEVER - 61 days ? NEVER : current + 1 + uint64(a % 60 days);
                vm.prank(beneficiary);
                try locker.extendLiquidityLock(id, later) {} catch {}
            } else if (op == 3 && count != 0) {
                try locker.releaseLiquidityLock(1 + uint256(a) % count) {} catch {}
            } else if (op == 4) {
                now_ += uint64(a % 40 days);
                vm.warp(now_);
            }
        }
        _assertFiguresMatch(address(pair));
        _assertFiguresMatch(address(otherPair));
        _assertFiguresMatch(v3Pool);
    }

    function _assertFiguresMatch(address pool) internal view {
        uint256[] memory ids = locker.liquidityLocksOfPool(pool, bytes32(0), 0, type(uint256).max);
        uint256 permanent;
        uint256 timed;
        uint64 earliest;
        uint256 tokensHeld;
        for (uint256 i; i < ids.length; ++i) {
            ILiquidityLocks.LiquidityLock memory l = locker.getLiquidityLock(ids[i]);
            assertEq(l.pool, pool);
            if (l.positionId != 0) {
                address owner = pm.ownerOf(l.positionId);
                assertEq(owner, l.amount == 0 ? beneficiary : address(locker));
            }
            if (l.amount == 0) continue;
            assertTrue(_holds(address(locker), ids[i]));
            if (l.positionId == 0) tokensHeld += l.amount;
            if (l.unlockAt == NEVER) {
                permanent += l.amount;
            } else {
                timed += l.amount;
                if (earliest == 0 || l.unlockAt < earliest) earliest = l.unlockAt;
            }
        }
        (uint256 p, uint256 t, uint64 e) = locker.lockedLiquidity(pool, bytes32(0));
        assertEq(p, permanent);
        assertEq(t, timed);
        assertEq(e, earliest);
        if (pool != v3Pool) assertEq(MockPair(pool).balanceOf(address(locker)), tokensHeld);
    }

    // ------------------------------------------------------------- detector inputs

    uint32 constant LP_LOCK_MAX = type(uint32).max - 1; // the largest value that is not the unavailability sentinel

    /// @dev The ERC-8376 `lockedLiquidity` and `lpLockRemaining` inputs for a pool, computed from conforming lockers as
    ///      the specification's "Detector inputs" describes, at window end `t`.
    function _detectorInputs(ILiquidityLocks[] memory lockers, address pool, uint256 t)
        internal
        view
        returns (uint256 lockedLiquidity, uint32 lpLockRemaining)
    {
        bool anyTimed;
        uint256 shortest = type(uint256).max;
        for (uint256 i; i < lockers.length; ++i) {
            (uint256 permanent, uint256 timed, uint64 earliestUnlock) = lockers[i].lockedLiquidity(pool, bytes32(0));
            lockedLiquidity += permanent + timed;
            if (timed == 0) continue;
            anyTimed = true;
            uint256 left = earliestUnlock > t ? earliestUnlock - t : 0;
            if (left < shortest) shortest = left;
        }
        if (lockedLiquidity == 0) return (0, 0);
        if (!anyTimed || shortest >= LP_LOCK_MAX) return (lockedLiquidity, LP_LOCK_MAX);
        // forge-lint: disable-next-line(unsafe-typecast)
        lpLockRemaining = uint32(shortest); // below LP_LOCK_MAX, checked on the line above
    }

    function test_detectorInputs_forPermanentMixedTimedAndEmptyPools() public {
        LiquidityLocker second = new LiquidityLocker(address(pm));
        MockPair farPair = new MockPair();
        farPair.mint(creator, 1e18);
        vm.startPrank(creator);
        pair.approve(address(second), type(uint256).max);
        otherPair.approve(address(second), type(uint256).max);
        farPair.approve(address(locker), type(uint256).max);
        vm.stopPrank();
        ILiquidityLocks[] memory lockers = new ILiquidityLocks[](2);
        lockers[0] = locker;
        lockers[1] = second;

        _lockTokens(pair, 100e18, NEVER); // permanent only, in both lockers
        vm.prank(creator);
        second.lockPoolTokens(address(pair), 50e18, NEVER, beneficiary);
        _lockTokens(otherPair, 100e18, NEVER); // mixed: permanent here, timed in the second locker
        vm.prank(creator);
        second.lockPoolTokens(address(otherPair), 20e18, IN_30D, beneficiary);
        _lockPosition(5e17, IN_90D); // timed only
        _lockPosition(2e17, IN_60D);
        _lockTokens(farPair, 1e18, T + 200 * 365 days); // timed, beyond what a uint32 of seconds holds

        (uint256 locked, uint32 remaining) = _detectorInputs(lockers, address(pair), T);
        assertEq(locked, 150e18);
        assertEq(remaining, LP_LOCK_MAX);
        (locked, remaining) = _detectorInputs(lockers, address(otherPair), T);
        assertEq(locked, 120e18);
        assertEq(remaining, 30 days); // 2,592,000 seconds: the shortest lock decides
        (locked, remaining) = _detectorInputs(lockers, v3Pool, T);
        assertEq(locked, 7e17);
        assertEq(remaining, 60 days);
        (locked, remaining) = _detectorInputs(lockers, address(farPair), T);
        assertEq(locked, 1e18);
        assertEq(remaining, LP_LOCK_MAX);
        (locked, remaining) = _detectorInputs(lockers, makeAddr("no locks"), T);
        assertEq(locked, 0);
        assertEq(remaining, 0);

        vm.warp(IN_30D + 1); // the timed lock of the mixed pool has lapsed, still held
        (locked, remaining) = _detectorInputs(lockers, address(otherPair), IN_30D + 1);
        assertEq(locked, 120e18);
        assertEq(remaining, 0);
    }

    // ------------------------------------------------------------- the reader's checks

    function test_readerCheck_catchesALockerThatDoesNotHoldWhatItReports() public {
        (uint256 positionLock,) = _lockPosition(5e17, IN_30D);
        uint256 tokensLock = _lockTokens(pair, 1000e18, IN_30D);
        assertTrue(_holds(address(locker), positionLock));
        assertTrue(_holds(address(locker), tokensLock));

        // the same figures, reported by a contract that holds nothing
        FakeLocker fakePosition = new FakeLocker(locker.getLiquidityLock(positionLock));
        FakeLocker fakeTokens = new FakeLocker(locker.getLiquidityLock(tokensLock));
        assertFalse(_holds(address(fakePosition), 1));
        assertFalse(_holds(address(fakeTokens), 1));
    }
}
