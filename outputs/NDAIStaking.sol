// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract NDAIStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable ndai;
    uint256 public totalYieldMinted;
    uint256 public constant YIELD_CAP_BPS = 1000; // 10%
    uint256 public dailyYieldPerToken = 2e15;    // adjust rate as needed

    struct Stake {
        uint256 principal;
        uint256 startDay;
        uint256 endDay;
        uint256 extracted;
        bool active;
    }

    mapping(address => Stake[]) public stakes;
    uint256 public currentDay;

    event StakeCreated(address indexed user, uint256 stakeId, uint256 amount, uint256 endDay);
    event YieldExtracted(address indexed user, uint256 stakeId, uint256 newAmount);
    event StakeEnded(address indexed user, uint256 stakeId, uint256 payout);

    constructor(address _ndai) {
        ndai = IERC20(_ndai);
    }

    function advanceDay() external {
        currentDay++;
    }

    function createStake(uint256 amount, uint256 lengthInDays) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(lengthInDays >= 1, "Invalid length");

        ndai.safeTransferFrom(msg.sender, address(this), amount);

        stakes[msg.sender].push(Stake({
            principal: amount,
            startDay: currentDay,
            endDay: currentDay + lengthInDays,
            extracted: 0,
            active: true
        }));

        emit StakeCreated(msg.sender, stakes[msg.sender].length - 1, amount, currentDay + lengthInDays);
    }

    function extractNEW(uint256 stakeId, address newToken) external nonReentrant {
        Stake storage stake = stakes[msg.sender][stakeId];
        require(stake.active, "Inactive");

        uint256 daysElapsed = currentDay - stake.startDay;
        uint256 accrued = (stake.principal * dailyYieldPerToken * daysElapsed) / 1e18;
        uint256 available = accrued > stake.extracted ? accrued - stake.extracted : 0;
        require(available > 0, "Nothing to extract");

        uint256 cap = (ndai.totalSupply() * YIELD_CAP_BPS) / 10000;
        require(totalYieldMinted + available <= cap, "Yield cap reached");

        stake.extracted += available;
        totalYieldMinted += available;

        NEW(newToken).mint(msg.sender, available);

        emit YieldExtracted(msg.sender, stakeId, available);
    }

    function endStake(uint256 stakeId) external nonReentrant {
        Stake storage stake = stakes[msg.sender][stakeId];
        require(stake.active, "Inactive");
        require(currentDay >= stake.endDay, "Not matured");

        uint256 daysElapsed = stake.endDay - stake.startDay;
        uint256 totalYield = (stake.principal * dailyYieldPerToken * daysElapsed) / 1e18;
        uint256 payout = stake.principal + totalYield - stake.extracted;

        stake.active = false;
        ndai.safeTransfer(msg.sender, payout);

        emit StakeEnded(msg.sender, stakeId, payout);
    }
}

contract NEW is ERC20 {
    address public immutable stakingContract;
    uint256 public immutable maturityDay;

    constructor(address _staking, uint256 _maturityDay, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        stakingContract = _staking;
        maturityDay = _maturityDay;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == stakingContract, "Only staking");
        _mint(to, amount);
    }

    function redeem(uint256 amount) external {
        require(NDAIStaking(stakingContract).currentDay() >= maturityDay, "Not matured");
        _burn(msg.sender, amount);
        IERC20(NDAIStaking(stakingContract).ndai()).transfer(msg.sender, amount);
    }
}
