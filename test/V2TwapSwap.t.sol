// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Strike} from "../src/Strike.sol";
import {V2TwapSwap} from "../src/V2TwapSwap.sol";
import {MockIMD} from "./Strike.t.sol";
import {PairModel, FactoryModel} from "./PairModel.sol";

contract V2TwapSwapTest is Test {
    Strike internal token;
    MockIMD internal imd;
    V2TwapSwap internal adapter;
    PairModel internal pair;
    FactoryModel internal factory;
    address internal alice = address(0xA11CE);
    uint256 internal signerKey = 0x1234;

    function setUp() public {
        vm.warp(1_700_000_000);
        imd = new MockIMD();
        factory = new FactoryModel();
        token = new Strike(
            address(this),
            address(0x4444),
            1,
            address(imd),
            address(factory),
            keccak256(type(PairModel).creationCode),
            vm.addr(signerKey),
            1 ether,
            1 ether
        );
        adapter = V2TwapSwap(address(token.swapAdapter()));
        pair = PairModel(token.market());
        adapter.prepareMarket();
        token.transfer(address(pair), 10_000_000 ether);
        imd.mint(address(pair), 10_000_000 ether);
        token.transfer(alice, 1_000_000 ether);
        imd.mint(alice, 1_000_000 ether);
        pair.sync();
    }

    function _warm() private {
        adapter.updateOracle();
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        adapter.updateOracle();
    }

    function testObservationWarmupFreshnessAndRecovery() public {
        vm.expectRevert(V2TwapSwap.OracleNotReady.selector);
        adapter.quote(address(token), 1 ether);
        adapter.updateOracle();
        vm.expectRevert(V2TwapSwap.ObservationTooSoon.selector);
        adapter.updateOracle();
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        adapter.updateOracle();
        assertEq(adapter.quote(address(token), 1 ether), 1 ether);
        assertEq(adapter.quote(address(imd), 1 ether), 1 ether);
        vm.warp(vm.getBlockTimestamp() + 2 hours + 1);
        vm.expectRevert(V2TwapSwap.OracleNotReady.selector);
        adapter.quote(address(token), 1 ether);
        adapter.updateOracle();
        assertFalse(adapter.ready());
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        adapter.updateOracle();
        assertTrue(adapter.ready());
    }

    function testTaxedTradingBothDirectionsWithActualKInvariant() public {
        _warm();
        vm.startPrank(alice);
        token.approve(address(adapter), 1000 ether);
        uint256 received = adapter.swap(address(token), 1000 ether, 970 ether, alice);
        assertGe(received, 970 ether);
        assertEq(token.pendingFund(), 10 ether);
        assertEq(token.pendingImdBurn(), 5 ether);
        imd.approve(address(adapter), 1000 ether);
        received = adapter.swap(address(imd), 1000 ether, 970 ether, alice);
        assertGe(received, 970 ether);
        vm.stopPrank();
        assertGt(token.pendingFund(), 19 ether);
        assertLt(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    function testTreasuryFeesOvertimeAndBurnEndToEnd() public {
        _warm();
        vm.startPrank(alice);
        token.approve(address(adapter), 100_000 ether);
        // Split trades so individual TWAP slippage remains bounded.
        for (uint256 i; i < 10; ++i) {
            adapter.swap(address(token), 1000 ether, 970 ether, alice);
        }
        token.stake(100 ether, 7);
        vm.stopPrank();
        uint256 principal = token.totalStaked();
        token.processFees(type(uint256).max, type(uint256).max);
        assertEq(token.totalStaked(), principal);
        assertEq(token.pendingFund(), 0);
        assertEq(token.pendingImdBurn(), 0);
        assertGt(token.fund(), 99 ether);
        assertGt(imd.balanceOf(token.DEAD()), 49 ether);
        uint256 beforeFund = token.fund();
        uint256 supply = token.totalSupply();
        uint256 now_ = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, token.answerDigest(1000, now_, now_ / 1 days));
        token.submitOvertime(1000, now_, now_ / 1 days, abi.encodePacked(r, s, v));
        assertEq(token.fund(), beforeFund - beforeFund / 50);
        assertLt(token.totalSupply(), supply);
        assertEq(imd.allowance(address(token), address(adapter)), 0);
        assertEq(token.allowance(address(token), address(adapter)), 0);
        vm.warp(now_ + 7 days);
        vm.prank(alice);
        token.exit();
        assertEq(token.totalStaked(), 0);
        assertGe(imd.balanceOf(address(token)), token.fund() + token.rewardLiability());
    }

    function testTreasuryCustodyLeavesDonationsAndDoesNotChargeDues() public {
        _warm();
        token.transfer(address(adapter), 123 ether);
        imd.mint(address(adapter), 456 ether);
        vm.startPrank(alice);
        token.approve(address(adapter), 1000 ether);
        adapter.swap(address(token), 1000 ether, 970 ether, alice);
        vm.stopPrank();
        token.processFees(type(uint256).max, type(uint256).max);
        uint256 now_ = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, token.answerDigest(1000, now_, now_ / 1 days));
        token.submitOvertime(1000, now_, now_ / 1 days, abi.encodePacked(r, s, v));
        assertEq(token.pendingStrikeBurn(), 0);
        assertEq(token.pendingFund(), 0);
        assertEq(token.pendingImdBurn(), 0);
        assertEq(token.balanceOf(address(adapter)), 123 ether);
        assertEq(imd.balanceOf(address(adapter)), 456 ether);
    }

    function testPublicSwapsCannotUseTreasuryCustodyOrTokenRecipients() public {
        _warm();
        address[3] memory forbidden = [address(adapter), address(token), address(imd)];
        vm.startPrank(alice);
        imd.approve(address(adapter), 1000 ether);
        for (uint256 i; i < forbidden.length; ++i) {
            vm.expectRevert(V2TwapSwap.InvalidSwap.selector);
            adapter.swap(address(imd), 1000 ether, 970 ether, forbidden[i]);
        }
        vm.stopPrank();
    }

    function testDefaultBargainUsesValidV2Recipient() public {
        _warm();
        vm.prank(alice);
        token.transfer(address(pair), 1000 ether);
        pair.sync();
        token.processFees(type(uint256).max, type(uint256).max);
        vm.warp(token.genesis() + 7 days + 1);
        _warm();
        uint256 supply = token.totalSupply();
        uint256 beforeFund = token.fund();
        assertEq(token.executeBargain(0), 0);
        assertEq(token.fund(), beforeFund - beforeFund / 100);
        assertEq(token.pendingStrikeBurn(), 0);
        assertLt(token.totalSupply(), supply);
    }

    function testThinPoolDefersBurnAndBoundedBatchesDrainIt() public {
        _warm();
        vm.startPrank(alice);
        token.approve(address(adapter), 1000 ether);
        adapter.swap(address(token), 1000 ether, 970 ether, alice);
        vm.stopPrank();
        token.processFees(type(uint256).max, type(uint256).max);
        // Simulate liquidity withdrawal to the factory, leaving a thin 1:1 pool.
        uint256 strikeWithdrawal = token.balanceOf(address(pair)) - 1 ether;
        uint256 imdWithdrawal = imd.balanceOf(address(pair)) - 1 ether;
        vm.startPrank(address(pair));
        token.transfer(address(this), strikeWithdrawal);
        imd.transfer(address(this), imdWithdrawal);
        vm.stopPrank();
        pair.sync();
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        adapter.updateOracle();
        uint256 now_ = vm.getBlockTimestamp();
        uint256 beforeFund = token.fund();
        uint256 spend = beforeFund / 50;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, token.answerDigest(1000, now_, now_ / 1 days));
        token.submitOvertime(1000, now_, now_ / 1 days, abi.encodePacked(r, s, v));
        assertEq(token.fund(), beforeFund - spend);
        assertEq(token.pendingStrikeBurn(), spend / 2);
        assertEq(token.streamBudget(), spend - spend / 2);
        assertTrue(token.usedDay(now_ / 1 days));
        uint256 supply = token.totalSupply();
        uint256 batch = spend / 20 + 1;
        for (uint256 i; i < 10; ++i) {
            vm.warp(vm.getBlockTimestamp() + 30 minutes);
            adapter.updateOracle();
            token.processStrikeBurn(batch);
        }
        assertEq(token.pendingStrikeBurn(), 0);
        assertLt(token.totalSupply(), supply);
        assertEq(token.pendingFund(), 0);
        assertEq(token.pendingImdBurn(), 0);
        assertEq(imd.allowance(address(token), address(adapter)), 0);
        assertGe(
            imd.balanceOf(address(token)),
            token.fund() + token.pendingStrikeBurn() + token.rewardLiability() + token.streamBudget()
                - token.streamReleased()
        );
    }

    function testGrossTwapFloorIncludesDuesAndLimitsPublicTradeSize() public {
        _warm();
        vm.startPrank(alice);
        imd.approve(address(adapter), 150_000 ether);
        vm.expectRevert(V2TwapSwap.InvalidSwap.selector);
        adapter.swap(address(imd), 100_000 ether, 97_000 ether, alice);
        assertGe(adapter.swap(address(imd), 50_000 ether, 48_500 ether, alice), 48_500 ether);
        vm.stopPrank();
    }

    function testSpotManipulationDoesNotReplaceTwap() public {
        _warm();
        uint256 oldQuote = adapter.quote(address(token), 1 ether);
        // Halve the spot STRIKE price in this block while the elapsed TWAP remains unchanged.
        token.transfer(address(pair), 10_000_000 ether);
        pair.sync();
        assertEq(adapter.quote(address(token), 1 ether), oldQuote);
        vm.startPrank(alice);
        token.approve(address(adapter), 1000 ether);
        vm.expectRevert(V2TwapSwap.InvalidSwap.selector);
        adapter.swap(address(token), 1000 ether, 970 ether, alice);
        vm.stopPrank();
        assertEq(token.pendingFund(), 0);
        // A direct token sell transfer still works despite stale/disagreeing prices.
        vm.prank(alice);
        token.transfer(address(pair), 100 ether);
        assertEq(token.pendingFund(), 1 ether);
    }

    function testMinOutCannotBeDisabledAndUnknownTokensRejected() public {
        _warm();
        vm.expectRevert(V2TwapSwap.InvalidSwap.selector);
        adapter.quote(address(0xBAD), 100);
        vm.expectRevert(V2TwapSwap.InvalidSwap.selector);
        adapter.swap(address(token), 100, 0, alice);
        vm.expectRevert(V2TwapSwap.InvalidSwap.selector);
        adapter.swap(address(token), 1000, 1, alice);
        vm.expectRevert(V2TwapSwap.InvalidSwap.selector);
        adapter.swap(address(token), 100, 97, address(pair));
        vm.expectRevert(V2TwapSwap.InvalidPair.selector);
        new V2TwapSwap(address(factory), bytes32(0), address(token), address(imd));
    }

    function testMarketPreparationIsIdempotentAndWrongInitCodeHashFails() public {
        assertEq(adapter.prepareMarket(), address(pair));
        V2TwapSwap wrong = new V2TwapSwap(address(factory), bytes32(uint256(123)), address(token), address(imd));
        vm.expectRevert(V2TwapSwap.InvalidPair.selector);
        wrong.prepareMarket();
    }

    function testTimestampWrapAndNon18DecimalPrice() public {
        vm.warp(uint256(type(uint32).max) - 900);
        pair.sync();
        adapter.updateOracle();
        vm.warp(vm.getBlockTimestamp() + 1800);
        adapter.updateOracle();
        assertEq(adapter.quote(address(token), 1 ether), 1 ether);
        // Unit amounts, not decimal metadata, determine ratios: reset a second pair to a 1e12 ratio.
        MockIMD six = new MockIMD();
        address secondPair = factory.createPair(address(token), address(six));
        token.transfer(secondPair, 1_000_000 ether);
        six.mint(secondPair, 1_000_000 * 1e6);
        PairModel(secondPair).sync();
        V2TwapSwap second =
            new V2TwapSwap(address(factory), keccak256(type(PairModel).creationCode), address(token), address(six));
        second.updateOracle();
        vm.warp(vm.getBlockTimestamp() + 1800);
        second.updateOracle();
        assertApproxEqAbs(second.quote(address(token), 1 ether), 1e6, 1);
        assertEq(second.quote(address(six), 1e6), 1 ether);
    }

    function testCreate2StaticDeploymentHasNoAddressCycleOrSupplyMovement() public {
        bytes32 salt = keccak256("launch");
        bytes memory creation = abi.encodePacked(
            type(Strike).creationCode,
            abi.encode(
                address(this),
                address(0x4444),
                uint64(22),
                address(imd),
                address(factory),
                keccak256(type(PairModel).creationCode),
                vm.addr(signerKey),
                1 ether,
                1 ether
            )
        );
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(creation)))))
        );
        Strike fresh = new Strike{salt: salt}(
            address(this),
            address(0x4444),
            22,
            address(imd),
            address(factory),
            keccak256(type(PairModel).creationCode),
            vm.addr(signerKey),
            1 ether,
            1 ether
        );
        assertEq(address(fresh), predicted);
        assertEq(fresh.balanceOf(address(this)), 1_000_000_000 ether);
        assertEq(fresh.totalSupply(), 1_000_000_000 ether);
        assertEq(factory.getPair(predicted, address(imd)), address(0));
        V2TwapSwap(address(fresh.swapAdapter())).prepareMarket();
        assertEq(fresh.market(), factory.getPair(predicted, address(imd)));
        assertGt(address(fresh.swapAdapter()).code.length, 0);
        assertLt(creation.length, 49_153);
        assertLt(address(fresh).code.length, 24_577);
    }

    function testRuntimeHasNoForbiddenOpcodes() public view {
        bytes memory code = address(token).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function testFuzzSmallTradesConserveSupplyAndFees(uint256 amount, bool buy) public {
        _warm();
        amount = bound(amount, 1 ether, 1000 ether);
        uint256 supply = token.totalSupply();
        vm.startPrank(alice);
        if (buy) {
            imd.approve(address(adapter), amount);
            adapter.swap(address(imd), amount, amount * 9700 / 10_000, alice);
        } else {
            token.approve(address(adapter), amount);
            adapter.swap(address(token), amount, amount * 9700 / 10_000, alice);
        }
        vm.stopPrank();
        assertEq(supply - token.totalSupply(), token.pendingImdBurn());
        assertEq(token.balanceOf(address(token)), token.pendingFund() + token.pendingImdBurn());
    }
}
