// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NDAICustody} from "./NDAICustody.sol";

interface INDAIBurnable is IERC20 {
    function burn(uint256 amount) external;
}

contract NDAIFeeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SCALE = 1e27;
    uint256 public constant PRINCIPAL_CAP = 100_000_000 ether;
    uint256 public constant FEE_CAP = 1e38;
    uint256 public constant INDEX_CAP = 1e65;
    uint256 public constant SYNC_LIMIT = 32;
    uint256 public constant TRANCHE_LIMIT = 8;

    struct Bucket {
        uint256 principal;
        uint256 previous;
        uint256 next;
    }

    struct Tranche {
        uint256 activation;
        uint256 principal;
    }

    struct Account {
        uint256 weight;
        uint256 lastIndex;
        uint256 earnedScaled;
        uint256 lockedFrom;
        Tranche[] pending;
    }

    IERC20 public immutable ndai;
    IERC20 public immutable claimToken;
    NDAICustody public immutable feeEscrow;
    address public immutable series;
    uint256 public immutable launchTime;
    uint256 public immutable redemptionTime;
    uint256 public firstActivation;
    uint256 public lastActivation;
    uint256 public totalPrincipal;
    uint256 public eligiblePrincipal;
    uint256 public rewardIndex;
    uint256 public feesReceived;
    uint256 public feesPaid;
    uint256 public carry;
    uint256 public reservedDust;
    uint256 public processedKeys;

    mapping(uint256 => Bucket) private buckets;
    mapping(uint256 => uint256) public activationIndex;
    mapping(uint256 => uint256) public checkpointUsers;
    mapping(address => Account) private accounts;

    error WrongChain();
    error OnlySeries();
    error InvalidAmount();
    error DepositClosed();
    error Capacity();
    error CatchUpRequired();
    error AccountingCeiling();
    error UnexpectedReceipt();

    event Deposited(address indexed account, uint256 amount, uint256 activation);
    event Withdrawn(address indexed account, uint256 amount, uint256 burned);
    event Synchronized(uint256 processed, uint256 nextActivation, uint256 eligible);
    event FeeCollected(uint256 amount, uint256 index);
    event FeeClaimed(address indexed account, uint256 amount);

    constructor(IERC20 asset, IERC20 claim, uint256 start, uint256 maturity) {
        if (block.chainid != 369) revert WrongChain();
        ndai = asset;
        claimToken = claim;
        series = msg.sender;
        launchTime = start;
        redemptionTime = maturity;
        feeEscrow = new NDAICustody(claim);
    }

    modifier onlySeries() {
        if (msg.sender != series) revert OnlySeries();
        _;
    }

    function accountState(address account) external view returns (
        uint256 settledWeight, uint256 earnedScaled, uint256 lockEnds, Tranche[] memory pending
    ) {
        Account storage state = accounts[account];
        return (state.weight, _earned(state), state.lockedFrom == 0 ? 0 : state.lockedFrom + 90 days, state.pending);
    }

    function pendingAt(uint256 activation) external view returns (uint256 principal, uint256 next) {
        Bucket storage bucket = buckets[activation];
        return (bucket.principal, bucket.next);
    }

    /// @notice Returns at most 33 distinct due keys. 33 means issuance needs catch-up.
    function dueKeyCount() external view returns (uint256 count) {
        uint256 at = firstActivation;
        while (count <= SYNC_LIMIT && at != 0 && at <= block.timestamp) {
            ++count;
            at = buckets[at].next;
        }
    }

    function sync() external nonReentrant returns (uint256) {
        return _sync();
    }

    function deposit(uint256 amount) external nonReentrant {
        if (block.timestamp < launchTime || block.timestamp >= redemptionTime) revert DepositClosed();
        if (amount < 1 ether) revert InvalidAmount();
        if (amount > PRINCIPAL_CAP - totalPrincipal) revert Capacity();
        _sync();
        Account storage state = accounts[msg.sender];
        _settle(state);
        uint256 at = block.timestamp + 1 days;
        uint256 count = state.pending.length;
        if (count != 0 && state.pending[count - 1].activation == at) {
            state.pending[count - 1].principal += amount;
        } else {
            if (count == TRANCHE_LIMIT) revert Capacity();
            state.pending.push(Tranche(at, amount));
            ++checkpointUsers[at];
        }
        Bucket storage bucket = buckets[at];
        if (bucket.principal == 0) {
            bucket.previous = lastActivation;
            if (lastActivation == 0) firstActivation = at;
            else buckets[lastActivation].next = at;
            lastActivation = at;
        }
        bucket.principal += amount;
        state.lockedFrom = block.timestamp;
        totalPrincipal += amount;
        uint256 balanceBefore = ndai.balanceOf(address(this));
        ndai.safeTransferFrom(msg.sender, address(this), amount);
        if (ndai.balanceOf(address(this)) - balanceBefore != amount) revert UnexpectedReceipt();
        emit Deposited(msg.sender, amount, at);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0 || amount > totalPrincipal) revert InvalidAmount();
        Account storage state = accounts[msg.sender];
        _settle(state);
        uint256 remaining = amount;
        while (remaining != 0 && state.pending.length != 0) {
            Tranche storage tranche = state.pending[state.pending.length - 1];
            uint256 taken = Math.min(remaining, tranche.principal);
            uint256 at = tranche.activation;
            tranche.principal -= taken;
            remaining -= taken;
            buckets[at].principal -= taken;
            if (buckets[at].principal == 0) _unlink(at);
            if (tranche.principal == 0) {
                _releaseCheckpoint(at);
                state.pending.pop();
            }
        }
        if (remaining > state.weight) revert InvalidAmount();
        if (remaining != 0) {
            state.weight -= remaining;
            eligiblePrincipal -= remaining;
            _quarantineCarry();
        }
        totalPrincipal -= amount;

        uint256 lockEnd = state.lockedFrom + 90 days;
        uint256 penalty;
        if (block.timestamp < lockEnd) {
            penalty = Math.mulDiv(amount, lockEnd - block.timestamp, 20 * 90 days);
            if (penalty != 0) INDAIBurnable(address(ndai)).burn(penalty);
        }
        if (amount > penalty) ndai.safeTransfer(msg.sender, amount - penalty);
        emit Withdrawn(msg.sender, amount, penalty);
    }

    function claimFees() external nonReentrant returns (uint256 amount) {
        Account storage state = accounts[msg.sender];
        _settle(state);
        amount = state.earnedScaled / SCALE;
        if (amount == 0) return 0;
        state.earnedScaled %= SCALE;
        feesPaid += amount;
        feeEscrow.pay(msg.sender, amount);
        emit FeeClaimed(msg.sender, amount);
    }

    function prepareIssuance() external onlySeries nonReentrant returns (uint256) {
        _sync();
        if (firstActivation != 0 && firstActivation <= block.timestamp) revert CatchUpRequired();
        return eligiblePrincipal;
    }

    function recordFee(uint256 amount, uint256 balanceBefore) external onlySeries nonReentrant {
        if (amount == 0 || eligiblePrincipal == 0) revert InvalidAmount();
        if (claimToken.balanceOf(address(feeEscrow)) != balanceBefore + amount) revert UnexpectedReceipt();
        if (amount > FEE_CAP - feesReceived) revert AccountingCeiling();
        uint256 weight = eligiblePrincipal;
        uint256 increment = Math.mulDiv(amount, SCALE, weight);
        uint256 remainder = mulmod(amount, SCALE, weight) + carry;
        increment += remainder / weight;
        if (increment > INDEX_CAP - rewardIndex) revert AccountingCeiling();
        carry = remainder % weight;
        rewardIndex += increment;
        feesReceived += amount;
        emit FeeCollected(amount, rewardIndex);
    }

    function _sync() private returns (uint256 processed) {
        while (processed < SYNC_LIMIT && firstActivation != 0 && firstActivation <= block.timestamp) {
            uint256 at = firstActivation;
            activationIndex[at] = rewardIndex;
            eligiblePrincipal += buckets[at].principal;
            _unlink(at);
            ++processed;
        }
        if (processed != 0) {
            processedKeys += processed;
            _quarantineCarry();
            emit Synchronized(processed, firstActivation, eligiblePrincipal);
        }
    }

    function _unlink(uint256 at) private {
        Bucket memory bucket = buckets[at];
        if (bucket.previous == 0) firstActivation = bucket.next;
        else buckets[bucket.previous].next = bucket.next;
        if (bucket.next == 0) lastActivation = bucket.previous;
        else buckets[bucket.next].previous = bucket.previous;
        delete buckets[at];
    }

    function _processed(uint256 at) private view returns (bool) {
        return at <= block.timestamp && (firstActivation == 0 || at < firstActivation);
    }

    function _earned(Account storage state) private view returns (uint256 earned) {
        earned = state.earnedScaled + state.weight * (rewardIndex - state.lastIndex);
        for (uint256 i; i < state.pending.length && _processed(state.pending[i].activation); ++i) {
            Tranche storage tranche = state.pending[i];
            earned += tranche.principal * (rewardIndex - activationIndex[tranche.activation]);
        }
    }

    function _settle(Account storage state) private {
        state.earnedScaled = _earned(state);
        state.lastIndex = rewardIndex;
        uint256 count = state.pending.length;
        uint256 settled;
        while (settled < count && _processed(state.pending[settled].activation)) {
            Tranche storage tranche = state.pending[settled++];
            state.weight += tranche.principal;
            _releaseCheckpoint(tranche.activation);
        }
        if (settled == 0) return;
        for (uint256 i = settled; i < count; ++i) state.pending[i - settled] = state.pending[i];
        while (state.pending.length > count - settled) state.pending.pop();
    }

    function _releaseCheckpoint(uint256 at) private {
        if (--checkpointUsers[at] == 0) delete activationIndex[at];
    }

    function _quarantineCarry() private {
        reservedDust += carry;
        carry = 0;
    }
}

