// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ActivationFlowFixture, ClaimCollateralFixture, FlowVm, FixtureToken} from "./NDAIActivationFlow.t.sol";

contract CatchUpFixture is ActivationFlowFixture {
    uint256 public head;
    uint256 private tailTime;
    uint256 private constant BATCH = 32;

    function keyCount() external view override returns (uint256) {
        return keys.length - head;
    }

    function slot(uint256 offset) external view returns (uint256) {
        return keys[offset];
    }

    function sync() external {
        _advance();
    }

    function _appendKey(uint256 at) internal override {
        if (keys.length != 0 && at == tailTime) return;
        keys.push(at);
        tailTime = at;
    }

    // A canceled slot remains in timestamp order and counts toward the batch.
    function _removeKey(uint256) internal override {}

    function _settleSeries() internal override {
        _advance();
        if (head < keys.length && keys[head] <= block.timestamp) revert CatchUpRequired();
    }

    function _advance() private {
        uint256 cursor = head;
        uint256 stop = cursor + BATCH;
        if (stop > keys.length) stop = keys.length;
        uint256 added;
        while (cursor < stop && keys[cursor] <= block.timestamp) {
            uint256 at = keys[cursor++];
            uint256 amount = pending[at];
            if (amount != 0) {
                checkpoint[at] = index;
                added += amount;
                delete pending[at];
            }
            delete keys[cursor - 1];
        }
        if (added != 0) {
            eligible += added;
            _reserveDust();
        }
        head = cursor;
    }
}

contract BacklogExitFixture is CatchUpFixture {
    function _settleWithdrawal() internal override {
        uint256 through = block.timestamp;
        if (head < keys.length && keys[head] <= through) {
            through = keys[head] - 1;
        }
        _settleAccount(through);
    }
}
contract PrunedQueueFixture is ActivationFlowFixture {
    mapping(uint256 => uint256) private next;
    mapping(uint256 => uint256) private previous;
    uint256 private first;
    uint256 private last;
    uint256 private count;

    function keyCount() external view override returns (uint256) { return count; }

    function _appendKey(uint256 at) internal override {
        previous[at] = last;
        if (last == 0) first = at;
        else next[last] = at;
        last = at;
        ++count;
    }

    function _removeKey(uint256 at) internal override {
        uint256 before = previous[at];
        uint256 afterKey = next[at];
        if (before == 0) first = afterKey;
        else next[before] = afterKey;
        if (afterKey == 0) last = before;
        else previous[afterKey] = before;
        delete next[at];
        delete previous[at];
        --count;
    }

    function sync() external { _advance(); }

    function _settleSeries() internal override {
        _advance();
        if (first != 0 && first <= block.timestamp) revert CatchUpRequired();
    }

    function _advance() private {
        uint256 added;
        for (uint256 i; i < 32 && first != 0 && first <= block.timestamp; ++i) {
            uint256 at = first;
            checkpoint[at] = index;
            added += pending[at];
            delete pending[at];
            _removeKey(at);
        }
        if (added != 0) {
            eligible += added;
            _reserveDust();
        }
    }

    function _settleWithdrawal() internal override {
        _settleAccount(first != 0 && first <= block.timestamp ? first - 1 : block.timestamp);
    }
}
// Single-series fixture. Issued collateral and fee-vault deposits have separate custody.
contract RetirementWithFeesFixture is PrunedQueueFixture, ERC721 {
    error AccountingCeiling();
    error VaultPrincipalCap();
    uint256 public vaultPrincipal;
    ClaimCollateralFixture public immutable positionCustody = new ClaimCollateralFixture();
    ClaimCollateralFixture public immutable feeEscrow = new ClaimCollateralFixture();

    function _payFee(address recipient, uint256 amount) internal override {
        feeEscrow.pay(claims, recipient, amount);
    }
    uint256 private constant MAX_FEES = 1e38;
    uint256 private constant MAX_INDEX = 1e65;
    struct Position {
        uint256 free;
        uint256 debt;
    }

    mapping(uint256 => Position) public positions;
    uint256 private nextId;
    uint256 public immutable maturity;

    constructor() ERC721("Test position", "TEST") {
        maturity = block.timestamp + 90 days;
    }

    function _updateVaultPrincipal(uint256 amount, bool depositing) internal override {
        if (depositing) {
            if (amount > 100_000_000 ether - vaultPrincipal) revert VaultPrincipalCap();
            vaultPrincipal += amount;
        } else {
            vaultPrincipal -= amount;
        }
    }

    function openPosition(uint256 amount) external returns (uint256 id) {
        require(block.timestamp < maturity && amount != 0);
        id = ++nextId;
        positions[id].free = amount;
        require(ndai.transferFrom(msg.sender, address(positionCustody), amount));
        _mint(msg.sender, id);
    }

    function issue(uint256) external pure override { revert(); }

    function extract(uint256 id, uint256 gross) external {
        require(ownerOf(id) == msg.sender && block.timestamp < maturity && gross != 0);
        _settle();
        positions[id].free -= gross;
        positions[id].debt += gross;
        positionCustody.pay(ndai, claimCollateral, gross);
        backing += gross;
        uint256 fee = eligible == 0 ? 0 : gross / 100 + (gross % 100 == 0 ? 0 : 1);
        claims.mint(msg.sender, gross - fee);
        if (fee != 0) {
            claims.mint(address(feeEscrow), fee);
            if (fee > MAX_FEES - feesReceived) revert AccountingCeiling();
            feesReceived += fee;
            uint256 scaled = fee * 1e27 + dust;
            uint256 increment = scaled / eligible;
            if (increment > MAX_INDEX - index) revert AccountingCeiling();
            index += increment;
            dust = scaled % eligible;
        }
    }

    function retire(uint256 id, uint256 amount) external {
        require(ownerOf(id) == msg.sender && block.timestamp < maturity && amount != 0);
        positions[id].debt -= amount;
        positions[id].free += amount;
        require(claims.transferFrom(msg.sender, address(this), amount));
        claims.burn(amount);
        backing -= amount;
        ClaimCollateralFixture(claimCollateral).pay(ndai, address(positionCustody), amount);
    }

    function redeem(uint256 amount) external {
        require(block.timestamp >= maturity && amount != 0);
        require(claims.transferFrom(msg.sender, address(this), amount));
        claims.burn(amount);
        backing -= amount;
        ClaimCollateralFixture(claimCollateral).pay(ndai, msg.sender, amount);
    }

    function withdrawPosition(uint256 id) external {
        require(ownerOf(id) == msg.sender && block.timestamp >= maturity);
        uint256 amount = positions[id].free;
        delete positions[id];
        _burn(id);
        positionCustody.pay(ndai, msg.sender, amount);
    }
}

