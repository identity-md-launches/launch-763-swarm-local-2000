// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Strike} from "src/Strike.sol";
import {V2TwapSwap} from "src/V2TwapSwap.sol";
import {UnionCard} from "src/UnionCard.sol";
import {MockIMD} from "./Strike.t.sol";
import {PairModel} from "./PairModel.sol";
import {StrikeFixture} from "./helpers/StrikeFixture.sol";

contract StrikeHandler is Test {
    Strike public immutable token;
    MockIMD public immutable imd;
    V2TwapSwap public immutable adapter;
    PairModel public immutable pair;
    UnionCard public immutable cards;
    address[4] public actors;
    uint256 public deposited;
    uint256 public returnedPrincipal;
    uint256 public penalties;
    uint256 public strikeDonations;
    uint256 public imdDonations;
    uint256 public netFees;
    uint256 public fundOutflows;
    uint256 public rewardsPaid;
    uint256 public burned;
    uint256 public burnCommitted;
    uint256 public burnSpent;
    uint256 public scheduledRewards;
    uint256 public checkpointAt;

    struct RewardGrant {
        uint256 amount;
        uint256 start;
    }
    RewardGrant[] private grants;
    mapping(bytes4 => uint256) public calls;
    uint256 private constant SIGNER_KEY = 0x5151;

    constructor(Strike t, MockIMD i, UnionCard c, address[4] memory users) {
        token = t;
        imd = i;
        cards = c;
        adapter = V2TwapSwap(address(t.swapAdapter()));
        pair = PairModel(t.market());
        actors = users;
    }

    // Independent history of funded grants: never read the contract's private tranche bookkeeping.
    function vestedRewards(uint256 at) public view returns (uint256 vested) {
        for (uint256 i; i < grants.length; ++i) {
            RewardGrant memory grant = grants[i];
            if (at <= grant.start) continue;
            uint256 age = at - grant.start;
            vested += age >= 7 days ? grant.amount : grant.amount * age / 7 days;
        }
    }

    function _schedule(uint256 amount) private {
        if (amount == 0) return;
        grants.push(RewardGrant(amount, vm.getBlockTimestamp()));
        scheduledRewards += amount;
        checkpointAt = vm.getBlockTimestamp();
    }

    function advance(uint256 elapsed) public {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 14 days));
        calls[this.advance.selector]++;
    }

    function _warm() private {
        if (vm.getBlockTimestamp() - adapter.observationAt() >= 30 minutes) adapter.updateOracle();
        if (!adapter.ready()) {
            vm.warp(vm.getBlockTimestamp() + 30 minutes);
            adapter.updateOracle();
        }
    }

    function trade(uint256 who, uint256 seed, bool buy) public {
        address user = actors[who % 4];
        uint256 liquid = buy ? imd.balanceOf(user) : token.balanceOf(user);
        if (liquid < 1 ether) return;
        // Small relative to reserves, so a fresh TWAP must permit both taxed directions.
        uint256 amount = bound(seed, 1 ether, liquid < 1000 ether ? liquid : 1000 ether);
        _warm();
        uint256 poolBefore = token.balanceOf(address(pair));
        uint256 minimum = adapter.quote(buy ? address(imd) : address(token), amount) * 9700 / 10_000;
        vm.startPrank(user);
        if (buy) imd.approve(address(adapter), amount);
        else token.approve(address(adapter), amount);
        uint256 output = adapter.swap(buy ? address(imd) : address(token), amount, minimum, user);
        vm.stopPrank();
        assertGe(output, minimum);
        burned += (buy ? poolBefore - token.balanceOf(address(pair)) : amount) / 200;
        calls[this.trade.selector]++;
    }

    function transferOrBurn(uint256 from, uint256 to, uint256 seed, bool burnTokens) public {
        address user = actors[from % 4];
        uint256 amount = bound(seed, 0, token.balanceOf(user));
        vm.prank(user);
        if (burnTokens) {
            token.burn(amount);
            burned += amount;
        } else {
            token.transfer(actors[to % 4], amount);
        }
        calls[this.transferOrBurn.selector]++;
    }

    function deposit(uint256 who, uint256 seed, uint256 term) public {
        address user = actors[who % 4];
        (uint256 existing,,,,,,) = token.stakes(user);
        uint256 liquid = token.balanceOf(user);
        if (existing != 0 || liquid == 0) return;
        uint256 amount = bound(seed, 1, liquid);
        uint256[4] memory terms = [uint256(7), 30, 90, 180];
        uint256 seniority = token.holdStart(user);
        vm.prank(user);
        token.stake(amount, terms[term % 4]);
        deposited += amount;
        checkpointAt = vm.getBlockTimestamp();
        assertEq(token.holdStart(user), seniority, "staking reset seniority");
        calls[this.deposit.selector]++;
    }

    function withdraw(uint256 who) public {
        address user = actors[who % 4];
        (uint256 amount,, uint256 unlockAt,,, uint256 voteLock,) = token.stakes(user);
        if (amount == 0) return;
        if (vm.getBlockTimestamp() < voteLock) {
            vm.prank(user);
            vm.expectRevert(Strike.VoteLocked.selector);
            token.exit();
            return;
        }
        uint256 penalty = vm.getBlockTimestamp() < unlockAt ? amount / 5 : 0;
        uint256 liquid = token.balanceOf(user);
        uint256 beforeReward = imd.balanceOf(user);
        uint256 accrued = token.earned(user);
        vm.prank(user);
        token.exit();
        checkpointAt = vm.getBlockTimestamp();
        assertEq(token.balanceOf(user) - liquid, amount - penalty, "incorrect principal returned");
        uint256 paid = imd.balanceOf(user) - beforeReward;
        assertEq(paid, vm.getBlockTimestamp() < unlockAt ? 0 : accrued, "incorrect exit reward");
        returnedPrincipal += amount - penalty;
        penalties += penalty;
        burned += penalty;
        rewardsPaid += paid;
        calls[this.withdraw.selector]++;
    }

    function claim(uint256 who) public {
        address user = actors[who % 4];
        (uint256 amount,, uint256 unlockAt,,,,) = token.stakes(user);
        if (amount == 0) return;
        if (vm.getBlockTimestamp() < unlockAt) {
            vm.prank(user);
            vm.expectRevert(Strike.TooSoon.selector);
            token.claim();
            return;
        }
        uint256 beforeReward = imd.balanceOf(user);
        uint256 earned = token.earned(user);
        vm.prank(user);
        uint256 paid = token.claim();
        checkpointAt = vm.getBlockTimestamp();
        assertEq(paid, earned);
        assertEq(imd.balanceOf(user) - beforeReward, paid);
        rewardsPaid += paid;
        calls[this.claim.selector]++;
    }

    function process(uint256 burnSeed, uint256 fundSeed) public {
        uint256 burnInput = bound(burnSeed, 0, token.pendingImdBurn());
        uint256 fundInput = bound(fundSeed, 0, token.pendingFund());
        if (burnInput + fundInput < 10_000) return; // Dust conversion is tested separately.
        _warm();
        uint256 beforeReward = imd.balanceOf(address(token));
        token.processFees(burnInput, fundInput);
        netFees += imd.balanceOf(address(token)) - beforeReward;
        calls[this.process.selector]++;
    }

    function overtime(uint256 jobs, bool fallbackMode) public {
        uint256 now_ = vm.getBlockTimestamp();
        uint256 day = now_ / 1 days;
        if (token.usedDay(day)) return;
        if (fallbackMode) {
            uint256 latest =
                token.lastAnswerAt() > token.lastOvertimeAt() ? token.lastAnswerAt() : token.lastOvertimeAt();
            if (now_ < latest + 2 days) return;
        }
        uint256 cap = token.fund() / 50;
        uint256 spend;
        if (fallbackMode) spend = cap < token.fallbackDaily() ? cap : token.fallbackDaily();
        else spend = jobs > cap / token.jobsRate() ? cap : jobs * token.jobsRate();
        uint256 fundBefore = token.fund();
        uint256 returnedToFund =
            spend != 0 && token.totalWeight() == 0 ? vestedRewards(now_) - vestedRewards(checkpointAt) : 0;
        uint256 beforeReward = imd.balanceOf(address(token));
        uint256 beforePool = token.balanceOf(address(pair));
        if (fallbackMode) {
            token.fallbackOvertime();
        } else {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, token.answerDigest(jobs, now_, day));
            token.submitOvertime(jobs, now_, day, abi.encodePacked(r, s, v));
        }
        uint256 spent = beforeReward - imd.balanceOf(address(token));
        fundOutflows += spent;
        burnCommitted += spend / 2;
        burnSpent += spent;
        _schedule(spend - spend / 2);
        assertEq(token.fund(), fundBefore - spend + returnedToFund);
        burned += beforePool - token.balanceOf(address(pair));
        assertTrue(token.usedDay(day));
        calls[this.overtime.selector]++;
    }

    function retryBurn(uint256 seed, bool refreshOracle) public {
        uint256 queued = token.pendingStrikeBurn();
        if (queued < 10_000) return; // Dust and empty retries have dedicated unit coverage.
        uint256 input = bound(seed, 10_000, queued);
        if (refreshOracle) _warm();
        uint256 beforeReward = imd.balanceOf(address(token));
        uint256 beforePool = token.balanceOf(address(pair));
        if (!adapter.ready() || vm.getBlockTimestamp() - adapter.observationAt() > 2 hours) {
            vm.expectRevert(V2TwapSwap.OracleNotReady.selector);
            token.processStrikeBurn(input);
            assertEq(token.pendingStrikeBurn(), queued);
            assertEq(imd.balanceOf(address(token)), beforeReward);
            assertEq(token.balanceOf(address(pair)), beforePool);
        } else {
            token.processStrikeBurn(input);
            assertEq(beforeReward - imd.balanceOf(address(token)), input);
            assertEq(token.pendingStrikeBurn(), queued - input);
            burnSpent += input;
            fundOutflows += input;
            burned += beforePool - token.balanceOf(address(pair));
        }
        calls[this.retryBurn.selector]++;
    }

    function vote(uint256 who, uint256 option) public {
        address user = actors[who % 4];
        uint256 week = token.currentWeek();
        (uint256 amount,,,,,, uint256 openedAt) = token.stakes(user);
        if (amount == 0 || token.voted(week, user) || openedAt >= token.genesis() + week * 7 days) return;
        vm.prank(user);
        token.vote(uint8(option % 3));
        calls[this.vote.selector]++;
    }

    function bargain() public {
        uint256 week = token.currentWeek();
        if (week == 0) return;
        (, bool executed) = token.ballot(week - 1);
        if (executed) return;
        uint256 spend = token.fund() / 100;
        uint256 beforeReward = imd.balanceOf(address(token));
        uint256 beforePool = token.balanceOf(address(pair));
        uint8 winner = token.executeBargain(week - 1);
        uint256 spent = beforeReward - imd.balanceOf(address(token));
        fundOutflows += spent;
        if (winner == 0) {
            burnCommitted += spend;
            burnSpent += spent;
        } else if (winner == 2) {
            _schedule(spend);
        }
        burned += beforePool - token.balanceOf(address(pair));
        (, executed) = token.ballot(week - 1);
        assertTrue(executed);
        vm.expectRevert(Strike.InvalidVote.selector);
        token.executeBargain(week - 1);
        calls[this.bargain.selector]++;
    }

    function donate(uint256 who, uint256 seed, bool rewardToken) public {
        address user = actors[who % 4];
        uint256 amount = bound(seed, 0, rewardToken ? imd.balanceOf(user) : token.balanceOf(user));
        vm.prank(user);
        if (rewardToken) {
            imd.transfer(address(token), amount);
            imdDonations += amount;
        } else {
            token.transfer(address(token), amount);
            strikeDonations += amount;
        }
        calls[this.donate.selector]++;
    }

    function mintCard(uint256 who) public {
        address user = actors[who % 4];
        (uint256 amount,,,,,,) = token.stakes(user);
        if (cards.minted(user) || token.balanceOf(user) + amount == 0) return;
        vm.prank(user);
        uint256 id = cards.mint();
        assertEq(cards.ownerOf(id), user);
        calls[this.mintCard.selector]++;
    }
}

