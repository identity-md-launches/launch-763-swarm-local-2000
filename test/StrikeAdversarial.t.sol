// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strike} from "src/Strike.sol";
import {V2TwapSwap} from "src/V2TwapSwap.sol";
import {UnionCard} from "src/UnionCard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {StrikeFixture} from "./helpers/StrikeFixture.sol";

/// @dev The receiver attacks mint from inside ERC721's external callback.
contract CardReceiver {
    UnionCard public immutable cards;
    bool public reject;
    bool public duplicateSucceeded;
    bool public transferSucceeded;

    constructor(UnionCard c) {
        cards = c;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function mint() external returns (uint256) {
        return cards.mint();
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(cards));
        (duplicateSucceeded,) = address(cards).call(abi.encodeCall(UnionCard.mint, ()));
        (transferSucceeded,) = address(cards)
            .call(abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), address(0xBAD), id));
        require(!reject, "receiver rejected card");
        return this.onERC721Received.selector;
    }
}

/// @dev Gives the promised output but spends one wei less input. Balance validation must reject it.
contract PartialInputSwap {
    IERC20 public immutable strike;
    IERC20 public immutable imd;

    constructor(IERC20 s, IERC20 i) {
        strike = s;
        imd = i;
    }

    function quote(address, uint256 input) external pure returns (uint256) {
        return input;
    }

    function swap(address input, uint256 amount, uint256, address to) external returns (uint256) {
        IERC20(input).transferFrom(msg.sender, address(this), amount - 1);
        (input == address(strike) ? imd : strike).transfer(to, amount);
        return amount;
    }
}

