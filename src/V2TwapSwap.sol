// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStrikeSwap} from "./interfaces/IStrikeSwap.sol";

interface IV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address);
}

interface IV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @notice Fixed 0.30%-fee Uniswap V2-compatible pair adapter with a 30-minute cumulative TWAP.
/// @dev Deploy against the token's configured market. Quotes fail closed until warmed up.
contract V2TwapSwap is IStrikeSwap, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WINDOW = 30 minutes;
    uint256 public constant MAX_AGE = 2 hours;
    uint256 public constant Q112 = 2 ** 112;
    IV2Pair public immutable pair;
    IV2Factory public immutable v2Factory;
    bytes32 public immutable pairInitCodeHash;
    address public immutable strike;
    address public immutable imd;
    address public immutable token0;
    uint256 public observationAt;
    uint256 public cumulative0;
    uint256 public cumulative1;
    uint256 public average0;
    uint256 public average1;
    bool public initialized;
    bool public ready;

    error InvalidPair();
    error InvalidSwap();
    error OracleNotReady();
    error ObservationTooSoon();
    event Observation(uint256 timestamp, uint256 average0, uint256 average1, bool ready);
    event Swapped(address indexed caller, address indexed tokenIn, uint256 input, uint256 output);

    constructor(address v2Factory_, bytes32 pairInitCodeHash_, address strike_, address imd_) {
        if (
            v2Factory_ == address(0) || pairInitCodeHash_ == bytes32(0) || strike_ == address(0) || imd_ == address(0)
                || strike_ == imd_
        ) revert InvalidPair();
        v2Factory = IV2Factory(v2Factory_);
        pairInitCodeHash = pairInitCodeHash_;
        strike = strike_;
        imd = imd_;
        (address first, address second) = strike_ < imd_ ? (strike_, imd_) : (imd_, strike_);
        token0 = first;
        pair = IV2Pair(
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff), v2Factory_, keccak256(abi.encodePacked(first, second)), pairInitCodeHash_
                            )
                        )
                    )
                )
            )
        );
    }

    /// @notice Creates the already fixed market if necessary; no parameter or permission changes.
    /// Constructor deployment itself needs no live IMD, V2 factory or pool code.
    function prepareMarket() external nonReentrant returns (address market) {
        market = v2Factory.getPair(strike, imd);
        if (market == address(0)) market = v2Factory.createPair(strike, imd);
        if (market != address(pair) || pair.token0() != token0 || pair.token1() != (token0 == strike ? imd : strike)) {
            revert InvalidPair();
        }
    }

    function _current() private view returns (uint256 p0, uint256 p1) {
        (uint112 r0, uint112 r1, uint32 last) = pair.getReserves();
        if (r0 == 0 || r1 == 0) revert OracleNotReady();
        p0 = pair.price0CumulativeLast();
        p1 = pair.price1CumulativeLast();
        // V2 timestamps and cumulative counters intentionally wrap.
        unchecked {
            uint32 elapsed = uint32(block.timestamp) - last;
            p0 += ((uint256(r1) << 112) / r0) * elapsed;
            p1 += ((uint256(r0) << 112) / r1) * elapsed;
        }
    }

    /// @notice Anyone maintains observations. A >2h outage requires a fresh 30-minute warm-up.
    function updateOracle() external {
        if (initialized && block.timestamp - observationAt < WINDOW) revert ObservationTooSoon();
        (uint256 p0, uint256 p1) = _current();
        uint256 elapsed = block.timestamp - observationAt;
        if (initialized && elapsed <= MAX_AGE) {
            unchecked {
                average0 = (p0 - cumulative0) / elapsed;
                average1 = (p1 - cumulative1) / elapsed;
            }
            ready = average0 != 0 && average1 != 0;
        } else {
            initialized = true;
            ready = false;
        }
        cumulative0 = p0;
        cumulative1 = p1;
        observationAt = block.timestamp;
        emit Observation(block.timestamp, average0, average1, ready);
    }

    function quote(address tokenIn, uint256 amountIn) public view returns (uint256) {
        if (tokenIn != strike && tokenIn != imd) revert InvalidSwap();
        if (!ready || block.timestamp - observationAt > MAX_AGE) revert OracleNotReady();
        // Price is gross TWAP; the 3% minimum-output tolerance also covers LP fees and price impact.
        return Math.mulDiv(amountIn, tokenIn == token0 ? average0 : average1, Q112);
    }

    function swap(address tokenIn, uint256 amountIn, uint256 minOut, address recipient)
        external
        nonReentrant
        returns (uint256 output)
    {
        bool treasury = msg.sender == strike && recipient == strike;
        if (
            amountIn == 0 || minOut == 0 || recipient == address(0) || recipient == address(pair)
                || recipient == address(this) || recipient == imd || (recipient == strike && !treasury)
        ) {
            revert InvalidSwap();
        }
        uint256 floor = Math.mulDiv(quote(tokenIn, amountIn), 9700, 10_000);
        if (floor == 0 || minOut < floor) revert InvalidSwap();
        address outputToken = tokenIn == strike ? imd : strike;
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = tokenIn == token0 ? (r0, r1) : (r1, r0);
        uint256 beforeInput = IERC20(tokenIn).balanceOf(address(pair));
        uint256 beforeOutput = IERC20(outputToken).balanceOf(recipient);
        uint256 beforeCustody = treasury ? IERC20(outputToken).balanceOf(address(this)) : 0;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(pair), amountIn);
        uint256 actualInput = IERC20(tokenIn).balanceOf(address(pair)) - beforeInput;
        if (actualInput == 0) revert InvalidSwap();
        uint256 withFee = actualInput * 997;
        uint256 grossOutput = Math.mulDiv(withFee, reserveOut, reserveIn * 1000 + withFee);
        if (grossOutput == 0 || grossOutput >= reserveOut) revert InvalidSwap();
        // Genuine V2 pairs reject either token contract as `to`. Only treasury swaps use custody;
        // public trades go directly to their recipient and retain the normal market dues.
        pair.swap(
            tokenIn == token0 ? 0 : grossOutput,
            tokenIn == token0 ? grossOutput : 0,
            treasury ? address(this) : recipient,
            ""
        );
        if (treasury) {
            uint256 received = IERC20(outputToken).balanceOf(address(this)) - beforeCustody;
            IERC20(outputToken).safeTransfer(recipient, received);
        }
        output = IERC20(outputToken).balanceOf(recipient) - beforeOutput;
        if (output < minOut) revert InvalidSwap();
        emit Swapped(msg.sender, tokenIn, amountIn, output);
    }
}
