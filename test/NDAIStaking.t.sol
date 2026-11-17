// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/NDAIStaking.sol";

contract MockNDAI is ERC20 {
    constructor() ERC20("Mock NDAI", "NDAI") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function mintYield(address to, uint256 amount) external { _mint(to, amount); }
}

contract NDAIStakingTest is Test {
    NDAIStaking staking;
    MockNDAI ndai;
    address user = address(0x1);

    function setUp() public {
        ndai = new MockNDAI();
        staking = new NDAIStaking(address(ndai), block.timestamp);
        ndai.mint(user, 10_000 ether);
        vm.prank(user);
        ndai.approve(address(staking), type(uint256).max);
    }

    function testCreateStake() public {
        vm.prank(user);
        staking.createStake(100 ether, 365);
        (uint256 principal,,,,) = staking.stakeInstances(user, 0);
        assertEq(principal, 100 ether);
    }

    function testMultiplier() public view {
        assertEq(staking.getMultiplier(1), 1e18);
        assertEq(staking.getMultiplier(365), 1.2e18);
        assertEq(staking.getMultiplier(3641), 3e18);
    }

    function testExtractAndEnd() public {
        vm.startPrank(user);
        staking.createStake(1000 ether, 100);
        vm.warp(block.timestamp + 50 days);
        uint256 endDay = staking.currentDay() + 50;
        NEW newToken = new NEW(address(staking), endDay, "NEW", "NEW");
        staking.extractNEW(0, address(newToken));
        vm.warp(block.timestamp + 50 days + 1);
        staking.endStake(0);
        vm.stopPrank();
    }

    function testCannotExtractBeforeAnyYield() public {
        vm.prank(user);
        staking.createStake(100 ether, 30);
        NEW newToken = new NEW(address(staking), staking.currentDay() + 30, "NEW", "NEW");
        vm.prank(user);
        vm.expectRevert("Nothing");
        staking.extractNEW(0, address(newToken));
    }
}