/// @dev The selector allowlist prevents the fuzzer from minting IMD or impersonating the factory.
/// Each successful operation updates independent cash-flow ghosts. No catch-all revert suppression.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract StrikeInvariantTest is StrikeFixture {
    StrikeHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new StrikeHandler(strike, reward, card, actors);
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.trade.selector;
        selectors[2] = handler.transferOrBurn.selector;
        selectors[3] = handler.deposit.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.process.selector;
        selectors[7] = handler.overtime.selector;
        selectors[8] = handler.vote.selector;
        selectors[9] = handler.bargain.selector;
        selectors[10] = handler.donate.selector;
        selectors[11] = handler.mintCard.selector;
        selectors[12] = handler.retryBurn.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        // Seed nonempty positions, fees and a stream, so every run starts with obligations.
        handler.deposit(0, 10_000 ether, 0);
        handler.deposit(1, 10_000 ether, 1);
        handler.trade(2, 1000 ether, false);
        handler.process(type(uint256).max, type(uint256).max);
        handler.overtime(type(uint256).max, false);
    }

    function invariant_treasuryExactlyBacksPrincipalFeesRewardsAndDonations() public view {
        assertEq(
            strike.balanceOf(address(strike)),
            strike.totalStaked() + strike.pendingFund() + strike.pendingImdBurn() + handler.strikeDonations()
        );
        uint256 reserved = strike.fund() + strike.pendingStrikeBurn() + strike.rewardLiability() + strike.streamBudget()
            - strike.streamReleased();
        assertEq(reward.balanceOf(address(strike)), reserved + handler.imdDonations());
        assertEq(
            handler.netFees() + handler.imdDonations(),
            reward.balanceOf(address(strike)) + handler.rewardsPaid() + handler.fundOutflows()
        );
        assertLe(handler.rewardsPaid(), handler.netFees(), "donations or emissions paid as rewards");
        uint256 earned;
        for (uint256 i; i < actors.length; ++i) {
            earned += strike.earned(actors[i]);
        }
        uint256 vested = handler.vestedRewards(vm.getBlockTimestamp());
        uint256 checkpointed = handler.vestedRewards(handler.checkpointAt());
        assertEq(strike.streamBudget() - strike.streamReleased(), handler.scheduledRewards() - checkpointed);
        assertEq(strike.pendingStrikeBurn(), handler.burnCommitted() - handler.burnSpent());
        uint256 uncheckpointed = vested - checkpointed;
        assertLe(earned, strike.rewardLiability() + uncheckpointed, "unvested rewards became claimable");
        assertLe(handler.rewardsPaid() + earned, vested, "rewards exceed independently vested grants");
    }

    function invariant_positionsAndPrincipalMatchIndependentDeposits() public view {
        uint256 amounts;
        uint256 weights;
        for (uint256 i; i < actors.length; ++i) {
            (uint256 amount, uint256 weight,,,,,) = strike.stakes(actors[i]);
            amounts += amount;
            weights += weight;
        }
        assertEq(amounts, strike.totalStaked());
        assertEq(weights, strike.totalWeight());
        assertEq(handler.deposited(), amounts + handler.returnedPrincipal() + handler.penalties());
        assertEq(strike.allowance(address(strike), address(swapper)), 0);
        assertEq(reward.allowance(address(strike), address(swapper)), 0);
    }

    function invariant_supplyIsConservedAndBurnsAreTheOnlySupplyChange() public view {
        uint256 balances = strike.balanceOf(address(this)) + strike.balanceOf(address(pool))
            + strike.balanceOf(address(strike)) + strike.balanceOf(address(swapper));
        for (uint256 i; i < actors.length; ++i) {
            balances += strike.balanceOf(actors[i]);
        }
        assertEq(balances, strike.totalSupply());
        assertEq(strike.totalSupply() + handler.burned(), strike.INITIAL_SUPPLY());
        assertEq(strike.balanceOf(address(swapper)), 0, "adapter retained STRIKE");
        assertEq(reward.balanceOf(address(swapper)), 0, "adapter retained IMD");
    }

    function invariant_cardsStayWithTheirOriginalWallet() public view {
        for (uint256 i; i < actors.length; ++i) {
            if (card.minted(actors[i])) {
                uint256 id = uint256(uint160(actors[i]));
                assertEq(card.ownerOf(id), actors[i]);
                assertEq(card.balanceOf(actors[i]), 1);
                assertTrue(card.locked(id));
            }
        }
    }

    function afterInvariant() public {
        // Close every live obligation, including positions locked by votes, after arbitrary history.
        vm.warp(vm.getBlockTimestamp() + 181 days);
        for (uint256 i; i < actors.length; ++i) {
            handler.withdraw(i);
        }
        assertEq(strike.totalStaked(), 0);
        assertEq(strike.totalWeight(), 0);
        invariant_treasuryExactlyBacksPrincipalFeesRewardsAndDonations();
        invariant_positionsAndPrincipalMatchIndependentDeposits();
        invariant_supplyIsConservedAndBurnsAreTheOnlySupplyChange();
    }

    function testHandlerReachesRewardsVotesFallbackAndEarlyExit() public {
        handler.advance(1 days);
        handler.withdraw(1);
        assertGt(handler.penalties(), 0);
        handler.overtime(1, false);
        handler.advance(7 days);
        handler.claim(0);
        handler.vote(0, 2);
        handler.advance(7 days);
        handler.bargain();
        handler.overtime(0, true);
        handler.mintCard(0);
        assertGt(handler.calls(handler.claim.selector), 0);
        assertGt(handler.calls(handler.vote.selector), 0);
        assertGt(handler.calls(handler.bargain.selector), 0);
        assertGt(handler.calls(handler.overtime.selector), 2);
        assertGt(handler.rewardsPaid(), 0);
        afterInvariant();
    }

    function testHandlerOverlappingGrantsKeepOriginalVestingDeadlines() public {
        uint256 first = handler.scheduledRewards();
        handler.advance(1 days);
        handler.overtime(type(uint256).max, false);
        uint256 second = handler.scheduledRewards() - first;
        assertGt(first, 0);
        assertGt(second, 0);
        handler.advance(6 days);
        assertApproxEqAbs(strike.earned(actors[0]) + strike.earned(actors[1]), first + second * 6 / 7, 4);
        invariant_treasuryExactlyBacksPrincipalFeesRewardsAndDonations();
        handler.advance(1 days);
        assertApproxEqAbs(strike.earned(actors[0]) + strike.earned(actors[1]), first + second, 4);
        invariant_treasuryExactlyBacksPrincipalFeesRewardsAndDonations();
        afterInvariant();
    }

    function testHandlerAccountsForVestingWhenNoStakersRemain() public {
        handler.withdraw(0);
        handler.withdraw(1);
        assertEq(strike.totalStaked(), 0);
        uint256 grant = handler.scheduledRewards();
        handler.advance(7 days);
        uint256 fundBefore = strike.fund();
        handler.overtime(type(uint256).max, false);
        assertEq(strike.fund(), fundBefore - fundBefore / 50 + grant);
        invariant_treasuryExactlyBacksPrincipalFeesRewardsAndDonations();
        afterInvariant();
    }

    function testHandlerRetriesQueuedBurnsWithoutConsumingRewards() public {
        handler.advance(1 days);
        handler.overtime(type(uint256).max, false);
        uint256 queued = strike.pendingStrikeBurn();
        uint256 imdBefore = reward.balanceOf(address(strike));
        uint256 supplyBefore = strike.totalSupply();
        assertGt(queued, 20_000);
        handler.retryBurn(queued, false);
        assertEq(strike.pendingStrikeBurn(), queued);
        assertEq(reward.balanceOf(address(strike)), imdBefore);
        assertEq(strike.totalSupply(), supplyBefore);
        invariant_treasuryExactlyBacksPrincipalFeesRewardsAndDonations();
        handler.retryBurn(queued / 2, true);
        assertEq(strike.pendingStrikeBurn(), queued - queued / 2);
        invariant_treasuryExactlyBacksPrincipalFeesRewardsAndDonations();
        handler.retryBurn(strike.pendingStrikeBurn(), true);
        assertEq(strike.pendingStrikeBurn(), 0);
        assertEq(reward.balanceOf(address(strike)), imdBefore - queued);
        assertEq(handler.calls(handler.retryBurn.selector), 3);
        afterInvariant();
    }

    function testHandlerAllowsAdjacentUtcDaysAndRespectsFallbackRecovery() public {
        uint256 callsBefore = handler.calls(handler.overtime.selector);
        uint256 nextDay = (vm.getBlockTimestamp() / 1 days + 1) * 1 days;
        handler.advance(nextDay - vm.getBlockTimestamp());
        handler.overtime(0, false);
        assertEq(handler.calls(handler.overtime.selector), callsBefore + 1);
        assertTrue(strike.usedDay(nextDay / 1 days));
        handler.advance(2 days);
        handler.overtime(0, true);
        assertEq(handler.calls(handler.overtime.selector), callsBefore + 2);
        uint256 fallbackAt = strike.lastOvertimeAt();
        handler.advance(1 days);
        handler.overtime(0, true);
        assertEq(strike.lastOvertimeAt(), fallbackAt);
        assertEq(handler.calls(handler.overtime.selector), callsBefore + 2);
        // The signer can recover on the day reserved by the fallback cooldown.
        handler.overtime(0, false);
        assertEq(handler.calls(handler.overtime.selector), callsBefore + 3);
        assertEq(strike.lastAnswerAt(), vm.getBlockTimestamp());
        afterInvariant();
    }
}
