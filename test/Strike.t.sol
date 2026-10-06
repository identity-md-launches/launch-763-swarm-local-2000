// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strike} from "../src/Strike.sol";
import {UnionCard} from "../src/UnionCard.sol";
import {FactoryModel, PairModel} from "./PairModel.sol";
import {IStrikeSwap} from "../src/interfaces/IStrikeSwap.sol";

contract MockIMD is ERC20 {
    constructor() ERC20("Identity MD", "IMD") {}

    function mint(address who, uint256 amount) external {
        _mint(who, amount);
    }
}

contract MockSwap is IStrikeSwap {
    IERC20 public strike;
    IERC20 public imd;
    uint256 public outputBps = 10_000;
    bool public broken;
    bool public reenter;
    bool public reentrySucceeded;

    function configure(IERC20 s, IERC20 i) external {
        strike = s;
        imd = i;
    }

    function setBehavior(uint256 bps, bool broken_, bool reenter_) external {
        outputBps = bps;
        broken = broken_;
        reenter = reenter_;
    }

    function quote(address, uint256 amount) external view returns (uint256) {
        require(!broken, "stale oracle");
        return amount;
    }

    function swap(address input, uint256 amount, uint256, address recipient) external returns (uint256) {
        if (reenter) {
            (reentrySucceeded,) = address(strike).call(abi.encodeCall(Strike.processFees, (1, 1)));
            require(!reentrySucceeded, "reentered");
            (reentrySucceeded,) = address(strike).call(abi.encodeCall(Strike.processStrikeBurn, (1)));
            require(!reentrySucceeded, "burn reentered");
            (reentrySucceeded,) = address(strike).call(abi.encodeCall(Strike.executeStrikeBurn, (1)));
            require(!reentrySucceeded, "self-call bypass");
        }
        IERC20(input).transferFrom(msg.sender, address(this), amount);
        IERC20 output = input == address(strike) ? imd : strike;
        output.transfer(recipient, amount * outputBps / 10_000);
        return type(uint256).max; // Deliberately untrustworthy return; callers must measure balances.
    }
}

contract NFTProbe {
    mapping(address => uint256) public balanceOf;

    function give(address user) external {
        balanceOf[user] = 1;
    }
}

