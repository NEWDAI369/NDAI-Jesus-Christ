// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface INDAI {
    function mintYield(address to, uint256 amount) external;
}

contract NDAIStaking is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable ndai;
    uint256 public totalYieldMinted;
    uint256 public constant YIELD_CAP_BPS = 1000; // 10%
    uint256 public dailyYieldPerToken = 2e15;

    struct StakeInstance {
        uint256 principal;
        uint256 startDay;
        uint256 endDay;
        uint256 extracted;
        bool active;
    }

    mapping(address => StakeInstance[]) public stakeInstances;
    uint256 public currentDay;

    event StakeCreated(address indexed user, uint256 stakeId, uint256 amount, uint256 endDay);
    event YieldExtracted(address indexed user, uint256 stakeId, uint256 newAmount);
    event StakeEnded(address indexed user, uint256 stakeId, uint256 payout);

    constructor(address _ndai) Ownable(msg.sender) {
        ndai = IERC20(_ndai);
    }

    function advanceDay() external {
        currentDay++;
    }

    function setDailyYield(uint256 rate) external onlyOwner {
        dailyYieldPerToken = rate;
    }

    function createStake(uint256 amount, uint256 lengthInDays) external nonReentrant {
        require(amount > 0 && lengthInDays >= 1, "Invalid");
        ndai.safeTransferFrom(msg.sender, address(this), amount);

        stakeInstances[msg.sender].push(StakeInstance({
            principal: amount,
            startDay: currentDay,
            endDay: currentDay + lengthInDays,
            extracted: 0,
            active: true
        }));

        emit StakeCreated(msg.sender, stakeInstances[msg.sender].length - 1, amount, currentDay + lengthInDays);
    }

    function extractNEW(uint256 stakeId, address newToken) external nonReentrant {
        StakeInstance storage s = stakeInstances[msg.sender][stakeId];
        require(s.active, "Inactive");

        uint256 daysElapsed = currentDay - s.startDay;
        uint256 accrued = (s.principal * dailyYieldPerToken * daysElapsed) / 1e18;
        uint256 available = accrued > s.extracted ? accrued - s.extracted : 0;
        require(available > 0, "Nothing");

        uint256 cap = (ndai.totalSupply() * YIELD_CAP_BPS) / 10000;
        require(totalYieldMinted + available <= cap, "Cap reached");

        s.extracted += available;
        totalYieldMinted += available;

        INDAI(address(ndai)).mintYield(address(this), available);
        NEW(newToken).mint(msg.sender, available);

        emit YieldExtracted(msg.sender, stakeId, available);
    }

    function endStake(uint256 stakeId) external nonReentrant {
        StakeInstance storage s = stakeInstances[msg.sender][stakeId];
        require(s.active && currentDay >= s.endDay, "Not ready");

        uint256 daysElapsed = s.endDay - s.startDay;
        uint256 totalYield = (s.principal * dailyYieldPerToken * daysElapsed) / 1e18;
        uint256 payout = s.principal + totalYield - s.extracted;

        s.active = false;

        if (totalYield > s.extracted) {
            uint256 remaining = totalYield - s.extracted;
            uint256 cap = (ndai.totalSupply() * YIELD_CAP_BPS) / 10000;
            if (totalYieldMinted + remaining <= cap) {
                INDAI(address(ndai)).mintYield(address(this), remaining);
                totalYieldMinted += remaining;
            }
        }

        ndai.safeTransfer(msg.sender, payout);
        emit StakeEnded(msg.sender, stakeId, payout);
    }
}

contract NEW is ERC20 {
    address public immutable staking;
    uint256 public immutable maturityDay;

    constructor(address _staking, uint256 _maturityDay, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        staking = _staking;
        maturityDay = _maturityDay;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == staking, "Only staking");
        _mint(to, amount);
    }

    function redeem(uint256 amount) external {
        require(NDAIStaking(staking).currentDay() >= maturityDay, "Early");
        _burn(msg.sender, amount);
        IERC20(NDAIStaking(staking).ndai()).transferFrom(staking, msg.sender, amount);
    }
}
