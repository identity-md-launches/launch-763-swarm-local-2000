// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Strike} from "src/Strike.sol";
import {V2TwapSwap} from "src/V2TwapSwap.sol";
import {UnionCard} from "src/UnionCard.sol";
import {MockIMD} from "../Strike.t.sol";
import {FactoryModel, PairModel} from "../PairModel.sol";

/// @dev Real production token and adapter; only the external IMD and V2 pair are local models.
abstract contract StrikeFixture is Test {
    Strike internal strike;
    MockIMD internal reward;
    V2TwapSwap internal swapper;
    PairModel internal pool;
    UnionCard internal card;
    address[4] internal actors = [address(0x101), address(0x102), address(0x103), address(0x104)];
    uint256 internal constant ORACLE_KEY = 0x5151;
    mapping(uint64 => address) public distributorOf;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        reward = new MockIMD();
        FactoryModel factory = new FactoryModel();
        strike = new Strike(
            address(this),
            address(0x4444),
            1,
            address(reward),
            address(factory),
            keccak256(type(PairModel).creationCode),
            vm.addr(ORACLE_KEY),
            1 ether,
            1 ether
        );
        swapper = V2TwapSwap(address(strike.swapAdapter()));
        pool = PairModel(swapper.prepareMarket());
        card = new UnionCard(address(strike));
        strike.transfer(address(pool), 100_000_000 ether);
        reward.mint(address(pool), 100_000_000 ether);
        for (uint256 i; i < actors.length; ++i) {
            strike.transfer(actors[i], 1_000_000 ether);
            reward.mint(actors[i], 1_000_000 ether);
        }
        pool.sync();
        swapper.updateOracle();
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        swapper.updateOracle();
    }

    function _warm() internal {
        if (vm.getBlockTimestamp() - swapper.observationAt() >= 30 minutes) swapper.updateOracle();
        if (!swapper.ready()) {
            vm.warp(vm.getBlockTimestamp() + 30 minutes);
            swapper.updateOracle();
        }
    }

    function _fund() internal {
        vm.prank(actors[3]);
        strike.transfer(address(pool), 100_000 ether);
        pool.sync();
        strike.processFees(type(uint256).max, type(uint256).max);
        assertGt(strike.fund(), 990 ether);
    }

    function _signature(uint256 key, uint256 jobs, uint256 observed, uint256 day) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, strike.answerDigest(jobs, observed, day));
        return abi.encodePacked(r, s, v);
    }

    function _answer(uint256 jobs) internal {
        uint256 now_ = vm.getBlockTimestamp();
        strike.submitOvertime(jobs, now_, now_ / 1 days, _signature(ORACLE_KEY, jobs, now_, now_ / 1 days));
    }
}
