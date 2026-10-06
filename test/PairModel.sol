// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Local V2 reserve/cumulative-price model with the actual 0.3% adjusted K check.
/// No liquidity shares: this is test scaffolding, not a production AMM.
contract PairModel {
    address public token0;
    address public token1;
    address public immutable factory = msg.sender;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private last;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    bool private entered;

    function initialize(address a, address b) external {
        require(msg.sender == factory && token0 == address(0), "initialize");
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, last);
    }

    function sync() external {
        _update();
    }

    function _update() private {
        unchecked {
            uint32 elapsed = uint32(block.timestamp) - last;
            if (reserve0 != 0 && reserve1 != 0) {
                price0CumulativeLast += ((uint256(reserve1) << 112) / reserve0) * elapsed;
                price1CumulativeLast += ((uint256(reserve0) << 112) / reserve1) * elapsed;
            }
        }
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        require(b0 <= type(uint112).max && b1 <= type(uint112).max, "overflow");
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
        last = uint32(block.timestamp);
    }

    function swap(uint256 out0, uint256 out1, address to, bytes calldata) external {
        require(!entered, "locked");
        entered = true;
        require((out0 > 0 || out1 > 0) && out0 < reserve0 && out1 < reserve1, "output");
        if (out0 != 0) IERC20(token0).transfer(to, out0);
        if (out1 != 0) IERC20(token1).transfer(to, out1);
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 in0 = b0 > reserve0 - out0 ? b0 - (reserve0 - out0) : 0;
        uint256 in1 = b1 > reserve1 - out1 ? b1 - (reserve1 - out1) : 0;
        require(in0 > 0 || in1 > 0, "input");
        require((b0 * 1000 - in0 * 3) * (b1 * 1000 - in1 * 3) >= uint256(reserve0) * reserve1 * 1_000_000, "K");
        _update();
        entered = false;
    }
}

contract FactoryModel {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address a, address b) external returns (address pair) {
        require(a != b && a != address(0) && b != address(0) && getPair[a][b] == address(0), "pair");
        (address first, address second) = a < b ? (a, b) : (b, a);
        pair = address(new PairModel{salt: keccak256(abi.encodePacked(first, second))}());
        PairModel(pair).initialize(first, second);
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }
}
