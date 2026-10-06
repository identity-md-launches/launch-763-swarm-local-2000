// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strike} from "../src/Strike.sol";

/// @notice Read-only, environment-free construction helpers. Never broadcasts or holds funds.
/// @dev For offline tooling/test use; do not deploy this large bytecode-building helper on chain.
contract DeploymentPlan {
    struct Config {
        address factory;
        address poolManager;
        uint64 launchNumber;
        address imd;
        address v2Factory;
        bytes32 pairInitCodeHash;
        address oracleSigner;
        uint256 jobsRate;
        uint256 fallbackDaily;
    }

    function tokenCode(Config memory c) public pure returns (bytes memory) {
        require(c.factory != address(0) && c.poolManager != address(0) && c.imd != address(0), "addresses");
        require(c.v2Factory != address(0) && c.oracleSigner != address(0), "dependencies");
        require(c.pairInitCodeHash != bytes32(0), "pair hash");
        require(c.jobsRate != 0 && c.fallbackDaily != 0, "rates");
        return abi.encodePacked(
            type(Strike).creationCode,
            abi.encode(
                c.factory,
                c.poolManager,
                c.launchNumber,
                c.imd,
                c.v2Factory,
                c.pairInitCodeHash,
                c.oracleSigner,
                c.jobsRate,
                c.fallbackDaily
            )
        );
    }

    function tokenAddress(Config memory c) external pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), c.factory, bytes32(uint256(c.launchNumber)), keccak256(tokenCode(c))
                        )
                    )
                )
            )
        );
    }
}
