// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BenchmarkVm} from "./NDAIActivationBenchmark.t.sol";

contract FixtureToken is ERC20 {
    constructor() ERC20("Fixture", "FIX") {}
    function mint(address account, uint256 amount) external { _mint(account, amount); }
    function burn(uint256 amount) external { _burn(msg.sender, amount); }
}

contract ClaimCollateralFixture {
    address private immutable controller = msg.sender;

    function pay(FixtureToken token, address recipient, uint256 amount) external {
        require(msg.sender == controller);
        require(token.transfer(recipient, amount));
    }
}

// Test fixture for gas measurement. Token minting and issuance funding are simplified.
contract ActivationFlowFixture {
    error Capacity();
    error CatchUpRequired();
    FixtureToken public immutable ndai;
    FixtureToken public immutable claims;
    address public immutable claimCollateral;
    uint256[] internal keys;
    mapping(uint256 => uint256) public pending;
    mapping(uint256 => uint256) public checkpoint;
    mapping(address => uint256[]) private tranches;
    mapping(address => mapping(uint256 => uint256)) private amounts;
    mapping(address => uint256) public weight;
    mapping(address => uint256) private lastIndex;
    mapping(address => uint256) public earnedScaled;
    mapping(address => uint256) private lastDeposit;
    uint256 public eligible;
    uint256 public index;
    uint256 public dust;
    uint256 public reservedDust;
    uint256 public backing;
    uint256 public feesReceived;
    uint256 public feesPaid;

    constructor() {
        ndai = new FixtureToken();
        claims = new FixtureToken();
        claimCollateral = address(new ClaimCollateralFixture());
    }

    function keyCount() external view virtual returns (uint256) { return keys.length; }

    function deposit(uint256 amount) external {
        require(amount != 0);
        _updateVaultPrincipal(amount, true);
        _settle();
        uint256 at = block.timestamp + 1 days;
        uint256[] storage entries = tranches[msg.sender];
        if (pending[at] == 0) {
            _appendKey(at);
        }
        if (amounts[msg.sender][at] == 0) {
            if (entries.length == 8) revert Capacity();
            entries.push(at);
        }
        pending[at] += amount;
        amounts[msg.sender][at] += amount;
        lastDeposit[msg.sender] = block.timestamp;
        require(ndai.transferFrom(msg.sender, address(this), amount));
    }

    function issue(uint256 gross) external virtual {
        _settle();
        _issue(gross);
    }

    function _issue(uint256 gross) internal {
        uint256 balanceBefore = ndai.balanceOf(claimCollateral);
        require(ndai.transferFrom(msg.sender, claimCollateral, gross));
        require(ndai.balanceOf(claimCollateral) - balanceBefore == gross);
        backing += gross;
        uint256 fee = eligible == 0 ? 0 : gross / 100 + (gross % 100 == 0 ? 0 : 1);
        claims.mint(msg.sender, gross - fee);
        if (fee != 0) {
            claims.mint(address(this), fee);
            feesReceived += fee;
            uint256 scaled = fee * 1e27 + dust;
            index += scaled / eligible;
            dust = scaled % eligible;
        }
    }

    function _payFee(address recipient, uint256 amount) internal virtual {
        require(claims.transfer(recipient, amount));
    }

    function claimFees() external returns (uint256 amount) {
        _settle();
        amount = earnedScaled[msg.sender] / 1e27;
        earnedScaled[msg.sender] %= 1e27;
        feesPaid += amount;
        require(feesPaid <= feesReceived);
        if (amount != 0) _payFee(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        _settleWithdrawal();
        _updateVaultPrincipal(amount, false);
        uint256 left = amount;
        uint256[] storage entries = tranches[msg.sender];
        while (left != 0 && entries.length != 0) {
            uint256 at = entries[entries.length - 1];
            uint256 available = amounts[msg.sender][at];
            uint256 taken = left < available ? left : available;
            pending[at] -= taken;
            amounts[msg.sender][at] -= taken;
            left -= taken;
            if (taken == available) entries.pop();
            if (pending[at] == 0) {
                _removeKey(at);
            }
        }
        if (left != 0) {
            weight[msg.sender] -= left;
            eligible -= left;
            _reserveDust();
        }
        uint256 elapsed = block.timestamp - lastDeposit[msg.sender];
        uint256 penalty = elapsed >= 90 days ? 0 : amount * (90 days - elapsed) / (20 * 90 days);
        if (penalty != 0) ndai.burn(penalty);
        require(ndai.transfer(msg.sender, amount - penalty));
    }

    function _updateVaultPrincipal(uint256, bool) internal virtual {}

    function _reserveDust() internal {
        reservedDust += dust;
        dust = 0;
    }

    function _appendKey(uint256 at) internal virtual {
        if (keys.length == 32) revert Capacity();
        keys.push(at);
    }

    function _removeKey(uint256 at) internal virtual {
        uint256 i;
        while (keys[i] != at) ++i;
        for (; i + 1 < keys.length; ++i) keys[i] = keys[i + 1];
        keys.pop();
    }

    function _settleSeries() internal virtual {
        uint256 due;
        while (due < keys.length && keys[due] <= block.timestamp) {
            uint256 at = keys[due++];
            checkpoint[at] = index;
            eligible += pending[at];
            delete pending[at];
        }
        if (due != 0) {
            _reserveDust();
            uint256 remaining = keys.length - due;
            for (uint256 i; i < remaining; ++i) keys[i] = keys[i + due];
            while (keys.length > remaining) keys.pop();
        }
    }

    function _settle() internal {
        _settleSeries();
        _settleAccount(block.timestamp);
    }

    function _settleWithdrawal() internal virtual {
        _settle();
    }

    function _settleAccount(uint256 through) internal {
        address account = msg.sender;
        earnedScaled[account] += weight[account] * (index - lastIndex[account]);
        lastIndex[account] = index;
        uint256[] storage entries = tranches[account];
        uint256 activated;
        while (activated < entries.length && entries[activated] <= through) {
            uint256 at = entries[activated++];
            uint256 amount = amounts[account][at];
            earnedScaled[account] += amount * (index - checkpoint[at]);
            weight[account] += amount;
            delete amounts[account][at];
        }
        if (activated != 0) {
            uint256 remaining = entries.length - activated;
            for (uint256 i; i < remaining; ++i) entries[i] = entries[i + activated];
            while (entries.length > remaining) entries.pop();
        }
    }
}

interface FlowVm is BenchmarkVm {
    function chainId(uint256) external;
    function getBlockTimestamp() external view returns (uint256);
    function prank(address) external;
    function expectRevert(bytes4) external;
    function expectRevert() external;
}

contract NDAIActivationFlowTest {
    FlowVm private constant vm = FlowVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    ActivationFlowFixture private vault;
    FixtureToken private ndai;
    event MeasuredGas(string operation, uint256 used);

    function setUp() public {
        vault = new ActivationFlowFixture();
        ndai = vault.ndai();
        ndai.mint(address(this), 1000 ether);
        ndai.approve(address(vault), type(uint256).max);
    }

    function testFirstIssuanceWaivesFeeAtZeroWeight() public {
        vault.issue(100 ether);
        require(vault.claims().balanceOf(address(this)) == 100 ether);
        require(vault.feesReceived() == 0 && vault.index() == 0);
        require(vault.backing() == 100 ether && ndai.balanceOf(vault.claimCollateral()) == 100 ether);
    }

    function testLaterIssuanceWaivesFeeAfterLastEligibleDepositExits() public {
        vault.deposit(1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.issue(100 ether);
        vault.withdraw(1 ether);
        require(vault.eligible() == 0);
        uint256 priorIndex = vault.index();
        vault.issue(100 ether);
        require(vault.claims().balanceOf(address(this)) == 199 ether);
        require(vault.feesReceived() == 1 ether && vault.index() == priorIndex);
        require(vault.backing() == 200 ether && ndai.balanceOf(vault.claimCollateral()) == 200 ether);
        require(vault.claimFees() == 1 ether);
    }

    function testIssuanceCollectsFeeAtExactActivation() public {
        vault.deposit(1 ether);
        uint256 activation = vm.getBlockTimestamp() + 1 days;
        vm.warp(activation - 1);
        vault.issue(100 ether);
        require(vault.eligible() == 0 && vault.feesReceived() == 0);
        vm.warp(activation);
        vault.issue(100 ether);
        require(vault.eligible() == 1 ether && vault.feesReceived() == 1 ether);
        require(vault.claims().balanceOf(address(this)) == 199 ether);
        require(vault.backing() == 200 ether && ndai.balanceOf(vault.claimCollateral()) == 200 ether);
        require(vault.claimFees() == 1 ether);
    }
    function testColdFullIssue() public {
        _fill();
        vm.warp(block.timestamp + 1 days);
        _cool();
        uint256 start = gasleft();
        vault.issue(100 ether);
        emit MeasuredGas("issue", start - gasleft());
        require(vault.eligible() == 32 ether && vault.weight(address(this)) == 8 ether);
        require(vault.backing() == 100 ether && vault.claims().totalSupply() == 100 ether);
        require(ndai.balanceOf(vault.claimCollateral()) == 100 ether);
        require(ndai.balanceOf(address(vault)) == 32 ether);
        require(vault.claims().balanceOf(address(vault)) == 1 ether);
        require(vault.claimFees() == 0.25 ether);
        require(vault.claimFees() == 0);
        require(vault.feesPaid() + vault.claims().balanceOf(address(vault)) == vault.feesReceived());
    }

    function testColdPartialCompactionWithEightTranches() public {
        uint256 firstActivation = block.timestamp + 1 days;
        for (uint256 i; i < 32; ++i) {
            address account = i < 8 ? address(this) : address(uint160(100 + i));
            if (i >= 8) _fund(account);
            vm.prank(account);
            vault.deposit(1 ether);
            vm.warp(vm.getBlockTimestamp() + 1);
        }
        // Activating only the oldest key leaves the maximum number of entries to shift.
        vm.warp(firstActivation);
        _cool();
        uint256 start = gasleft();
        vault.issue(100 ether);
        emit MeasuredGas("partial compaction and issue", start - gasleft());
        require(vault.weight(address(this)) == 1 ether, "unexpected active tranche");
        require(vault.eligible() == 1 ether && vault.keyCount() == 31, "wrong queue state");
    }

    function testRepeatedSaturationAndRecovery() public {
        address next = address(999);
        _fund(next);
        for (uint256 round; round < 8; ++round) {
            _fill();
            vm.warp(vm.getBlockTimestamp() + 1);
            vm.expectRevert(ActivationFlowFixture.Capacity.selector);
            vm.prank(next);
            vault.deposit(1 ether);
            vm.prank(address(108));
            vault.withdraw(1 ether);
            vm.prank(next);
            vault.deposit(1 ether);
            require(vault.keyCount() == 32, "queue did not refill");
            vm.warp(vm.getBlockTimestamp() + 1 days);
            vault.issue(1 ether + 1);
            require(vault.keyCount() == 0, "queue did not drain");
            require(vault.eligible() == (round + 1) * 32 ether, "weight duplicated");
            require(ndai.balanceOf(vault.claimCollateral()) == vault.claims().totalSupply());
        }
        require(vault.feesReceived() == 8 * (0.01 ether + 1), "wrong fee rounding");
    }

    function testCompetingDepositorCanRepeatedlyTakeFreedSlot() public {
        _fill();
        address waiting = address(998);
        address competitor = address(999);
        _fund(waiting);
        _fund(competitor);

        for (uint256 i; i < 8; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1);
            vm.prank(address(uint160(108 + i)));
            vault.withdraw(1 ether);
            vm.prank(competitor);
            vault.deposit(1 ether);

            vm.warp(vm.getBlockTimestamp() + 1);
            vm.expectRevert(ActivationFlowFixture.Capacity.selector);
            vm.prank(waiting);
            vault.deposit(1 ether);
            require(vault.keyCount() == 32, "queue unexpectedly changed");
        }
        require(ndai.balanceOf(waiting) == 10 ether, "rejected deposit charged user");
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(waiting);
        vault.deposit(1 ether);
        require(vault.eligible() == 32 ether && vault.keyCount() == 1);
    }

    function testColdFullWithdrawalWithBurn() public {
        _fill();
        vm.warp(block.timestamp + 1 days);
        uint256 balanceBefore = ndai.balanceOf(address(this));
        uint256 supplyBefore = ndai.totalSupply();
        _cool();
        uint256 start = gasleft();
        vault.withdraw(8 ether);
        emit MeasuredGas("withdraw with burn", start - gasleft());
        require(vault.eligible() == 24 ether && vault.weight(address(this)) == 0);
        uint256 burn = uint256(8 ether) * (90 days - 1 days - 24) / (20 * 90 days);
        require(ndai.totalSupply() == supplyBefore - burn);
        require(ndai.balanceOf(address(this)) == balanceBefore + 8 ether - burn);
    }

    function testFullQueueRejectsThenRecoversAfterCancellationAndActivation() public {
        _fill();
        address next = address(999);
        _fund(next);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(ActivationFlowFixture.Capacity.selector);
        vm.prank(next);
        vault.deposit(1 ether);
        vm.prank(address(108));
        vault.withdraw(1 ether);
        require(vault.keyCount() == 31);
        vm.prank(next);
        vault.deposit(1 ether);
        require(vault.keyCount() == 32);
        vm.warp(block.timestamp + 1 days);
        vm.prank(next);
        vault.deposit(1 ether);
        require(vault.keyCount() == 1 && vault.eligible() == 32 ether);
    }

    function testCoalescingCancellationAndExactActivation() public {
        uint256 activation = block.timestamp + 1 days;
        vault.deposit(1 ether);
        vault.deposit(2 ether);
        require(vault.keyCount() == 1 && vault.pending(activation) == 3 ether);
        vault.withdraw(1 ether);
        vm.warp(activation - 1);
        vault.issue(100 ether);
        require(vault.claims().balanceOf(address(vault)) == 0);
        vm.warp(activation);
        vault.issue(100 ether);
        require(vault.eligible() == 2 ether && vault.checkpoint(activation) == 0);
        require(vault.claims().balanceOf(address(vault)) == 1 ether);
        vault.withdraw(2 ether);
        require(vault.earnedScaled(address(this)) == 1e45 && vault.eligible() == 0);
    }

    function _fund(address account) private {
        ndai.mint(account, 10 ether);
        vm.prank(account);
        ndai.approve(address(vault), type(uint256).max);
    }

    function _fill() private {
        for (uint256 i; i < 32; ++i) {
            address account = i < 8 ? address(this) : address(uint160(100 + i));
            if (i >= 8) _fund(account);
            vm.prank(account);
            vault.deposit(1 ether);
            if (i != 31) vm.warp(vm.getBlockTimestamp() + 1);
        }
    }

    function _cool() private {
        vm.cool(address(vault));
        vm.cool(address(ndai));
        vm.cool(address(vault.claims()));
    }
}