contract StrikeAdversarialTest is StrikeFixture {
    function _accountingHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                strike.totalSupply(),
                strike.balanceOf(address(strike)),
                reward.balanceOf(address(strike)),
                strike.pendingFund(),
                strike.pendingImdBurn(),
                strike.fund(),
                strike.totalStaked(),
                strike.totalWeight(),
                strike.rewardLiability(),
                strike.rewardPerWeight(),
                strike.streamBudget(),
                strike.streamReleased(),
                strike.pendingStrikeBurn()
            )
        );
    }

    function testAllZeroConstructorFieldsAndWrongFactoryAreRejected() public {
        address factory = address(swapper.v2Factory());
        bytes32 initHash = swapper.pairInitCodeHash();
        address signer = vm.addr(ORACLE_KEY);
        for (uint256 i; i < 9; ++i) {
            vm.expectRevert(Strike.InvalidConfiguration.selector);
            new Strike(
                i == 0 ? address(0) : i == 8 ? actors[0] : address(this),
                i == 1 ? address(0) : address(0x4444),
                1,
                i == 2 ? address(0) : address(reward),
                i == 3 ? address(0) : factory,
                i == 4 ? bytes32(0) : initHash,
                i == 5 ? address(0) : signer,
                i == 6 ? 0 : 1,
                i == 7 ? 0 : 1
            );
        }
    }

    function testInsufficientBalanceStakeRollsBackPositionAndCheckpoint() public {
        _fund();
        _answer(10);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bytes32 beforeState = _accountingHash();
        uint256 liquid = strike.balanceOf(actors[0]);
        vm.prank(actors[0]);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, actors[0], liquid, liquid + 1)
        );
        strike.stake(liquid + 1, 7);
        assertEq(_accountingHash(), beforeState);
        (uint256 amount,,,,,,) = strike.stakes(actors[0]);
        assertEq(amount, 0);
    }

    function testMaxUintTransfersAndBurnsRevertWithoutChangingFeesOrSeniority() public {
        bytes32 state = _accountingHash();
        uint256 start = strike.holdStart(actors[0]);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.startPrank(actors[0]);
        vm.expectRevert();
        strike.transfer(address(pool), type(uint256).max);
        vm.expectRevert();
        strike.burn(type(uint256).max);
        vm.stopPrank();
        assertEq(_accountingHash(), state);
        assertEq(strike.holdStart(actors[0]), start);
    }

    function testInfiniteAllowanceAndFailedFiniteAllowanceAreAtomic() public {
        vm.prank(actors[0]);
        strike.approve(actors[1], type(uint256).max);
        vm.prank(actors[1]);
        strike.transferFrom(actors[0], address(pool), 200 ether);
        assertEq(strike.allowance(actors[0], actors[1]), type(uint256).max);
        vm.prank(actors[0]);
        strike.approve(actors[1], 1 ether);
        bytes32 state = _accountingHash();
        vm.prank(actors[1]);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, actors[1], 1 ether, 2 ether)
        );
        strike.transferFrom(actors[0], address(pool), 2 ether);
        assertEq(strike.allowance(actors[0], actors[1]), 1 ether);
        assertEq(_accountingHash(), state);
    }

    function testFullSupplyCanStakeAndExitWithoutCreatingSupply() public {
        Strike fresh = new Strike(
            address(this),
            address(0x4444),
            2,
            address(reward),
            address(swapper.v2Factory()),
            swapper.pairInitCodeHash(),
            vm.addr(ORACLE_KEY),
            1,
            1
        );
        uint256 supply = fresh.totalSupply();
        fresh.stake(supply, 180);
        assertEq(fresh.balanceOf(address(this)), 0);
        assertEq(fresh.totalStaked(), supply);
        assertEq(fresh.totalWeight(), supply * 4);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        fresh.exit();
        assertEq(fresh.balanceOf(address(this)), supply);
        assertEq(fresh.totalSupply(), supply);
        assertEq(fresh.balanceOf(address(fresh)), 0);
    }

    function testOneWeiStakeAndRepeatedExitCannotWithdrawTwice() public {
        uint256 beforeBalance = strike.balanceOf(actors[0]);
        vm.startPrank(actors[0]);
        strike.stake(1, 7);
        strike.exit();
        vm.expectRevert(Strike.NoStake.selector);
        strike.exit();
        vm.expectRevert(Strike.NoStake.selector);
        strike.claim();
        vm.stopPrank();
        assertEq(strike.balanceOf(actors[0]), beforeBalance);
        assertEq(strike.totalStaked(), 0);
        assertEq(strike.totalWeight(), 0);
    }

    function testAllLockBoundariesRejectEarlyClaimAndReturnFullPrincipalAtMaturity() public {
        _fund();
        uint256[4] memory terms = [uint256(7), 30, 90, 180];
        uint256 opened = vm.getBlockTimestamp();
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            strike.stake(100 ether, terms[i]);
        }
        _answer(10);
        for (uint256 i; i < actors.length; ++i) {
            vm.warp(opened + terms[i] * 1 days - 1);
            vm.prank(actors[i]);
            vm.expectRevert(Strike.TooSoon.selector);
            strike.claim();
            vm.warp(opened + terms[i] * 1 days);
            uint256 expectedReward = strike.earned(actors[i]);
            uint256 balance = strike.balanceOf(actors[i]);
            uint256 rewardBalance = reward.balanceOf(actors[i]);
            vm.startPrank(actors[i]);
            assertEq(strike.claim(), expectedReward);
            assertEq(strike.claim(), 0, "reward paid twice");
            strike.exit();
            vm.stopPrank();
            assertEq(strike.balanceOf(actors[i]) - balance, 100 ether);
            assertEq(reward.balanceOf(actors[i]) - rewardBalance, expectedReward);
        }
        assertEq(strike.totalStaked(), 0);
    }

    function testRankThresholdsAndIncomingDustDoNotResetHolderAge() public {
        uint256 start = strike.holdStart(actors[0]);
        uint256[6] memory ages = [uint256(1 days - 1), 1 days, 7 days - 1, 7 days, 30 days - 1, 30 days];
        uint256[6] memory bonuses = [uint256(10_000), 11_000, 11_000, 12_500, 12_500, 15_000];
        for (uint256 i; i < ages.length; ++i) {
            vm.warp(start + ages[i]);
            vm.prank(actors[1]);
            strike.transfer(actors[0], 1);
            assertEq(strike.holdStart(actors[0]), start);
            assertEq(strike.rankBonus(actors[0]), bonuses[i]);
        }
        vm.prank(actors[0]);
        strike.transfer(address(pool), 1);
        assertEq(strike.rankBonus(actors[0]), 10_000);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzInvalidLock(uint256 term) public {
        // Generate every unsupported term without discarding fuzz runs.
        if (term == 7 || term == 30 || term == 90 || term == 180) ++term;
        vm.prank(actors[0]);
        vm.expectRevert(Strike.InvalidLock.selector);
        strike.stake(1, term);
        assertEq(strike.totalStaked(), 0);
    }

    function testEmptyAndDustFeeProcessingFailsWithoutLosingPendingDues() public {
        vm.expectRevert(Strike.InvalidAmount.selector);
        strike.processFees(type(uint256).max, type(uint256).max);
        vm.prank(actors[0]);
        strike.transfer(address(pool), 200);
        bytes32 state = _accountingHash();
        vm.expectRevert(Strike.SwapFailed.selector);
        strike.processFees(1, 0);
        assertEq(_accountingHash(), state);
        assertEq(strike.pendingImdBurn(), 1);
        assertEq(strike.pendingFund(), 2);
    }

    function testAdapterCannotKeepUnspentInputEvenWhenOutputMeetsQuote() public {
        vm.prank(actors[0]);
        strike.transfer(address(pool), 1000 ether);
        PartialInputSwap malicious = new PartialInputSwap(IERC20(address(strike)), IERC20(address(reward)));
        vm.etch(address(swapper), address(malicious).code);
        reward.mint(address(swapper), 100 ether);
        bytes32 state = _accountingHash();
        vm.expectRevert(Strike.SwapFailed.selector);
        strike.processFees(5 ether, 10 ether);
        assertEq(_accountingHash(), state);
        assertEq(strike.allowance(address(strike), address(swapper)), 0);
    }

    function testAnswerDigestBindsQuestionJobsTimeDayChainAndContract() public view {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Swarm Local 2000 Overtime"),
                keccak256("1"),
                block.chainid,
                address(strike)
            )
        );
        uint256 now_ = vm.getBlockTimestamp();
        bytes32 answer = keccak256(
            abi.encode(
                keccak256("Overtime(bytes32 questionHash,uint256 jobs,uint256 observedAt,uint256 day)"),
                keccak256("jobs the IMD swarm accepted in the last 24h"),
                uint256(42),
                now_,
                now_ / 1 days
            )
        );
        assertEq(strike.answerDigest(42, now_, now_ / 1 days), keccak256(abi.encodePacked(hex"1901", domain, answer)));
    }

    function testSignedAnswerFreshnessAtOneHourAndInvalidDayBoundary() public {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 12 hours);
        uint256 now_ = vm.getBlockTimestamp();
        uint256 day = now_ / 1 days;
        bytes memory stale = _signature(ORACLE_KEY, 0, now_ - 1 hours - 1, day);
        vm.expectRevert(Strike.InvalidAnswer.selector);
        strike.submitOvertime(0, now_ - 1 hours - 1, day, stale);
        bytes memory wrongDay = _signature(ORACLE_KEY, 0, now_, day - 1);
        vm.expectRevert(Strike.InvalidAnswer.selector);
        strike.submitOvertime(0, now_, day - 1, wrongDay);
        strike.submitOvertime(0, now_ - 1 hours, day, _signature(ORACLE_KEY, 0, now_ - 1 hours, day));
        assertTrue(strike.usedDay(day));
        assertEq(strike.lastAnswerAt(), now_ - 1 hours);
    }

    function testMalformedAndMalleableSignaturesDoNotConsumeTheDay() public {
        uint256 now_ = vm.getBlockTimestamp();
        uint256 day = now_ / 1 days;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 0));
        strike.submitOvertime(0, now_, day, "");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_KEY, strike.answerDigest(0, now_, day));
        bytes32 highS = bytes32(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - uint256(s));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        strike.submitOvertime(0, now_, day, abi.encodePacked(r, highS, uint8(v == 27 ? 28 : 27)));
        assertFalse(strike.usedDay(day));
        _answer(0);
        assertTrue(strike.usedDay(day));
    }

    function testFallbackIsAvailableExactlyAfter48Hours() public {
        vm.warp(strike.lastAnswerAt() + 2 days - 1);
        vm.expectRevert(Strike.TooSoon.selector);
        strike.fallbackOvertime();
        vm.warp(vm.getBlockTimestamp() + 1);
        strike.fallbackOvertime();
        assertEq(strike.lastOvertimeAt(), vm.getBlockTimestamp());
        assertTrue(strike.usedDay(vm.getBlockTimestamp() / 1 days));
        vm.expectRevert(Strike.TooSoon.selector);
        strike.fallbackOvertime();
    }

    function testBargainDefersFailedBurnAndRetryCannotSpendOtherReserves() public {
        _fund();
        vm.prank(actors[0]);
        strike.stake(100 ether, 30);
        _answer(10);
        vm.warp(strike.genesis() + 7 days);
        _warm();
        uint256 fundBefore = strike.fund();
        uint256 spend = fundBefore / 100;
        uint256 imdBefore = reward.balanceOf(address(strike));
        uint256 supplyBefore = strike.totalSupply();
        uint256 earnedBefore = strike.earned(actors[0]);
        bytes memory quote = abi.encodeCall(V2TwapSwap.quote, (address(reward), spend));
        vm.mockCall(address(swapper), quote, abi.encode(uint256(0)));
        assertEq(strike.executeBargain(0), 0);
        (, bool executed) = strike.ballot(0);
        assertTrue(executed);
        assertEq(strike.fund(), fundBefore - spend);
        assertEq(strike.pendingStrikeBurn(), spend);
        assertEq(reward.balanceOf(address(strike)), imdBefore);
        assertEq(strike.totalSupply(), supplyBefore);
        assertEq(strike.earned(actors[0]), earnedBefore);
        bytes32 state = _accountingHash();
        vm.expectRevert(Strike.InvalidVote.selector);
        strike.executeBargain(0);
        vm.expectRevert(Strike.SwapFailed.selector);
        strike.processStrikeBurn(type(uint256).max);
        assertEq(_accountingHash(), state);
        assertEq(reward.allowance(address(strike), address(swapper)), 0);
        vm.clearMockedCalls();
        uint256 poolBefore = strike.balanceOf(address(pool));
        // A nonprivileged keeper can drain only the earmarked amount, even with an unlimited bound.
        vm.prank(actors[2]);
        strike.processStrikeBurn(type(uint256).max);
        assertEq(strike.pendingStrikeBurn(), 0);
        assertEq(reward.balanceOf(address(strike)), imdBefore - spend);
        assertEq(strike.fund(), fundBefore - spend);
        assertEq(strike.totalStaked(), 100 ether);
        assertEq(strike.earned(actors[0]), earnedBefore);
        uint256 bought = poolBefore - strike.balanceOf(address(pool));
        assertGt(bought, 0);
        assertEq(supplyBefore - strike.totalSupply(), bought);
        assertEq(reward.allowance(address(strike), address(swapper)), 0);
    }

    function testUnstakedAndOutOfRangeVotesAreRejected() public {
        vm.warp(strike.genesis() + 7 days);
        vm.prank(actors[0]);
        vm.expectRevert(Strike.InvalidVote.selector);
        strike.vote(0);
        vm.prank(actors[0]);
        strike.stake(100 ether, 30);
        vm.warp(strike.genesis() + 14 days);
        vm.prank(actors[0]);
        vm.expectRevert(Strike.InvalidVote.selector);
        strike.vote(3);
        assertFalse(strike.voted(2, actors[0]));
        vm.prank(actors[0]);
        strike.vote(2);
        assertTrue(strike.voted(2, actors[0]));
    }

    function testReceiverCannotReenterMintOrTransferAndRejectedMintCanRetry() public {
        CardReceiver receiver = new CardReceiver(card);
        strike.transfer(address(receiver), 1);
        receiver.setReject(true);
        vm.expectRevert("receiver rejected card");
        receiver.mint();
        assertFalse(card.minted(address(receiver)));
        assertEq(card.balanceOf(address(receiver)), 0);
        receiver.setReject(false);
        uint256 id = receiver.mint();
        assertFalse(receiver.duplicateSucceeded());
        assertFalse(receiver.transferSucceeded());
        assertEq(card.ownerOf(id), address(receiver));
        assertEq(card.balanceOf(address(receiver)), 1);
    }

    function testBothSafeTransferOverloadsAndOperatorApprovalAreSoulbound() public {
        vm.prank(actors[0]);
        uint256 id = card.mint();
        vm.startPrank(actors[0]);
        vm.expectRevert(UnionCard.Soulbound.selector);
        card.safeTransferFrom(actors[0], actors[1], id);
        vm.expectRevert(UnionCard.Soulbound.selector);
        card.safeTransferFrom(actors[0], actors[1], id, hex"abcd");
        vm.expectRevert(UnionCard.Soulbound.selector);
        card.setApprovalForAll(actors[1], true);
        vm.stopPrank();
        assertEq(card.ownerOf(id), actors[0]);
        assertEq(card.getApproved(id), address(0));
        assertFalse(card.isApprovedForAll(actors[0], actors[1]));
    }

    function testMalformedOrRevertingIdentityNFTCannotBreakCards() public {
        vm.prank(actors[0]);
        uint256 id = card.mint();
        bytes memory query = abi.encodeWithSignature("balanceOf(address)", actors[0]);
        vm.mockCallRevert(card.IDENTITY_MD(), query, "unavailable");
        assertFalse(card.gold(actors[0]));
        assertGt(bytes(card.tokenURI(id)).length, 0);
        vm.clearMockedCalls();
        vm.mockCall(card.IDENTITY_MD(), query, abi.encode(uint256(1), uint256(1)));
        assertFalse(card.gold(actors[0]));
        vm.clearMockedCalls();
        vm.mockCall(card.IDENTITY_MD(), query, abi.encode(uint256(1)));
        assertTrue(card.gold(actors[0]));
        vm.clearMockedCalls();
        assertFalse(card.gold(actors[0]));
    }
}
