// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {NDAIStaking, NDAITimeClaim} from "../outputs/NDAIStaking.sol";
import {FixtureToken, FlowVm} from "./NDAIActivationFlow.t.sol";

interface FullRevertVm {
    function expectRevert(bytes calldata) external;
}

contract NDAIAccountingValidationTest {
    function _expectEmptyBalance() private {
        FullRevertVm(address(vm)).expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), uint256(0), uint256(1))
        );
    }
    FlowVm private constant vm = FlowVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SCALE = 1e27;
    uint32 private constant DAY = 90;
    address private constant BUYER = address(0x101);

    function testRetirementAndRedemptionBeforeNftWithdrawal() public {
        _checkPayoutOrder(true);
    }

    function testRetirementAndRedemptionAfterNftWithdrawal() public {
        _checkPayoutOrder(false);
    }

    function _checkPayoutOrder(bool redeemFirst) private {
        vm.chainId(369);
        FixtureToken ndai = new FixtureToken();
        NDAIStaking vault = new NDAIStaking(ndai, 1798185600);
        vm.warp(vault.LAUNCH_TIME());
        ndai.mint(address(this), 110 ether);
        ndai.approve(address(vault), 110 ether);
        uint256 id = vault.stake(100 ether, DAY);
        uint256 otherId = vault.stake(10 ether, DAY);
        vault.extract(id, 60 ether, 60 ether);
        vault.extract(otherId, 10 ether, 10 ether);
        NDAITimeClaim series = vault.maturityTokens(DAY);
        series.transfer(BUYER, 10 ether);
        vault.transferFrom(address(this), BUYER, id);

        vm.expectRevert(NDAIStaking.OnlyStakeOwner.selector);
        vault.retire(id, 1 ether);
        vm.prank(BUYER);
        vm.expectRevert(NDAIStaking.InvalidAmount.selector);
        vault.retire(id, 61 ether);
        vm.prank(BUYER);
        vault.retire(id, 10 ether);
        (, uint256 principal, uint256 debt) = vault.stakes(id);
        (, , uint256 otherDebt) = vault.stakes(otherId);
        require(principal - debt == 50 ether && otherDebt == 10 ether, "wrong position balances");
        require(ndai.balanceOf(BUYER) == 0 && series.totalSupply() == 60 ether, "wrong retirement");

        vm.warp(vault.maturityTime(DAY));
        vm.prank(BUYER);
        vm.expectRevert(NDAIStaking.MaturityReached.selector);
        vault.retire(id, 1 ether);
        if (redeemFirst) vault.redeem(DAY, 50 ether);
        vm.prank(BUYER);
        vault.withdraw(id);
        if (!redeemFirst) vault.redeem(DAY, 50 ether);

        require(ndai.balanceOf(BUYER) == 50 ether && ndai.balanceOf(address(this)) == 50 ether);
        require(series.totalSupply() == 10 ether && ndai.balanceOf(address(vault.claimCustody())) == 10 ether);
        vault.redeem(DAY, 10 ether);
        _expectEmptyBalance();
        vault.redeem(DAY, 1);
    }

    function testWideProductAndRemainderCarry() public pure {
        uint256 high = type(uint256).max;
        (uint256 increment, uint256 remainder) = _nextIndex(high - 1, high - 1, high);
        require(increment == SCALE && remainder == high - 1 - SCALE);
        (increment, remainder) = _nextIndex(1, 0, high);
        require(increment == 0 && remainder == SCALE);
    }

    function testProposedCapAndLifetimeFeeBounds() public pure {
        uint256 weightCap = 100_000_000 ether;
        uint256 feeCap = 1e38;
        require(weightCap < SCALE);
        (uint256 maxIndex,) = _nextIndex(feeCap, 0, 1);
        require(maxIndex == 1e65 && maxIndex < type(uint256).max);
        (uint256 increment, uint256 dust) = _nextIndex(1, weightCap - 1, weightCap);
        require(increment == 10 && dust == weightCap - 1);
    }
    function testLifetimeIndexLimit() public {
        uint256 maxFees = type(uint256).max / SCALE;
        (uint256 index,) = _nextIndex(maxFees, 0, 1);
        require(index == maxFees * SCALE);
        vm.expectRevert(Math.MathOverflowedMulDiv.selector);
        this.nextIndex(maxFees + 1, 0, 1);
    }

    function testFuzzRoundingConservesScaledFees(uint128 fee, uint128 rawWeight, uint128 rawDust) public pure {
        uint256 weight = uint256(rawWeight) + 1;
        uint256 dust = uint256(rawDust) % weight;
        (uint256 increment, uint256 remainder) = _nextIndex(fee, dust, weight);
        require(remainder < weight && increment * weight + remainder == uint256(fee) * SCALE + dust);
    }

    function nextIndex(uint256 fee, uint256 dust, uint256 weight) external pure returns (uint256, uint256) {
        return _nextIndex(fee, dust, weight);
    }

    function _nextIndex(uint256 fee, uint256 dust, uint256 weight)
        private pure returns (uint256 increment, uint256 remainder)
    {
        increment = Math.mulDiv(fee, SCALE, weight);
        remainder = mulmod(fee, SCALE, weight);
        uint256 toCarry = weight - dust;
        if (remainder >= toCarry) return (increment + 1, remainder - toCarry);
        return (increment, remainder + dust);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}


