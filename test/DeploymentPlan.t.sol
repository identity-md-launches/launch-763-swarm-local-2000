// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeploymentPlan} from "../script/DeploymentPlan.sol";
import {Strike} from "../src/Strike.sol";
import {MockIMD} from "./Strike.t.sol";
import {FactoryModel, PairModel} from "./PairModel.sol";

contract DeploymentPlanTest is Test, DeploymentPlan {
    function testExplicitConfigurationBuildsAndPredictsActualDeployment() public {
        MockIMD imd = new MockIMD();
        FactoryModel v2 = new FactoryModel();
        Config memory config = Config(
            address(this),
            address(0x4444),
            21,
            address(imd),
            address(v2),
            keccak256(type(PairModel).creationCode),
            address(0x1234),
            1e6,
            1e5
        );
        bytes memory code = tokenCode(config);
        bytes32 salt = bytes32(uint256(config.launchNumber));
        address predicted = this.tokenAddress(config);
        address deployed;
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        assertEq(deployed, predicted);
        assertEq(Strike(deployed).balanceOf(address(this)), 1_000_000_000 ether);
        assertEq(Strike(deployed).jobsRate(), 1e6);
        assertEq(Strike(deployed).fallbackDaily(), 1e5);
    }

    function testConstructorAndLaunchTransfersNeedNoExternalDependencyCode() public {
        address manager = address(0x4444);
        Strike fresh = new Strike(
            address(this), manager, 42, address(0x1111), address(0x2222), bytes32(uint256(123)), address(0x3333), 1, 1
        );
        assertEq(fresh.balanceOf(address(this)), fresh.totalSupply());
        assertEq(fresh.market().code.length, 0);
        fresh.transfer(manager, 100 ether);
        vm.prank(manager);
        fresh.transfer(address(0xABCD), 100 ether);
        vm.prank(address(0xABCD));
        fresh.transfer(manager, 100 ether);
        assertEq(fresh.balanceOf(manager), 100 ether);
        assertEq(fresh.totalSupply(), 1_000_000_000 ether);
    }

    function testMissingDeploymentParametersRejected() public {
        Config memory config;
        vm.expectRevert("addresses");
        this.tokenCode(config);
    }
}
