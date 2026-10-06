// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrikeSwap} from "./interfaces/IStrikeSwap.sol";
import {V2TwapSwap} from "./V2TwapSwap.sol";

/// @notice Fixed-supply STRIKE, fee treasury, locked staking, overtime and weekly bargaining.
/// @dev No owner, setters, proxy, arbitrary execution, emissions or external calls on ordinary sends.
contract Strike is ERC20, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant WEEK = 7 days;
    uint256 public constant PRECISION = 1e27;
    uint256 public constant SLIPPAGE_BPS = 300;
    address public constant DEAD = address(0xdead);
    bytes32 public constant QUESTION_HASH = keccak256("jobs the IMD swarm accepted in the last 24h");
    bytes32 public constant ANSWER_TYPEHASH =
        keccak256("Overtime(bytes32 questionHash,uint256 jobs,uint256 observedAt,uint256 day)");

    address public immutable factory;
    address public immutable poolManager;
    uint64 public immutable launchNumber;
    address public immutable market;
    IERC20 public immutable imd;
    IStrikeSwap public immutable swapAdapter;
    address public immutable oracleSigner;
    uint256 public immutable jobsRate;
    uint256 public immutable fallbackDaily;
    uint256 public immutable genesis;

    uint256 public pendingImdBurn;
    uint256 public pendingFund;
    uint256 public fund;
    uint256 public totalStaked;
    uint256 public totalWeight;
    uint256 public rewardPerWeight;
    uint256 public rewardLiability;
    uint256 public streamBudget;
    uint256 public streamReleased;
    uint256 public streamStart;
    uint256 public streamEnd;
    uint256 public lastAnswerAt;
    uint256 public lastOvertimeAt;
    mapping(uint256 => bool) public usedDay;
    mapping(address => uint256) public holdStart;

    struct Stake {
        uint256 amount;
        uint256 weight;
        uint256 unlockAt;
        uint256 rewardDebt;
        uint256 accrued;
        uint256 voteLockUntil;
        uint256 openedAt;
    }
    mapping(address => Stake) public stakes;

    struct Ballot {
        uint256[3] votes;
        bool executed;
    }
    mapping(uint256 => Ballot) private ballots;
    mapping(uint256 => mapping(address => bool)) public voted;

    error InvalidConfiguration();
    error InvalidAmount();
    error InvalidLock();
    error ActiveStake();
    error NoStake();
    error VoteLocked();
    error InvalidVote();
    error InvalidAnswer();
    error TooSoon();
    error SwapFailed();

    event Dues(address indexed trader, uint256 strikeBurn, uint256 imdBurnInput, uint256 fundInput);
    event FeesProcessed(uint256 input, uint256 imdBurned, uint256 fundAdded);
    event Staked(address indexed account, uint256 amount, uint256 weight, uint256 unlockAt);
    event Exited(address indexed account, uint256 returned, uint256 burned, uint256 forfeited);
    event RewardPaid(address indexed account, uint256 amount);
    event StreamStarted(uint256 amount, uint256 finish);
    event Overtime(uint256 indexed day, uint256 jobs, uint256 spent, bool fallbackUsed);
    event VoteCast(uint256 indexed week, address indexed account, uint8 option, uint256 weight);
    event Bargained(uint256 indexed week, uint8 winner, uint256 spent);

    constructor(
        address factory_,
        address poolManager_,
        uint64 launchNumber_,
        address imd_,
        address v2Factory_,
        bytes32 pairInitCodeHash_,
        address oracleSigner_,
        uint256 jobsRate_,
        uint256 fallbackDaily_
    ) ERC20("Swarm Local 2000", "STRIKE") EIP712("Swarm Local 2000 Overtime", "1") {
        if (
            factory_ == address(0) || factory_ != msg.sender || poolManager_ == address(0) || imd_ == address(0)
                || v2Factory_ == address(0) || pairInitCodeHash_ == bytes32(0) || oracleSigner_ == address(0)
                || jobsRate_ == 0 || fallbackDaily_ == 0 || imd_ == address(this)
        ) revert InvalidConfiguration();
        factory = factory_;
        poolManager = poolManager_;
        launchNumber = launchNumber_;
        V2TwapSwap adapter = new V2TwapSwap(v2Factory_, pairInitCodeHash_, address(this), imd_);
        address pair = address(adapter.pair());
        if (pair == address(0) || pair == poolManager_ || pair == factory_) revert InvalidConfiguration();
        market = pair;
        imd = IERC20(imd_);
        swapAdapter = IStrikeSwap(address(adapter));
        oracleSigner = oracleSigner_;
        jobsRate = jobsRate_;
        fallbackDaily = fallbackDaily_;
        genesis = block.timestamp;
        lastAnswerAt = block.timestamp;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice No ownership is ever granted.
    function owner() external pure returns (address) {
        return address(0);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (amount == 0) {
            super._update(from, to, 0);
            return;
        }
        if (to != address(0) && balanceOf(to) + stakes[to].amount == 0) holdStart[to] = block.timestamp;
        bool taxed = from != address(0) && to != address(0) && from != to && (from == market || to == market)
            && !_exempt(from, to);
        if (taxed) {
            uint256 burnPart = amount / 200;
            uint256 imdPart = amount / 200;
            uint256 fundPart = amount / 100;
            pendingImdBurn += imdPart;
            pendingFund += fundPart;
            super._update(from, address(0), burnPart);
            super._update(from, address(this), imdPart + fundPart);
            super._update(from, to, amount - burnPart - imdPart - fundPart);
            emit Dues(from == market ? to : from, burnPart, imdPart, fundPart);
        } else {
            super._update(from, to, amount);
        }
        if (from != address(0)) {
            holdStart[from] = balanceOf(from) + stakes[from].amount == 0 ? 0 : block.timestamp;
        }
    }

    function _exempt(address from, address to) private view returns (bool) {
        if (
            msg.sender == factory || from == factory || to == factory || msg.sender == poolManager
                || from == poolManager || to == poolManager || from == address(this) || to == address(this)
        ) return true;
        // A missing or reverting distributor lookup cannot disable transfers.
        bytes memory data = abi.encodeWithSignature("distributorOf(uint64)", launchNumber);
        address target = factory;
        bool ok;
        uint256 size;
        uint256 raw;
        // Copy at most one word, even if the factory returns excessive data.
        assembly ("memory-safe") {
            ok := staticcall(30000, target, add(data, 32), mload(data), 0, 32)
            size := returndatasize()
            raw := mload(0)
        }
        if (!ok || size != 32 || raw == 0 || raw > type(uint160).max) return false;
        address distributor = address(uint160(raw));
        return msg.sender == distributor || from == distributor || to == distributor;
    }

    /// @notice Rank expressed in basis points; staking transfers retain wallet seniority.
    function rankBonus(address account) public view returns (uint256) {
        if (balanceOf(account) + stakes[account].amount == 0) return 10_000;
        uint256 age = block.timestamp - holdStart[account];
        if (age >= 30 days) return 15_000;
        if (age >= 7 days) return 12_500;
        if (age >= 1 days) return 11_000;
        return 10_000;
    }

    /// @notice Converts bounded amounts of accrued dues. Never invoked by a transfer.
    function processFees(uint256 maxImdBurnInput, uint256 maxFundInput) external nonReentrant {
        uint256 burnInput = Math.min(pendingImdBurn, maxImdBurnInput);
        uint256 fundInput = Math.min(pendingFund, maxFundInput);
        uint256 input = burnInput + fundInput;
        if (input == 0) revert InvalidAmount();
        pendingImdBurn -= burnInput;
        pendingFund -= fundInput;
        uint256 received = _swap(address(this), input);
        uint256 burned = Math.mulDiv(received, burnInput, input);
        fund += received - burned;
        if (burned != 0) imd.safeTransfer(DEAD, burned);
        emit FeesProcessed(input, burned, received - burned);
    }

    /// @dev Never trust an adapter's return value: measure both sides and clear its exact allowance.
    function _swap(address inputToken, uint256 input) private returns (uint256 output) {
        uint256 quote = swapAdapter.quote(inputToken, input);
        uint256 minimum = Math.mulDiv(quote, 10_000 - SLIPPAGE_BPS, 10_000);
        if (minimum == 0) revert SwapFailed();
        IERC20 source = IERC20(inputToken);
        IERC20 destination = inputToken == address(this) ? imd : IERC20(address(this));
        uint256 beforeInput = source.balanceOf(address(this));
        uint256 beforeOutput = destination.balanceOf(address(this));
        source.forceApprove(address(swapAdapter), input);
        swapAdapter.swap(inputToken, input, minimum, address(this));
        source.forceApprove(address(swapAdapter), 0);
        output = destination.balanceOf(address(this)) - beforeOutput;
        if (output < minimum || source.balanceOf(address(this)) != beforeInput - input) revert SwapFailed();
    }

    function stake(uint256 amount, uint256 lockDays) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (stakes[msg.sender].amount != 0) revert ActiveStake();
        uint256 multiplier;
        if (lockDays == 7) multiplier = 10;
        else if (lockDays == 30) multiplier = 15;
        else if (lockDays == 90) multiplier = 25;
        else if (lockDays == 180) multiplier = 40;
        else revert InvalidLock();
        _checkpoint();
        uint256 weight = amount * multiplier / 10;
        uint256 unlockAt = block.timestamp + lockDays * 1 days;
        stakes[msg.sender] = Stake(amount, weight, unlockAt, rewardPerWeight, 0, 0, block.timestamp);
        totalStaked += amount;
        totalWeight += weight;
        // User initiated deposit; no allowance required, no seniority reset and no fee.
        super._update(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount, weight, unlockAt);
    }

    function _vested() private view returns (uint256) {
        if (streamEnd == 0) return 0;
        return Math.mulDiv(streamBudget, Math.min(block.timestamp, streamEnd) - streamStart, WEEK);
    }

    function _checkpoint() private {
        uint256 vested = _vested();
        uint256 newlyVested = vested - streamReleased;
        streamReleased = vested;
        _distribute(newlyVested);
    }

    function _distribute(uint256 amount) private {
        if (amount == 0) return;
        if (totalWeight == 0) {
            fund += amount;
        } else {
            // Reserve the full amount. Sub-wei per-user rounding dust remains reserved, never reused.
            rewardPerWeight += Math.mulDiv(amount, PRECISION, totalWeight);
            rewardLiability += amount;
        }
    }

    function _accrue(Stake storage position) private {
        position.accrued += Math.mulDiv(position.weight, rewardPerWeight - position.rewardDebt, PRECISION);
        position.rewardDebt = rewardPerWeight;
    }

    function earned(address account) external view returns (uint256) {
        Stake storage position = stakes[account];
        uint256 accumulator = rewardPerWeight;
        if (totalWeight != 0) {
            accumulator += Math.mulDiv(_vested() - streamReleased, PRECISION, totalWeight);
        }
        return position.accrued + Math.mulDiv(position.weight, accumulator - position.rewardDebt, PRECISION);
    }

    /// @notice Rewards vest linearly, but can only be claimed after the stake's lock matures.
    /// This makes early-exit forfeiture enforceable, including all previously accrued rewards.
    function claim() external nonReentrant returns (uint256 reward) {
        Stake storage position = stakes[msg.sender];
        if (position.amount == 0) revert NoStake();
        if (block.timestamp < position.unlockAt) revert TooSoon();
        _checkpoint();
        _accrue(position);
        reward = position.accrued;
        position.accrued = 0;
        rewardLiability -= reward;
        if (reward != 0) imd.safeTransfer(msg.sender, reward);
        emit RewardPaid(msg.sender, reward);
    }

    function exit() external nonReentrant {
        Stake storage position = stakes[msg.sender];
        if (position.amount == 0) revert NoStake();
        if (block.timestamp < position.voteLockUntil) revert VoteLocked();
        _checkpoint();
        _accrue(position);
        uint256 amount = position.amount;
        uint256 reward = position.accrued;
        bool early = block.timestamp < position.unlockAt;
        totalStaked -= amount;
        totalWeight -= position.weight;
        delete stakes[msg.sender];
        rewardLiability -= reward;
        uint256 penalty = early ? amount / 5 : 0;
        if (early) _distribute(reward);
        if (penalty != 0) super._update(address(this), address(0), penalty);
        super._update(address(this), msg.sender, amount - penalty);
        if (!early && reward != 0) imd.safeTransfer(msg.sender, reward);
        emit Exited(msg.sender, amount - penalty, penalty, early ? reward : 0);
        if (!early) emit RewardPaid(msg.sender, reward);
    }

    function _stream(uint256 amount) private {
        _checkpoint();
        uint256 remaining = streamBudget - streamReleased;
        streamBudget = remaining + amount;
        streamReleased = 0;
        streamStart = block.timestamp;
        streamEnd = block.timestamp + WEEK;
        emit StreamStarted(streamBudget, streamEnd);
    }

    function answerDigest(uint256 jobs, uint256 observedAt, uint256 day) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ANSWER_TYPEHASH, QUESTION_HASH, jobs, observedAt, day)));
    }

    /// @notice Anyone may relay one fresh, typed, signed answer per UTC day, at least 24h apart.
    function submitOvertime(uint256 jobs, uint256 observedAt, uint256 day, bytes calldata signature)
        external
        nonReentrant
    {
        if (
            observedAt > block.timestamp || block.timestamp - observedAt > 1 hours || day != observedAt / 1 days
                || day != block.timestamp / 1 days || usedDay[day]
                || ECDSA.recover(answerDigest(jobs, observedAt, day), signature) != oracleSigner
        ) revert InvalidAnswer();
        _checkOvertimeCadence();
        usedDay[day] = true;
        lastAnswerAt = observedAt;
        // Cap before multiplying: even a signed uint256-max jobs count cannot overflow.
        uint256 cap = fund / 50;
        uint256 spend = jobs > cap / jobsRate ? cap : jobs * jobsRate;
        _overtime(day, jobs, spend, false);
    }

    function fallbackOvertime() external nonReentrant {
        if (block.timestamp < lastAnswerAt + 2 days) revert TooSoon();
        uint256 day = block.timestamp / 1 days;
        if (usedDay[day]) revert TooSoon();
        _checkOvertimeCadence();
        usedDay[day] = true;
        _overtime(day, 0, Math.min(fallbackDaily, fund / 50), true);
    }

    function _checkOvertimeCadence() private view {
        if (lastOvertimeAt != 0 && block.timestamp < lastOvertimeAt + 1 days) revert TooSoon();
    }

    function _overtime(uint256 day, uint256 jobs, uint256 spend, bool isFallback) private {
        lastOvertimeAt = block.timestamp;
        fund -= spend;
        uint256 burnInput = spend / 2;
        if (burnInput != 0) {
            uint256 strikeBought = _swap(address(imd), burnInput);
            super._update(address(this), address(0), strikeBought);
        }
        if (spend != 0) _stream(spend - burnInput);
        emit Overtime(day, jobs, spend, isFallback);
    }

    function currentWeek() public view returns (uint256) {
        return (block.timestamp - genesis) / WEEK;
    }

    function ballot(uint256 week) external view returns (uint256[3] memory votes, bool executed) {
        return (ballots[week].votes, ballots[week].executed);
    }

    /// @notice Position must predate the week; voting escrows it through the end of that week.
    function vote(uint8 option) external nonReentrant {
        uint256 week = currentWeek();
        Stake storage position = stakes[msg.sender];
        if (option > 2 || position.amount == 0 || voted[week][msg.sender] || position.openedAt >= genesis + week * WEEK)
        {
            revert InvalidVote();
        }
        uint256 weight = Math.mulDiv(position.amount, rankBonus(msg.sender), 10_000);
        voted[week][msg.sender] = true;
        position.voteLockUntil = genesis + (week + 1) * WEEK;
        ballots[week].votes[option] += weight;
        emit VoteCast(week, msg.sender, option, weight);
    }

    /// @notice Only the immediately preceding week is executable; idle history cannot drain the fund.
    function executeBargain(uint256 week) external nonReentrant returns (uint8 winner) {
        uint256 current = currentWeek();
        Ballot storage result = ballots[week];
        if (current == 0 || week != current - 1 || result.executed) revert InvalidVote();
        uint256 a = result.votes[0];
        uint256 b = result.votes[1];
        uint256 c = result.votes[2];
        // Any tie for highest (including B/C) resolves to A, as requested.
        if (b > a && b > c) winner = 1;
        else if (c > a && c > b) winner = 2;
        result.executed = true;
        uint256 spend = fund / 100;
        fund -= spend;
        if (spend != 0) {
            if (winner == 0) {
                uint256 strikeBought = _swap(address(imd), spend);
                super._update(address(this), address(0), strikeBought);
            } else if (winner == 1) {
                imd.safeTransfer(DEAD, spend);
            } else {
                _stream(spend);
            }
        }
        emit Bargained(week, winner, spend);
    }
}
