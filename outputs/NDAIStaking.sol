// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface INDAI {
    function mintYield(address to, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

/// @title NDAIStaking
/// @notice Stake NDAI and extract accrued yield as NEW tokens without ending the stake.
/// @notice NEW tokens are redeemable 1:1 for NDAI on or after the stake's end day.
/// @notice Total yield minted is hard-capped at 10% of NDAI total supply.
contract NDAIStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable ndai;
    uint256 public immutable launchTime;
    uint256 public totalYieldMinted;
    uint256 public constant YIELD_CAP_BPS = 1000; // 10%
    uint256 public immutable dailyYieldPerToken;

    struct StakeInstance {
        uint256 principal;
        uint256 startDay;
        uint256 endDay;
        uint256 extracted;
        bool active;
    }

    mapping(address => StakeInstance[]) public stakeInstances;

    event StakeCreated(address indexed user, uint256 stakeId, uint256 amount, uint256 endDay);
    event YieldExtracted(address indexed user, uint256 stakeId, uint256 newAmount);
    event StakeEnded(address indexed user, uint256 stakeId, uint256 payout);

    constructor(address _ndai, uint256 _dailyYieldPerToken, uint256 _launchTime) {
        ndai = IERC20(_ndai);
        dailyYieldPerToken = _dailyYieldPerToken;
        launchTime = _launchTime;
    }

    function currentDay() public view returns (uint256) {
        if (block.timestamp < launchTime) return 0;
        return (block.timestamp - launchTime) / 1 days;
    }

    function createStake(uint256 amount, uint256 lengthInDays) external nonReentrant {
        require(amount > 0 && lengthInDays >= 1, "Invalid");
        ndai.safeTransferFrom(msg.sender, address(this), amount);

        uint256 start = currentDay();
        stakeInstances[msg.sender].push(StakeInstance({
            principal: amount,
            startDay: start,
            endDay: start + lengthInDays,
            extracted: 0,
            active: true
        }));

        emit StakeCreated(msg.sender, stakeInstances[msg.sender].length - 1, amount, start + lengthInDays);
    }

    /// @notice Extract accrued yield as NEW without ending the stake.
    /// @param newToken Must be a NEW contract whose maturityDay equals this stake's endDay.
    function extractNEW(uint256 stakeId, address newToken) external nonReentrant {
        StakeInstance storage s = stakeInstances[msg.sender][stakeId];
        require(s.active, "Inactive");
        require(NEW(newToken).staking() == address(this), "Invalid NEW");
        require(NEW(newToken).maturityDay() == s.endDay, "Maturity mismatch");

        uint256 dayNow = currentDay();
        uint256 effectiveDay = dayNow > s.endDay ? s.endDay : dayNow;
        uint256 daysElapsed = effectiveDay > s.startDay ? effectiveDay - s.startDay : 0;

        uint256 accrued = (s.principal * dailyYieldPerToken * daysElapsed) / 1e18;
        uint256 available = accrued > s.extracted ? accrued - s.extracted : 0;
        require(available > 0, "Nothing");

        uint256 cap = (INDAI(address(ndai)).totalSupply() * YIELD_CAP_BPS) / 10000;
        require(totalYieldMinted + available <= cap, "Cap reached");

        s.extracted += available;
        totalYieldMinted += available;

        INDAI(address(ndai)).mintYield(address(this), available);
        NEW(newToken).mint(msg.sender, available);

        emit YieldExtracted(msg.sender, stakeId, available);
    }

    function endStake(uint256 stakeId) external nonReentrant {
        StakeInstance storage s = stakeInstances[msg.sender][stakeId];
        require(s.active, "Inactive");
        require(currentDay() >= s.endDay, "Not matured");

        uint256 daysElapsed = s.endDay - s.startDay;
        uint256 totalYield = (s.principal * dailyYieldPerToken * daysElapsed) / 1e18;
        uint256 remainingYield = totalYield > s.extracted ? totalYield - s.extracted : 0;

        uint256 mintedNow = 0;
        if (remainingYield > 0) {
            uint256 cap = (INDAI(address(ndai)).totalSupply() * YIELD_CAP_BPS) / 10000;
            if (totalYieldMinted + remainingYield <= cap) {
                INDAI(address(ndai)).mintYield(address(this), remainingYield);
                totalYieldMinted += remainingYield;
                mintedNow = remainingYield;
            }
        }

        // Pay only principal + newly minted yield for this stake.
        // Previously extracted yield is already represented by NEW tokens.
        uint256 payout = s.principal + mintedNow;

        s.active = false;
        ndai.safeTransfer(msg.sender, payout);

        emit StakeEnded(msg.sender, stakeId, payout);
    }
}

contract NEW is ERC20 {
    address public immutable staking;
    uint256 public immutable maturityDay;

    constructor(address _staking, uint256 _maturityDay, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        staking = _staking;
        maturityDay = _maturityDay;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == staking, "Only staking");
        _mint(to, amount);
    }

    /// @notice Redeem NEW 1:1 for NDAI on or after maturityDay.
    function redeem(uint256 amount) external {
        require(NDAIStaking(staking).currentDay() >= maturityDay, "Early");
        _burn(msg.sender, amount);
        IERC20(NDAIStaking(staking).ndai()).transfer(msg.sender, amount);
    }
}
