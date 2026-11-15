// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface BenchmarkVm {
    function warp(uint256) external;
    function cool(address) external;
}

// Models queue and checkpoint storage costs for a cold, fully overdue queue.
contract ActivationFixture {
    uint256[] private timestamps;
    mapping(uint256 => uint256) private pending;
    mapping(uint256 => uint256) public activationIndex;
    uint256[] private accountTranches;
    uint256 public eligible = 10 ether;
    uint256 public accountEligible;
    uint256 public index = 1e27;
    uint256 public dust = 1;
    uint256 public reservedDust;

    constructor(uint256 keys, uint256 tranches) {
        for (uint256 i; i < keys; ++i) {
            uint256 at = block.timestamp + 86_400 + i;
            timestamps.push(at);
            pending[at] = 1 ether;
            if (i < tranches) accountTranches.push(at);
        }
    }

    function settleAndAllocate() external {
        uint256 weight = eligible;
        uint256 currentIndex = index;
        uint256 count = timestamps.length;
        for (uint256 i; i < count; ++i) {
            uint256 at = timestamps[i];
            require(at <= block.timestamp, "fixture requires all keys due");
            activationIndex[at] = currentIndex;
            weight += pending[at];
            delete pending[at];
        }
        delete timestamps;
        uint256 activated;
        for (uint256 i; i < accountTranches.length; ++i) {
            require(activationIndex[accountTranches[i]] == currentIndex, "missing checkpoint");
            activated += 1 ether;
        }
        delete accountTranches;
        accountEligible += activated;
        eligible = weight;
        reservedDust += dust;
        index = currentIndex + 1e45 / weight;
        dust = 1e45 % weight;
    }
}

contract NDAIActivationBenchmark {
    BenchmarkVm private constant vm =
        BenchmarkVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event ColdSettlementGas(uint256 keys, uint256 tranches, uint256 gasUsed);

    function testColdQueue32Tranches8() public { _measure(32, 8, 1_500_000); }
    function testColdQueue64Tranches16() public { _measure(64, 16, 3_000_000); }
    function testColdQueue128Tranches32() public { _measure(128, 32, 6_000_000); }

    function _measure(uint256 keys, uint256 tranches, uint256 budget) private {
        ActivationFixture queue = new ActivationFixture(keys, tranches);
        vm.warp(block.timestamp + 90 days);
        vm.cool(address(queue));
        uint256 before = gasleft();
        queue.settleAndAllocate();
        uint256 used = before - gasleft();
        emit ColdSettlementGas(keys, tranches, used);
        require(used <= budget, "settlement exceeded fixture budget");
        require(queue.eligible() == (10 + keys) * 1 ether, "missing eligible weight");
        require(queue.accountEligible() == tranches * 1 ether, "missing account weight");
        require(queue.reservedDust() == 1, "old cohort dust was redistributed");
    }
}
