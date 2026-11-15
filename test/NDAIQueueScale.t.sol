// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BacklogExitFixture, PrunedQueueFixture} from "./NDAICatchUpAndRetirement.t.sol";
import {FlowVm, FixtureToken} from "./NDAIActivationFlow.t.sol";

interface RecoveryQueue {
    function keyCount() external view returns (uint256);
    function sync() external;
    function issue(uint256) external;
    function eligible() external view returns (uint256);
    function feesReceived() external view returns (uint256);
}

contract DeferredRecoveryFixture is BacklogExitFixture {
    function seed(uint256 count, uint256 canceled, uint256 start) external {
        for (uint256 i; i < count; ++i) {
            _appendKey(start + i);
            if (i >= canceled) pending[start + i] = 1 ether;
        }

    }

    function cleanup() external {
        for (uint256 i; i < 32 && head < keys.length; ++i) {
            uint256 at = keys[head];
            if (pending[at] != 0) break;
            delete keys[head++];
        }
    }
}

contract PrunedRecoveryFixture is PrunedQueueFixture {
    function seed(uint256 count, uint256 canceled, uint256 start) external {
        for (uint256 i = canceled; i < count; ++i) {
            _appendKey(start + i);
            pending[start + i] = 1 ether;
        }

    }
}

contract NDAIQueueScaleTest {
    FlowVm private constant vm = FlowVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    event Recovery(string strategy, uint256 seeded, uint256 calls, uint256 gasUsed);

    function testRecovery100() public { _compare(100); }
    function testRecovery1000() public { _compare(1000); }
    function testRecovery10000() public { _compare(10000); }

    function testRepeatedRedepositAndSimultaneousActivation() public {
        PrunedQueueFixture queue = new PrunedQueueFixture();
        FixtureToken token = queue.ndai();
        token.mint(address(this), 300 ether);
        token.approve(address(queue), type(uint256).max);
        for (uint256 i; i < 16; ++i) {
            queue.deposit(1 ether);
            queue.withdraw(1 ether);
            require(queue.keyCount() == 0);
        }
        for (uint256 i; i < 100; ++i) {
            address depositor = address(uint160(4000 + i));
            token.mint(depositor, 1 ether);
            vm.prank(depositor);
            token.approve(address(queue), 1 ether);
            vm.prank(depositor);
            queue.deposit(1 ether);
        }
        require(queue.keyCount() == 1);
        vm.warp(vm.getBlockTimestamp() + 1 days - 1);
        queue.issue(100 ether);
        require(queue.feesReceived() == 0 && queue.eligible() == 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        queue.issue(100 ether);
        require(queue.feesReceived() == 1 ether && queue.eligible() == 100 ether);
        vm.prank(address(4000));
        require(queue.claimFees() == 0.01 ether);
        vm.prank(address(4000));
        require(queue.claimFees() == 0);
    }
    function testBurstRecoveryAfterMissedInterval() public {
        PrunedRecoveryFixture queue = new PrunedRecoveryFixture();
        uint256 first = vm.getBlockTimestamp() + 1 days;
        queue.seed(256, 0, first);
        queue.ndai().mint(address(this), 100 ether);
        queue.ndai().approve(address(queue), 100 ether);

        vm.warp(first + 159);
        vm.expectRevert(bytes4(keccak256("CatchUpRequired()")));
        queue.issue(100 ether);
        require(queue.eligible() == 0 && queue.feesReceived() == 0);

        vm.warp(first + 175);
        for (uint256 i; i < 4; ++i) queue.sync();
        require(queue.eligible() == 128 ether);
        vm.expectRevert(bytes4(keccak256("CatchUpRequired()")));
        queue.issue(100 ether);

        vm.warp(first + 191);
        for (uint256 i; i < 4; ++i) queue.sync();
        require(queue.eligible() == 192 ether && queue.keyCount() == 64);
        queue.issue(100 ether);
        require(queue.feesReceived() == 1 ether && queue.backing() == 100 ether);
    }
    function testRecovery10000Live() public {
        PrunedRecoveryFixture pruned = new PrunedRecoveryFixture();
        for (uint256 i; i < 10000; i += 256) {
            pruned.seed(i + 256 <= 10000 ? 256 : 10000 - i, 0, i + 1);
        }
        pruned.ndai().mint(address(this), 100 ether);
        pruned.ndai().approve(address(pruned), 100 ether);
        vm.warp(20000);
        _recover(RecoveryQueue(address(pruned)), "immediate all live", 10000, 0, 0);
    }

    function _compare(uint256 count) private {
        uint256 canceled = count * 9 / 10;
        DeferredRecoveryFixture deferred = new DeferredRecoveryFixture();
        DeferredRecoveryFixture incremental = new DeferredRecoveryFixture();
        PrunedRecoveryFixture pruned = new PrunedRecoveryFixture();
        for (uint256 i; i < count; i += 256) {
            uint256 batch = count - i < 256 ? count - i : 256;
            uint256 empty = canceled > i ? canceled - i : 0;
            if (empty > batch) empty = batch;
            deferred.seed(batch, empty, i + 1);
            incremental.seed(batch, empty, i + 1);
        }
        deferred.ndai().mint(address(this), 100 ether);
        incremental.ndai().mint(address(this), 100 ether);
        for (uint256 i = canceled; i < count; i += 256) {
            pruned.seed(count - i < 256 ? count - i : 256, 0, i + 1);
        }
        pruned.ndai().mint(address(this), 100 ether);
        deferred.ndai().approve(address(deferred), 100 ether);
        incremental.ndai().approve(address(incremental), 100 ether);
        pruned.ndai().approve(address(pruned), 100 ether);
        vm.warp(20000);
        _recover(RecoveryQueue(address(deferred)), "deferred", count, canceled, 0);
        _recover(RecoveryQueue(address(incremental)), "incremental", count, canceled, (canceled + 31) / 32);
        _recover(RecoveryQueue(address(pruned)), "immediate", count, canceled, 0);
    }

    function _recover(RecoveryQueue queue, string memory strategy, uint256 count, uint256 canceled, uint256 cleanupCalls) private {
        uint256 before = gasleft();
        for (uint256 i; i < cleanupCalls; ++i) DeferredRecoveryFixture(address(queue)).cleanup();
        uint256 syncCalls;
        while (queue.keyCount() > 32) {
            queue.sync();
            ++syncCalls;
        }
        queue.issue(100 ether);
        emit Recovery(strategy, count, cleanupCalls + syncCalls + 1, before - gasleft());
        require(queue.keyCount() == 0 && queue.eligible() == (count - canceled) * 1 ether);
        require(queue.feesReceived() == 1 ether);
    }
}






