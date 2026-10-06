// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Immutable, permissionless swap service. Inputs/outputs are token minor units.
interface IStrikeSwap {
    function quote(address tokenIn, uint256 amountIn) external view returns (uint256);
    function swap(address tokenIn, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut);
}