contract NDAICatchUpAndRetirementTest {
    FlowVm private constant vm = FlowVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    event CatchUpGas(uint256 gasUsed);
    event PostCatchUpGas(string operation, uint256 gasUsed);
    address private constant BUYER = address(0x101);

    function testCatchUpAllowsMoreThan32KeysAndGuardsStaleIssuance() public {
        CatchUpFixture queue = new CatchUpFixture();
        FixtureToken token = queue.ndai();
        token.mint(address(this), 100 ether);
        token.approve(address(queue), type(uint256).max);
        for (uint256 i; i < 35; ++i) {
            address depositor = address(uint160(1000 + i));
            token.mint(depositor, 1 ether);
            vm.prank(depositor);
            token.approve(address(queue), 1 ether);
            vm.prank(depositor);
            queue.deposit(1 ether);
            vm.warp(vm.getBlockTimestamp() + 1);
        }
        require(queue.keyCount() == 35);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(ActivationFlowFixture.CatchUpRequired.selector);
        queue.issue(100 ether);
        require(queue.eligible() == 0 && queue.backing() == 0 && queue.feesReceived() == 0);
        require(queue.keyCount() == 35 && token.balanceOf(address(this)) == 100 ether);

        vm.cool(address(queue));
        uint256 before = gasleft();
        vm.prank(address(0x202));
        queue.sync();
        emit CatchUpGas(before - gasleft());
        require(queue.keyCount() == 3 && queue.eligible() == 32 ether);
        queue.issue(100 ether);
        require(queue.keyCount() == 0 && queue.eligible() == 35 ether);
        require(queue.feesReceived() == 1 ether && queue.backing() == 100 ether);
    }

    function testPrunedSlotsPreserveLazyRewardsAcrossBacklogBatches() public {
        CatchUpFixture queue = new CatchUpFixture();
        FixtureToken token = queue.ndai();
        token.mint(address(this), 300 ether);
        token.approve(address(queue), 300 ether);
        queue.deposit(1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        queue.issue(100 ether);
        uint256 firstActivation = vm.getBlockTimestamp() + 1 days;
        for (uint256 i; i < 96; ++i) {
            address depositor = address(uint160(1000 + i));
            token.mint(depositor, 1 ether);
            vm.prank(depositor);
            token.approve(address(queue), 1 ether);
            vm.prank(depositor);
            queue.deposit(1 ether);
            vm.warp(vm.getBlockTimestamp() + 1);
        }
        vm.warp(firstActivation + 95);
        for (uint256 batch; batch < 3; ++batch) {
            vm.cool(address(queue));
            uint256 before = gasleft();
            queue.sync();
            emit CatchUpGas(before - gasleft());
            require(queue.keyCount() == 64 - batch * 32);
        }
        require(queue.head() == 97 && queue.eligible() == 97 ether);
        for (uint256 i; i < 97; ++i) require(queue.slot(i) == 0);
        vm.cool(address(queue));
        uint256 beforeIssue = gasleft();
        queue.issue(9700);
        emit PostCatchUpGas("issuance", beforeIssue - gasleft());
        vm.prank(address(1000));
        require(queue.claimFees() == 1);
        vm.prank(address(1095));
        require(queue.claimFees() == 1);
        vm.prank(address(1000));
        require(queue.claimFees() == 0);
        require(queue.claimFees() == 1 ether + 1);
        vm.cool(address(queue));
        vm.prank(address(1095));
        uint256 beforeWithdrawal = gasleft();
        queue.withdraw(1 ether);
        emit PostCatchUpGas("early withdrawal", beforeWithdrawal - gasleft());
        require(queue.eligible() == 96 ether && queue.weight(address(1095)) == 0);
        queue.deposit(1 ether);
        require(queue.keyCount() == 1 && queue.slot(97) == vm.getBlockTimestamp() + 1 days);
    }
    function testCatchUpWhileMoreActivationsBecomeDue() public {
        CatchUpFixture queue = new CatchUpFixture();
        FixtureToken token = queue.ndai();
        token.mint(address(this), 200 ether);
        token.approve(address(queue), 200 ether);
        uint256 start = vm.getBlockTimestamp();
        queue.deposit(1 ether);
        for (uint256 i = 1; i < 180; ++i) {
            vm.warp(start + i);
            address depositor = address(uint160(2000 + i));
            token.mint(depositor, 1 ether);
            vm.prank(depositor);
            token.approve(address(queue), 1 ether);
            vm.prank(depositor);
            queue.deposit(1 ether);
        }

        uint256 firstDue = start + 1 days;
        uint256[3] memory firstRounds = [uint256(64), 96, 128];
        for (uint256 i; i < firstRounds.length; ++i) {
            vm.warp(firstDue + firstRounds[i]);
            queue.sync();
            require(queue.eligible() == (i + 1) * 32 ether);
            vm.expectRevert(ActivationFlowFixture.CatchUpRequired.selector);
            queue.issue(100 ether);
            vm.expectRevert(ActivationFlowFixture.CatchUpRequired.selector);
            queue.withdraw(1 ether);
            require(queue.eligible() == (i + 1) * 32 ether);
            require(queue.backing() == 0 && queue.feesReceived() == 0);
        }

        // New due keys now arrive more slowly than the explicit sync processes them.
        vm.warp(firstDue + 143);
        queue.sync();
        require(queue.eligible() == 128 ether);
        queue.issue(100 ether);
        require(queue.eligible() == 144 ether && queue.keyCount() == 36);
        require(queue.backing() == 100 ether && queue.feesReceived() == 1 ether);
        queue.withdraw(1 ether);
        require(queue.eligible() == 143 ether && queue.weight(address(this)) == 0);
    }
    function testPrunedQueueUnderSustainedLiveArrivals() public {
        PrunedQueueFixture queue = new PrunedQueueFixture();
        FixtureToken token = queue.ndai();
        token.mint(address(this), 200 ether);
        token.approve(address(queue), 200 ether);
        uint256 start = vm.getBlockTimestamp();
        queue.deposit(1 ether);
        for (uint256 i = 1; i < 180; ++i) {
            vm.warp(start + i);
            address depositor = address(uint160(2000 + i));
            token.mint(depositor, 1 ether);
            vm.prank(depositor);
            token.approve(address(queue), 1 ether);
            vm.prank(depositor);
            queue.deposit(1 ether);
        }

        uint256 firstDue = start + 1 days;
        uint256[3] memory firstRounds = [uint256(64), 96, 128];
        for (uint256 i; i < firstRounds.length; ++i) {
            vm.warp(firstDue + firstRounds[i]);
            queue.sync();
            require(queue.eligible() == (i + 1) * 32 ether);
            vm.expectRevert(ActivationFlowFixture.CatchUpRequired.selector);
            queue.issue(100 ether);
            require(queue.eligible() == (i + 1) * 32 ether);
            require(queue.backing() == 0 && queue.feesReceived() == 0);
        }

        // New due keys now arrive more slowly than the explicit sync processes them.
        vm.warp(firstDue + 143);
        queue.sync();
        require(queue.eligible() == 128 ether);
        queue.issue(100 ether);
        require(queue.eligible() == 144 ether && queue.keyCount() == 36);
        require(queue.backing() == 100 ether && queue.feesReceived() == 1 ether);
        queue.withdraw(1 ether);
        require(queue.eligible() == 143 ether && queue.weight(address(this)) == 0);
    }
    function testBacklogExitPreservesEarnedFeesAndCancelsUnprocessedWeight() public {
        BacklogExitFixture queue = new BacklogExitFixture();
        FixtureToken token = queue.ndai();
        token.mint(address(this), 300 ether);
        token.approve(address(queue), 300 ether);
        queue.deposit(1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        queue.issue(100 ether);
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < 40; ++i) {
            vm.warp(start + i);
            if (i >= 33) {
                queue.deposit(1 ether);
            } else {
                address depositor = address(uint160(2000 + i));
                token.mint(depositor, 1 ether);
                vm.prank(depositor);
                token.approve(address(queue), 1 ether);
                vm.prank(depositor);
                queue.deposit(1 ether);
            }
        }
        vm.warp(start + 1 days + 39);
        vm.expectRevert(ActivationFlowFixture.CatchUpRequired.selector);
        queue.issue(100 ether);
        queue.withdraw(8 ether);
        require(queue.head() == 1 && queue.keyCount() == 40);
        require(queue.weight(address(this)) == 0 && queue.eligible() == 0);
        require(queue.earnedScaled(address(this)) == 1 ether * 1e27);
        require(queue.backing() == 100 ether);
        queue.sync();
        queue.issue(100 ether);
        require(queue.eligible() == 33 ether && queue.keyCount() == 0);
        require(queue.claimFees() == 1 ether);
        require(queue.claimFees() == 0);
        require(queue.feesReceived() == 2 ether && queue.feesPaid() == 1 ether);
    }
    function testPartialBacklogExitAcrossThreeActivationStates() public {
        BacklogExitFixture queue = new BacklogExitFixture();
        FixtureToken token = queue.ndai();
        token.mint(address(this), 300 ether);
        token.approve(address(queue), 300 ether);
        uint256 start = vm.getBlockTimestamp();
        queue.deposit(4 ether);
        vm.warp(start + 1);
        queue.deposit(2 ether);
        vm.warp(start + 1 days);
        queue.issue(100 ether);
        queue.deposit(3 ether);
        vm.warp(start + 1 days + 1);
        queue.withdraw(6 ether);
        require(queue.eligible() == 3 ether && queue.weight(address(this)) == 3 ether);
        require(queue.pending(start + 1 days + 1) == 0);
        require(queue.pending(start + 2 days) == 0);
        require(queue.keyCount() == 2 && queue.backing() == 100 ether);
        queue.issue(300);
        require(queue.claimFees() == 1 ether + 3);
        require(queue.claimFees() == 0);
    }
    function testPrunedQueueRecoveryCadenceWithWithdrawals() public {
        PrunedQueueFixture queue = new PrunedQueueFixture();
        FixtureToken token = queue.ndai();
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < 128; ++i) {
            address account = address(uint160(5000 + i));
            vm.warp(start + i);
            token.mint(account, 1 ether);
            vm.prank(account);
            token.approve(address(queue), 1 ether);
            vm.prank(account);
            queue.deposit(1 ether);
        }
        token.mint(address(this), 100 ether);
        token.approve(address(queue), 100 ether);
        for (uint256 round; round < 3; ++round) {
            vm.warp(start + 1 days + 79 + 16 * round);
            vm.prank(address(0x202));
            queue.sync();
            require(queue.keyCount() == 128 - 32 * (round + 1));
            vm.prank(address(uint160(5000 + round)));
            queue.withdraw(1 ether);
            require(queue.eligible() == (round + 1) * 31 ether);
            if (round == 0) {
                vm.expectRevert(ActivationFlowFixture.CatchUpRequired.selector);
                queue.issue(100 ether);
            }
        }
        queue.issue(100 ether);
        require(queue.eligible() == 109 ether && queue.keyCount() == 16);
        require(queue.feesReceived() == 1 ether && queue.backing() == 100 ether);
    }
    function testPrunedQueueRecoversAfterMissedAndDelayedSync() public {
        PrunedQueueFixture queue = new PrunedQueueFixture();
        FixtureToken token = queue.ndai();
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < 128; ++i) {
            address account = address(uint160(6000 + i));
            vm.warp(start + i);
            token.mint(account, 1 ether);
            vm.prank(account);
            token.approve(address(queue), 1 ether);
            vm.prank(account);
            queue.deposit(1 ether);
        }
        token.mint(address(this), 100 ether);
        token.approve(address(queue), 100 ether);
        uint256 firstDue = start + 1 days;
        vm.warp(firstDue + 63);
        vm.prank(address(0x202));
        queue.sync();
        require(queue.eligible() == 32 ether);

        // Skip the sync at :79 and include its replacement eight seconds after :95.
        vm.warp(firstDue + 103);
        vm.prank(address(0x303));
        queue.sync();
        require(queue.keyCount() == 64 && queue.eligible() == 64 ether);
        vm.expectRevert(ActivationFlowFixture.CatchUpRequired.selector);
        queue.issue(100 ether);
        require(queue.keyCount() == 64 && queue.feesReceived() == 0 && queue.backing() == 0);
        vm.prank(address(6000));
        queue.withdraw(1 ether);
        require(queue.keyCount() == 64 && queue.eligible() == 63 ether);

        vm.warp(firstDue + 119);
        vm.prank(address(0x202));
        queue.sync();
        require(queue.keyCount() == 32 && queue.eligible() == 95 ether);
        queue.issue(100 ether);
        require(queue.keyCount() == 8 && queue.eligible() == 119 ether);
        require(queue.feesReceived() == 1 ether && queue.backing() == 100 ether);
    }
    function testPrunedQueueUnlinksHeadMiddleAndTail() public {
        PrunedQueueFixture queue = new PrunedQueueFixture();
        FixtureToken token = queue.ndai();
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < 5; ++i) {
            address depositor = address(uint160(3000 + i));
            vm.warp(start + i);
            token.mint(depositor, 3 ether);
            vm.prank(depositor);
            token.approve(address(queue), 3 ether);
            vm.prank(depositor);
            queue.deposit(1 ether);
        }
        vm.prank(address(3000));
        queue.withdraw(1 ether);
        vm.prank(address(3002));
        queue.withdraw(1 ether);
        vm.prank(address(3004));
        queue.withdraw(1 ether);
        require(queue.keyCount() == 2);
        vm.prank(address(3004));
        queue.deposit(2 ether);
        require(queue.keyCount() == 3);

        vm.warp(start + 1 days + 1);
        queue.sync();
        require(queue.eligible() == 1 ether && queue.keyCount() == 2);
        vm.warp(start + 1 days + 3);
        queue.sync();
        require(queue.eligible() == 2 ether && queue.keyCount() == 1);
        vm.warp(start + 1 days + 4);
        queue.sync();
        require(queue.eligible() == 4 ether && queue.keyCount() == 0);
        queue.sync();
        require(queue.eligible() == 4 ether);
    }
    function testPrunedQueueSameTimestampRedeposit() public {
        _checkRedeposit(new BacklogExitFixture(), 1);
        _checkRedeposit(new PrunedQueueFixture(), 0);
    }

    function _checkRedeposit(ActivationFlowFixture queue, uint256 canceledKeys) private {
        FixtureToken token = queue.ndai();
        token.mint(address(this), 400 ether);
        token.approve(address(queue), 400 ether);
        queue.deposit(1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        token.mint(BUYER, 3 ether);
        vm.prank(BUYER);
        token.approve(address(queue), 3 ether);
        uint256 at = vm.getBlockTimestamp() + 1 days;
        vm.prank(BUYER);
        queue.deposit(1 ether);
        vm.prank(BUYER);
        queue.withdraw(1 ether);
        require(queue.keyCount() == canceledKeys && queue.pending(at) == 0);
        vm.prank(BUYER);
        queue.deposit(1 ether);
        require(queue.keyCount() == 1 && queue.pending(at) == 1 ether);
        vm.warp(at - 1);
        queue.issue(100 ether);
        vm.prank(BUYER);
        require(queue.claimFees() == 0);
        vm.warp(at);
        queue.issue(100 ether);
        require(queue.eligible() == 2 ether && queue.keyCount() == 0);
        vm.prank(BUYER);
        require(queue.claimFees() == 0.5 ether);
        vm.prank(BUYER);
        require(queue.claimFees() == 0);
        require(queue.claimFees() == 1.5 ether);
        require(queue.feesPaid() == queue.feesReceived());
    }
    function testPositionAndFeeCustodyRejectUnauthorizedPayouts() public {
        RetirementWithFeesFixture vault = new RetirementWithFeesFixture();
        FixtureToken token = vault.ndai();
        token.mint(address(this), 103 ether);
        token.approve(address(vault), 103 ether);
        uint256 id = vault.openPosition(102 ether);
        vault.deposit(1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.extract(id, 100 ether);
        require(token.balanceOf(address(vault)) == 1 ether);
        require(token.balanceOf(address(vault.positionCustody())) == 2 ether);
        require(token.balanceOf(vault.claimCollateral()) == 100 ether);
        require(vault.claims().balanceOf(address(vault.feeEscrow())) == 1 ether);

        _rejectDirectCustody(vault);
        vm.prank(BUYER);
        vm.expectRevert();
        vault.extract(id, 1 ether);
        vm.prank(BUYER);
        vm.expectRevert();
        vault.retire(id, 1);
        require(vault.claimFees() == 1 ether);
        require(vault.claims().balanceOf(address(vault.feeEscrow())) == 0);
        require(token.balanceOf(vault.claimCollateral()) == 100 ether);
    }

    function _rejectDirectCustody(RetirementWithFeesFixture vault) private {
        // Low-level calls check each custodian independently without changing the owner.
        (bool position,) = address(vault.positionCustody()).call(
            abi.encodeCall(ClaimCollateralFixture.pay, (vault.ndai(), BUYER, 1))
        );
        (bool claim,) = vault.claimCollateral().call(
            abi.encodeCall(ClaimCollateralFixture.pay, (vault.ndai(), BUYER, 1))
        );
        (bool fee,) = address(vault.feeEscrow()).call(
            abi.encodeCall(ClaimCollateralFixture.pay, (vault.claims(), BUYER, 1))
        );
        require(!position && !claim && !fee);

    }
    function testVaultCapCountsPendingAndActivePrincipal() public {
        RetirementWithFeesFixture vault = new RetirementWithFeesFixture();
        FixtureToken token = vault.ndai();
        uint256 cap = 100_000_000 ether;
        token.mint(address(this), cap + 1 ether);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(cap - 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.deposit(1 ether);
        require(vault.eligible() == cap - 1 ether && vault.vaultPrincipal() == cap);
        vm.expectRevert(RetirementWithFeesFixture.VaultPrincipalCap.selector);
        vault.deposit(1 ether);
        require(token.balanceOf(address(vault)) == cap && vault.vaultPrincipal() == cap);
        vault.withdraw(1 ether);
        vault.deposit(1 ether);
        require(vault.vaultPrincipal() == cap && vault.eligible() == cap - 1 ether);
    }
    function testPositionIssuanceFeeWaiverLifecycle() public {
        RetirementWithFeesFixture vault = new RetirementWithFeesFixture();
        FixtureToken token = vault.ndai();
        token.mint(address(this), 401 ether);
        token.approve(address(vault), 401 ether);
        uint256 id = vault.openPosition(400 ether);
        vault.extract(id, 100 ether);
        require(vault.feesReceived() == 0 && vault.claims().balanceOf(address(this)) == 100 ether);
        vault.deposit(1 ether);
        uint256 activation = vm.getBlockTimestamp() + 1 days;
        vm.warp(activation - 1);
        vault.extract(id, 100 ether);
        require(vault.feesReceived() == 0 && vault.claims().balanceOf(address(this)) == 200 ether);
        vm.warp(activation);
        vault.extract(id, 100 ether);
        require(vault.feesReceived() == 1 ether && vault.claims().balanceOf(address(this)) == 299 ether);
        vault.withdraw(1 ether);
        vault.extract(id, 100 ether);
        require(vault.eligible() == 0 && vault.feesReceived() == 1 ether);
        require(vault.claims().balanceOf(address(this)) == 399 ether);
        require(vault.claimFees() == 1 ether && vault.claimFees() == 0);
        require(vault.claims().totalSupply() == 400 ether && vault.backing() == 400 ether);
        require(token.balanceOf(vault.claimCollateral()) == 400 ether);
    }
    function testCeilingCrossingRollsBackAndPreservesExitPaths() public {
        RetirementWithFeesFixture vault = new RetirementWithFeesFixture();
        FixtureToken token = vault.ndai();
        FixtureToken claims = vault.claims();
        uint256 gross = 1e40;
        token.mint(address(this), gross + 101);
        token.approve(address(vault), gross + 101);
        uint256 id = vault.openPosition(gross + 100);
        vault.deposit(1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.extract(id, gross);
        require(vault.feesReceived() == 1e38 && vault.index() == 1e65);
        vm.expectRevert(RetirementWithFeesFixture.AccountingCeiling.selector);
        vault.extract(id, 100);
        (uint256 free, uint256 debt) = vault.positions(id);
        require(free == 100 && debt == gross);
        require(vault.backing() == gross && claims.totalSupply() == gross);
        require(token.balanceOf(vault.claimCollateral()) == gross);
        require(vault.feesReceived() == 1e38 && vault.index() == 1e65);

        require(vault.claimFees() == 1e38);
        vault.withdraw(1);
        vault.extract(id, 100);
        require(vault.feesReceived() == 1e38 && vault.index() == 1e65);
        claims.approve(address(vault), type(uint256).max);
        vault.retire(id, 1);
        vm.warp(vault.maturity());
        vault.withdrawPosition(id);
        vault.redeem(gross + 99);
        require(token.balanceOf(address(this)) == gross + 101);
        require(vault.backing() == 0 && claims.totalSupply() == 0);
    }
    function testFeeDerivedClaimRetiresTransferredPosition() public {
        RetirementWithFeesFixture vault = new RetirementWithFeesFixture();
        FixtureToken token = vault.ndai();
        FixtureToken claims = vault.claims();
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        uint256 id = vault.openPosition(100 ether);
        token.mint(BUYER, 10 ether);
        vm.prank(BUYER);
        token.approve(address(vault), 10 ether);
        vm.prank(BUYER);
        vault.deposit(10 ether);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.extract(id, 100 ether);
        vault.transferFrom(address(this), BUYER, id);
        vm.prank(BUYER);
        require(vault.claimFees() == 1 ether);
        vm.prank(BUYER);
        claims.approve(address(vault), 1 ether);
        vm.prank(BUYER);
        vault.retire(id, 1 ether);
        (uint256 free, uint256 debt) = vault.positions(id);
        require(free == 1 ether && debt == 99 ether);
        require(claims.totalSupply() == 99 ether && vault.backing() == 99 ether);
        require(token.balanceOf(vault.claimCollateral()) == 99 ether);
        require(token.balanceOf(BUYER) == 0 && vault.weight(BUYER) == 10 ether);
        require(vault.feesReceived() == 1 ether && vault.feesPaid() == 1 ether);
        vm.prank(BUYER);
        require(vault.claimFees() == 0);

        vm.warp(vault.maturity());
        claims.approve(address(vault), 99 ether);
        vault.redeem(99 ether);
        vm.prank(BUYER);
        vault.withdrawPosition(id);
        require(token.balanceOf(address(this)) == 99 ether && token.balanceOf(BUYER) == 1 ether);
        require(token.balanceOf(address(vault)) == 10 ether);
        require(vault.backing() == 0 && claims.totalSupply() == 0);
    }
}

