contract StrikeTest is Test {
    Strike internal token;
    MockIMD internal imd;
    MockSwap internal adapter;
    FactoryModel internal v2Factory;
    UnionCard internal cards;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal market = address(0xBA4);
    address internal manager = address(0x4444);
    uint256 internal signerKey = 0x5151;
    uint64 internal launch = 23;
    mapping(uint64 => address) public distributorOf;

    function setUp() public {
        vm.warp(1_700_000_000);
        imd = new MockIMD();
        v2Factory = new FactoryModel();
        token = new Strike(
            address(this),
            manager,
            launch,
            address(imd),
            address(v2Factory),
            keccak256(type(PairModel).creationCode),
            vm.addr(signerKey),
            1 ether,
            1 ether
        );
        market = token.market();
        MockSwap implementation = new MockSwap();
        vm.etch(address(token.swapAdapter()), address(implementation).code);
        adapter = MockSwap(address(token.swapAdapter()));
        adapter.setBehavior(10_000, false, false);
        adapter.configure(IERC20(address(token)), IERC20(address(imd)));
        cards = new UnionCard(address(token));
        imd.mint(address(adapter), 1e30);
        token.transfer(address(adapter), 1_000_000 ether);
        token.transfer(alice, 1_000_000 ether);
        token.transfer(bob, 1_000_000 ether);
        token.transfer(carol, 1_000_000 ether);
        token.transfer(market, 1_000_000 ether);
    }

    function _fees() internal {
        vm.prank(carol);
        token.transfer(market, 100_000 ether);
        token.processFees(type(uint256).max, type(uint256).max);
        assertEq(token.fund(), 1000 ether);
    }

    function _stake(address who, uint256 amount, uint256 days_) internal {
        vm.prank(who);
        token.stake(amount, days_);
    }

    function _answer(uint256 jobs) internal {
        uint256 day = vm.getBlockTimestamp() / 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, token.answerDigest(jobs, vm.getBlockTimestamp(), day));
        token.submitOvertime(jobs, vm.getBlockTimestamp(), day, abi.encodePacked(r, s, v));
    }

    function _assertSolvent() internal view {
        assertGe(token.balanceOf(address(token)), token.totalStaked() + token.pendingFund() + token.pendingImdBurn());
        assertGe(
            imd.balanceOf(address(token)),
            token.fund() + token.rewardLiability() + token.streamBudget() - token.streamReleased()
                + token.pendingStrikeBurn()
        );
        assertLe(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    function testMetadataAndInitialSupply() public {
        Strike fresh = new Strike(
            address(this),
            manager,
            launch,
            address(imd),
            address(v2Factory),
            keccak256(type(PairModel).creationCode),
            vm.addr(signerKey),
            1,
            1
        );
        assertEq(fresh.name(), "Swarm Local 2000");
        assertEq(fresh.symbol(), "STRIKE");
        assertEq(fresh.decimals(), 18);
        assertEq(fresh.totalSupply(), 1_000_000_000 ether);
        assertEq(fresh.balanceOf(address(this)), fresh.totalSupply());
        assertEq(fresh.owner(), address(0));
        assertLt(address(token).code.length, 24_577);
    }

    function testConstructorRejectsInvalidConfig() public {
        vm.expectRevert(Strike.InvalidConfiguration.selector);
        new Strike(
            address(this),
            manager,
            launch,
            address(imd),
            address(0),
            keccak256(type(PairModel).creationCode),
            vm.addr(signerKey),
            1,
            1
        );
        vm.expectRevert(Strike.InvalidConfiguration.selector);
        new Strike(
            alice,
            manager,
            launch,
            address(imd),
            address(v2Factory),
            keccak256(type(PairModel).creationCode),
            vm.addr(signerKey),
            1,
            1
        );
    }

    function testLaunchFlowsExactAndNoAdmin() public {
        address distributor = address(0xD157);
        distributorOf[launch] = distributor;
        uint256 swarm = token.INITIAL_SUPPLY() / 10;
        token.transfer(distributor, swarm);
        vm.prank(distributor);
        token.transfer(alice, swarm);
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.balanceOf(alice), 1_000_000 ether + swarm);
        token.transfer(manager, 880_000_000 ether);
        vm.prank(manager);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.transfer(manager, 100 ether);
        assertEq(token.balanceOf(manager), 880_000_000 ether);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
        string[6] memory forbidden = [
            "mint(address,uint256)",
            "pause()",
            "blacklist(address)",
            "burnFrom(address,uint256)",
            "upgradeTo(address)",
            "setFee(uint256)"
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(forbidden[i], alice, 100));
            assertFalse(ok);
        }
        vm.expectRevert();
        token.transferFrom(alice, bob, 1);
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    function testBuySellFeesAndTransfers() public {
        uint256 initialSupply = token.totalSupply();
        uint256 beforeAlice = token.balanceOf(alice);
        vm.prank(market);
        token.transfer(alice, 10_000 ether);
        assertEq(token.balanceOf(alice) - beforeAlice, 9800 ether);
        assertEq(token.pendingFund(), 100 ether);
        assertEq(token.pendingImdBurn(), 50 ether);
        assertEq(initialSupply - token.totalSupply(), 50 ether);
        uint256 beforeMarket = token.balanceOf(market);
        vm.prank(alice);
        token.transfer(market, 10_000 ether);
        assertEq(token.balanceOf(market) - beforeMarket, 9800 ether);
        assertEq(token.pendingFund(), 200 ether);
        vm.prank(alice);
        token.transfer(bob, 500 ether);
        assertEq(token.pendingFund(), 200 ether);
        assertEq(token.totalSupply(), initialSupply - 100 ether);
        _assertSolvent();
    }

    function testTransferFromRespectsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100 ether);
        vm.prank(bob);
        token.transferFrom(alice, market, 100 ether);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, bob, 1);
    }

    function testSellingUnaffectedByBrokenSwapService() public {
        adapter.setBehavior(10_000, true, false);
        vm.prank(alice);
        token.transfer(market, 100 ether);
        uint256 pending = token.pendingFund();
        vm.expectRevert("stale oracle");
        token.processFees(1 ether, 1 ether);
        assertEq(token.pendingFund(), pending);
        vm.prank(alice);
        token.transfer(market, 100 ether);
        assertEq(token.pendingFund(), 2 ether);
    }

    function testFeeConversionBoundedNoPrincipalSpendAndNoAllowanceLeft() public {
        _stake(alice, 100_000 ether, 180);
        vm.prank(carol);
        token.transfer(market, 100_000 ether);
        token.processFees(100 ether, 200 ether);
        assertEq(token.pendingImdBurn(), 400 ether);
        assertEq(token.pendingFund(), 800 ether);
        assertEq(token.fund(), 200 ether);
        assertEq(imd.balanceOf(token.DEAD()), 100 ether);
        assertEq(token.allowance(address(token), address(adapter)), 0);
        assertEq(token.totalStaked(), 100_000 ether);
        _assertSolvent();
    }

    function testShortSwapOutputRevertsAllAccounting() public {
        vm.prank(carol);
        token.transfer(market, 100_000 ether);
        adapter.setBehavior(9000, false, false);
        uint256 before = token.balanceOf(address(token));
        vm.expectRevert(Strike.SwapFailed.selector);
        token.processFees(500 ether, 1000 ether);
        assertEq(token.pendingFund(), 1000 ether);
        assertEq(token.balanceOf(address(token)), before);
        assertEq(token.fund(), 0);
        assertEq(token.allowance(address(token), address(adapter)), 0);
    }

    function testReentrancyCannotProcessFeesTwice() public {
        adapter.setBehavior(10_000, false, true);
        _fees();
        assertFalse(adapter.reentrySucceeded());
        _assertSolvent();
    }

    function testRanksResetOnlyOnNonzeroOutgoingAndStakeExempt() public {
        uint256 start = token.holdStart(alice);
        vm.warp(start + 1 days);
        assertEq(token.rankBonus(alice), 11_000);
        vm.warp(start + 7 days);
        assertEq(token.rankBonus(alice), 12_500);
        vm.prank(bob);
        token.transfer(alice, 0);
        vm.prank(bob);
        token.transfer(alice, 1);
        assertEq(token.holdStart(alice), start);
        _stake(alice, 100 ether, 7);
        assertEq(token.holdStart(alice), start);
        vm.warp(start + 30 days);
        assertEq(token.rankBonus(alice), 15_000);
        vm.prank(alice);
        token.exit();
        assertEq(token.holdStart(alice), start);
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.rankBonus(alice), 10_000);
        assertEq(token.holdStart(alice), vm.getBlockTimestamp());
    }

    function testZeroTransferFromCannotGriefRank() public {
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(carol);
        token.transferFrom(alice, bob, 0);
        assertEq(token.rankBonus(alice), 15_000);
        uint256 liquid = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(bob, liquid);
        assertEq(token.holdStart(alice), 0);
    }

    function testLockWeightsAndInvalidActions() public {
        _stake(alice, 100 ether, 7);
        _stake(bob, 100 ether, 30);
        _stake(carol, 100 ether, 90);
        _stake(address(this), 100 ether, 180);
        assertEq(token.totalWeight(), 900 ether);
        vm.prank(alice);
        vm.expectRevert(Strike.ActiveStake.selector);
        token.stake(1, 7);
        vm.prank(market);
        vm.expectRevert(Strike.InvalidLock.selector);
        token.stake(1, 8);
        vm.prank(market);
        vm.expectRevert(Strike.InvalidAmount.selector);
        token.stake(0, 7);
        vm.prank(market);
        vm.expectRevert(Strike.NoStake.selector);
        token.exit();
        _assertSolvent();
    }

    function testOvertimeCapStreamsAndWeightedRewards() public {
        _fees();
        _stake(alice, 100 ether, 7);
        _stake(bob, 100 ether, 30);
        uint256 supply = token.totalSupply();
        _answer(type(uint256).max);
        assertEq(token.fund(), 980 ether);
        assertEq(supply - token.totalSupply(), 10 ether);
        assertEq(token.streamBudget(), 10 ether);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(token.earned(alice), 4 ether);
        assertEq(token.earned(bob), 6 ether);
        vm.prank(alice);
        token.claim();
        assertEq(imd.balanceOf(alice), 4 ether);
        vm.prank(bob);
        vm.expectRevert(Strike.TooSoon.selector);
        token.claim();
        vm.warp(vm.getBlockTimestamp() + 23 days);
        vm.prank(bob);
        token.exit();
        assertEq(imd.balanceOf(bob), 6 ether);
        _assertSolvent();
    }

    function testEarlyExitBurnsAndForfeitsToRemainingStakers() public {
        _fees();
        _stake(alice, 100 ether, 30);
        _stake(bob, 100 ether, 30);
        _answer(20);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(token.earned(alice), 5 ether, 1);
        uint256 supply = token.totalSupply();
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        token.exit();
        assertEq(token.balanceOf(alice) - before, 80 ether);
        assertEq(supply - token.totalSupply(), 20 ether);
        assertEq(imd.balanceOf(alice), 0);
        assertApproxEqAbs(token.earned(bob), 10 ether, 2);
        vm.warp(vm.getBlockTimestamp() + 23 days);
        vm.prank(bob);
        token.claim();
        assertApproxEqAbs(imd.balanceOf(bob), 10 ether, 2);
        _assertSolvent();
    }

    function testLastEarlyExiterReturnsForfeitureToFund() public {
        _fees();
        _stake(alice, 100 ether, 30);
        _answer(20);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(alice);
        token.exit();
        assertApproxEqAbs(token.fund(), 990 ether, 1);
        assertLe(token.rewardLiability(), 1);
        _assertSolvent();
    }

    function testNoStakerBackdatedRewardsAndDonationIgnored() public {
        _fees();
        _answer(20);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _stake(alice, 100 ether, 7);
        assertEq(token.earned(alice), 0);
        assertEq(token.fund(), 990 ether);
        imd.mint(address(token), 123 ether);
        assertEq(token.fund(), 990 ether);
        _assertSolvent();
    }

    function testOverlappingStreamsConserveBudgets() public {
        _fees();
        _stake(alice, 100 ether, 30);
        _answer(20);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 alreadyEarned = token.earned(alice);
        _answer(10);
        assertApproxEqAbs(token.streamBudget(), 15 ether - alreadyEarned, 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(token.earned(alice), 15 ether, 2);
        _assertSolvent();
    }

    function testSignatureReplayStaleFutureWrongSignerAndDomain() public {
        vm.chainId(31337);
        _fees();
        uint256 now_ = vm.getBlockTimestamp();
        uint256 day = now_ / 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, token.answerDigest(20, now_, day));
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.expectRevert(Strike.InvalidAnswer.selector);
        token.submitOvertime(21, now_, day, sig);
        vm.expectRevert(Strike.InvalidAnswer.selector);
        token.submitOvertime(20, now_ + 1, day, sig);
        (v, r, s) = vm.sign(123, token.answerDigest(20, now_, day));
        vm.expectRevert(Strike.InvalidAnswer.selector);
        token.submitOvertime(20, now_, day, abi.encodePacked(r, s, v));
        vm.chainId(31338);
        vm.expectRevert(Strike.InvalidAnswer.selector);
        token.submitOvertime(20, now_, day, sig);
        vm.chainId(31337);
        token.submitOvertime(20, now_, day, sig);
        vm.expectRevert(Strike.InvalidAnswer.selector);
        token.submitOvertime(20, now_, day, sig);
        vm.warp(now_ + 2 days);
        vm.expectRevert(Strike.InvalidAnswer.selector);
        token.submitOvertime(20, now_, day, sig);
    }

    function testCadenceZeroJobsAndFallback() public {
        _fees();
        _answer(0);
        assertEq(token.fund(), 1000 ether);
        assertEq(token.lastAnswerAt(), vm.getBlockTimestamp());
        vm.expectRevert(Strike.TooSoon.selector);
        token.fallbackOvertime();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        token.fallbackOvertime();
        assertEq(token.fund(), 999 ether);
        assertEq(token.streamBudget(), 0.5 ether);
        vm.expectRevert(Strike.TooSoon.selector);
        token.fallbackOvertime();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _answer(1);
        assertEq(token.fund(), 998 ether + uint256(0.5 ether) / 7);
        _assertSolvent();
    }

    function testDailyCadenceAcceptsAdjacentUtcDaysAndRejectsReplay() public {
        _fees();
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days - 10);
        _answer(1);
        vm.warp(vm.getBlockTimestamp() + 20);
        uint256 day = vm.getBlockTimestamp() / 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, token.answerDigest(1, vm.getBlockTimestamp(), day));
        token.submitOvertime(1, vm.getBlockTimestamp(), day, abi.encodePacked(r, s, v));
        assertTrue(token.usedDay(day));
        vm.expectRevert(Strike.InvalidAnswer.selector);
        token.submitOvertime(1, vm.getBlockTimestamp(), day, abi.encodePacked(r, s, v));
    }

    function testOracleSwapFailureDefersBurnAndPreservesAnswerAndRewards() public {
        _fees();
        _stake(alice, 100 ether, 7);
        adapter.setBehavior(1, false, false);
        uint256 day = vm.getBlockTimestamp() / 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, token.answerDigest(20, vm.getBlockTimestamp(), day));
        token.submitOvertime(20, vm.getBlockTimestamp(), day, abi.encodePacked(r, s, v));
        assertTrue(token.usedDay(day));
        assertEq(token.fund(), 980 ether);
        assertEq(token.pendingStrikeBurn(), 10 ether);
        assertEq(token.streamBudget(), 10 ether);
        assertEq(imd.balanceOf(address(token)), 1000 ether);
        assertEq(imd.allowance(address(token), address(adapter)), 0);
        vm.expectRevert(Strike.SwapFailed.selector);
        token.processStrikeBurn(5 ether);
        assertEq(token.pendingStrikeBurn(), 10 ether);
        assertEq(imd.allowance(address(token), address(adapter)), 0);
        vm.expectRevert(Strike.InvalidAnswer.selector);
        token.submitOvertime(20, vm.getBlockTimestamp(), day, abi.encodePacked(r, s, v));
        adapter.setBehavior(10_000, false, false);
        uint256 supply = token.totalSupply();
        token.processStrikeBurn(3 ether);
        assertEq(token.pendingStrikeBurn(), 7 ether);
        token.processStrikeBurn(type(uint256).max);
        assertEq(token.pendingStrikeBurn(), 0);
        assertEq(supply - token.totalSupply(), 10 ether);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(alice);
        token.exit();
        assertEq(imd.balanceOf(alice), 10 ether);
        _assertSolvent();
    }

    function testPoolManagerMarketRoutesAndOperatorPayDues() public {
        token.transfer(manager, 30_000 ether);
        uint256 supply = token.totalSupply();
        vm.prank(manager);
        token.transfer(market, 10_000 ether);
        vm.prank(market);
        token.transfer(manager, 10_000 ether);
        vm.prank(alice);
        token.approve(manager, 10_000 ether);
        vm.prank(manager);
        token.transferFrom(alice, market, 10_000 ether);
        assertEq(token.pendingFund(), 300 ether);
        assertEq(token.pendingImdBurn(), 150 ether);
        assertEq(supply - token.totalSupply(), 150 ether);
        _assertSolvent();
    }

    function testFallbackLeavesSignerRecoveryWindow() public {
        vm.warp(token.genesis() + 2 days);
        token.fallbackOvertime();
        uint256 fallbackAt = vm.getBlockTimestamp();
        vm.warp(fallbackAt + 1 days);
        vm.expectRevert(Strike.TooSoon.selector);
        token.fallbackOvertime();
        _answer(15);
        assertEq(token.lastAnswerAt(), vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 2 days);
        token.fallbackOvertime();
        vm.warp(vm.getBlockTimestamp() + 2 days - 1);
        vm.expectRevert(Strike.TooSoon.selector);
        token.fallbackOvertime();
        vm.warp(vm.getBlockTimestamp() + 1);
        token.fallbackOvertime();
    }

    function testFallbackAndBargainDeferUnavailableMarket() public {
        _fees();
        _stake(alice, 100 ether, 30);
        adapter.setBehavior(10_000, true, false);
        vm.warp(token.genesis() + 2 days);
        token.fallbackOvertime();
        assertEq(token.pendingStrikeBurn(), 0.5 ether);
        assertEq(token.fund(), 999 ether);
        vm.warp(token.genesis() + 7 days);
        assertEq(token.executeBargain(0), 0);
        (, bool executed) = token.ballot(0);
        assertTrue(executed);
        assertEq(token.pendingStrikeBurn(), 10.49 ether);
        assertEq(token.fund(), 989.01 ether);
        _assertSolvent();
    }

    function testBurnQueueAccessReentrancyAndEmptyActions() public {
        vm.expectRevert(Strike.SwapFailed.selector);
        token.executeStrikeBurn(1);
        vm.expectRevert(Strike.InvalidAmount.selector);
        token.processStrikeBurn(0);
        vm.expectRevert(Strike.InvalidAmount.selector);
        token.processStrikeBurn(type(uint256).max);
        _fees();
        adapter.setBehavior(10_000, true, false);
        _answer(20);
        adapter.setBehavior(10_000, false, true);
        token.processStrikeBurn(type(uint256).max);
        assertFalse(adapter.reentrySucceeded());
        assertEq(token.pendingStrikeBurn(), 0);
        _assertSolvent();
    }

    function testMaturedPositionRetainsItsPromisedWeightUntilExit() public {
        _fees();
        _stake(alice, 100 ether, 180);
        vm.warp(vm.getBlockTimestamp() + 181 days);
        _stake(bob, 100 ether, 7);
        assertEq(token.totalWeight(), 500 ether);
        _answer(20);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(token.earned(alice), 4 * token.earned(bob));
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        token.exit();
        assertEq(token.balanceOf(alice) - beforeBalance, 100 ether);
    }

    function testFuzzEachDailyStreamFinishesWithinSevenDays(uint64 jobsSeed) public {
        _fees();
        _stake(alice, 100 ether, 180);
        uint256 start = vm.getBlockTimestamp();
        uint256 expectedUnreleased;
        uint256 totalStreams;
        for (uint256 i; i < 8; ++i) {
            vm.warp(start + i * 1 days);
            uint256 jobs = 1 + (uint256(jobsSeed) >> (i * 8)) % 30;
            uint256 spend = jobs * 1 ether;
            if (spend > token.fund() / 50) spend = token.fund() / 50;
            uint256 stream = spend - spend / 2;
            totalStreams += stream;
            expectedUnreleased += stream - stream * (7 - i) / 7;
            _answer(jobs);
        }
        assertEq(token.streamBudget() - token.streamReleased(), expectedUnreleased);
        assertApproxEqAbs(token.earned(alice), totalStreams - expectedUnreleased, 8);
        vm.warp(start + 14 days);
        assertApproxEqAbs(token.earned(alice), totalStreams, 10);
        _assertSolvent();
    }

    function testVoteUsesStakeAndRankNotRewardMultiplierAndLocksPosition() public {
        _fees();
        _stake(alice, 100 ether, 7);
        _stake(bob, 100 ether, 180);
        vm.prank(alice);
        vm.expectRevert(Strike.InvalidVote.selector);
        token.vote(1);
        vm.warp(token.genesis() + 7 days);
        vm.prank(alice);
        token.vote(1);
        vm.prank(bob);
        token.vote(2);
        (uint256[3] memory votes,) = token.ballot(1);
        assertEq(votes[1], 125 ether);
        assertEq(votes[2], 125 ether);
        vm.prank(alice);
        vm.expectRevert(Strike.InvalidVote.selector);
        token.vote(1);
        vm.prank(alice);
        vm.expectRevert(Strike.VoteLocked.selector);
        token.exit();
        vm.warp(token.genesis() + 14 days);
        uint256 supply = token.totalSupply();
        assertEq(token.executeBargain(1), 0); // B/C highest tie still goes to A.
        assertEq(supply - token.totalSupply(), 10 ether);
        assertEq(token.fund(), 990 ether);
        vm.prank(alice);
        token.exit();
        vm.expectRevert(Strike.InvalidVote.selector);
        token.executeBargain(1);
        _assertSolvent();
    }

    function testBargainingBAndCAndDefaultTie() public {
        _fees();
        _stake(alice, 100 ether, 180);
        vm.warp(token.genesis() + 7 days);
        vm.prank(alice);
        token.vote(1);
        vm.warp(token.genesis() + 14 days);
        uint256 before = imd.balanceOf(token.DEAD());
        assertEq(token.executeBargain(1), 1);
        assertEq(imd.balanceOf(token.DEAD()) - before, 10 ether);
        vm.prank(alice);
        token.vote(2);
        vm.warp(token.genesis() + 21 days);
        assertEq(token.executeBargain(2), 2);
        assertEq(token.streamBudget(), 9.9 ether);
        vm.warp(token.genesis() + 28 days);
        assertEq(token.executeBargain(3), 0);
        _assertSolvent();
    }

    function testCannotVoteWithRecycledOrSameWeekStakeOrExecuteOldWeeks() public {
        _fees();
        vm.warp(token.genesis() + 7 days);
        _stake(alice, 100 ether, 7);
        vm.prank(alice);
        vm.expectRevert(Strike.InvalidVote.selector);
        token.vote(1);
        vm.prank(bob);
        vm.expectRevert(Strike.InvalidVote.selector);
        token.vote(1);
        vm.warp(token.genesis() + 21 days);
        vm.expectRevert(Strike.InvalidVote.selector);
        token.executeBargain(0);
        vm.expectRevert(Strike.InvalidVote.selector);
        token.executeBargain(3);
    }

    function testCardsAreFreeUniqueSoulboundLiveAndGold() public {
        vm.prank(alice);
        uint256 id = cards.mint();
        assertEq(cards.ownerOf(id), alice);
        assertTrue(cards.locked(id));
        assertTrue(cards.supportsInterface(0x80ac58cd));
        assertTrue(cards.supportsInterface(0xb45a3c0e));
        vm.prank(alice);
        vm.expectRevert(UnionCard.Ineligible.selector);
        cards.mint();
        vm.prank(alice);
        vm.expectRevert(UnionCard.Soulbound.selector);
        cards.transferFrom(alice, bob, id);
        vm.prank(alice);
        vm.expectRevert(UnionCard.Soulbound.selector);
        cards.approve(bob, id);
        vm.prank(alice);
        vm.expectRevert(UnionCard.Soulbound.selector);
        cards.setApprovalForAll(bob, true);
        assertFalse(cards.gold(alice));
        bytes32 before = keccak256(bytes(cards.tokenURI(id)));
        NFTProbe probe = new NFTProbe();
        vm.etch(cards.IDENTITY_MD(), address(probe).code);
        NFTProbe(cards.IDENTITY_MD()).give(alice);
        assertTrue(cards.gold(alice));
        assertTrue(keccak256(bytes(cards.tokenURI(id))) != before);
        before = keccak256(bytes(cards.tokenURI(id)));
        _stake(alice, 100 ether, 7);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        assertTrue(keccak256(bytes(cards.tokenURI(id))) != before);
        vm.prank(address(0xBAD));
        vm.expectRevert(UnionCard.Ineligible.selector);
        cards.mint();
        vm.expectRevert();
        cards.tokenURI(0);
    }

    function testStakerWithNoLiquidBalanceCanMintCard() public {
        _stake(alice, token.balanceOf(alice), 7);
        vm.prank(alice);
        uint256 id = cards.mint();
        assertEq(cards.ownerOf(id), alice);
        vm.prank(alice);
        token.exit();
        uint256 liquid = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(bob, liquid);
        assertEq(cards.ownerOf(id), alice); // Permanent card; metadata becomes inactive.
    }

    function testFuzzFeeConservation(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(alice));
        uint256 supply = token.totalSupply();
        uint256 seller = token.balanceOf(alice);
        uint256 pool = token.balanceOf(market);
        vm.prank(alice);
        token.transfer(market, amount);
        assertEq(supply - token.totalSupply(), amount / 200);
        assertEq(seller - token.balanceOf(alice), amount);
        assertEq(token.balanceOf(market) - pool, amount - amount / 200 * 2 - amount / 100);
        assertEq(token.balanceOf(address(token)), amount / 200 + amount / 100);
        _assertSolvent();
    }

    function testFuzzEarlyExitPrincipalConservation(uint256 amount, uint8 term) public {
        amount = bound(amount, 1, token.balanceOf(alice));
        uint256[4] memory terms = [uint256(7), 30, 90, 180];
        uint256 before = token.balanceOf(alice);
        uint256 supply = token.totalSupply();
        _stake(alice, amount, terms[term % 4]);
        vm.prank(alice);
        token.exit();
        assertEq(before - token.balanceOf(alice), amount / 5);
        assertEq(supply - token.totalSupply(), amount / 5);
        assertEq(token.totalStaked(), 0);
        _assertSolvent();
    }

    function testFuzzRewardSolvency(uint96 aliceStake, uint96 bobStake, uint32 elapsed, bool earlyAlice) public {
        uint256 a = bound(aliceStake, 1, 1_000_000 ether);
        uint256 b = bound(bobStake, 1, 1_000_000 ether);
        _fees();
        _stake(alice, a, 7);
        _stake(bob, b, 30);
        _answer(20);
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 1, 40 days));
        if (earlyAlice) {
            vm.prank(alice);
            token.exit();
        }
        _assertSolvent();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        if (!earlyAlice) {
            vm.prank(alice);
            token.exit();
        }
        vm.prank(bob);
        token.exit();
        assertLe(imd.balanceOf(alice) + imd.balanceOf(bob), 10 ether);
        assertEq(token.totalStaked(), 0);
        _assertSolvent();
    }
}
