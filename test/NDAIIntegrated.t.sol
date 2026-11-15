// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NDAIStaking, NDAITimeClaim} from "../outputs/NDAIStaking.sol";
import {NDAIFeeVault} from "../outputs/NDAIFeeVault.sol";
import {NDAICustody} from "../outputs/NDAICustody.sol";
import {FixtureToken, FlowVm} from "./NDAIActivationFlow.t.sol";

contract NDAIIntegratedTest {
    FlowVm private constant vm = FlowVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant START = 1798185600;
    uint32 private constant DAY = 90;
    address private constant BUYER = address(0x101);

    FixtureToken private ndai;
    NDAIStaking private series;
    NDAIFeeVault private vault;
    NDAITimeClaim private claims;

    function setUp() public {
        vm.chainId(369);
        vm.warp(START);
        ndai = new FixtureToken();
        series = new NDAIStaking(ndai, START);
        vault = series.feeVault();
        claims = series.claimToken();
        ndai.approve(address(series), type(uint256).max);
        ndai.approve(address(vault), type(uint256).max);
    }

    function testLaunchTickerAndFutureNumberedTicker() public {
        require(keccak256(bytes(claims.symbol())) == keccak256("NEW"));
        require(series.REDEMPTION_DAY() == 3300 && series.MATURITY_DAY() == 90);
        require(series.redemptionTime() == START + 90 days);
        NDAITimeClaim futureClaim = new NDAITimeClaim(START + 190 days, 3400);
        require(keccak256(bytes(futureClaim.symbol())) == keccak256("NEW-3400"));
        require(address(futureClaim) != address(claims));
    }
    function testMatchingVaultWaiverAndSeparateCustody() public {
        ndai.mint(address(this), 401 ether);
        uint256 id = series.stake(400 ether, DAY);
        series.extract(id, 100 ether, 100 ether);
        vault.deposit(1 ether);
        vm.warp(START + 1 days - 1);
        series.extract(id, 100 ether, 100 ether);
        require(vault.feesReceived() == 0 && claims.balanceOf(address(this)) == 200 ether);
        vm.warp(START + 1 days);
        vm.expectRevert(NDAIStaking.InvalidAmount.selector);
        series.extract(id, 100 ether, 100 ether);
        series.extract(id, 100 ether, 99 ether);
        require(vault.feesReceived() == 1 ether && claims.balanceOf(address(vault.feeEscrow())) == 1 ether);
        require(ndai.balanceOf(address(vault)) == 1 ether);
        require(ndai.balanceOf(address(series.positionCustody())) == 100 ether);
        vault.withdraw(1 ether);
        require(vault.eligiblePrincipal() == 0 && vault.totalPrincipal() == 0);
        series.extract(id, 100 ether, 100 ether);
        require(vault.feesReceived() == 1 ether && claims.balanceOf(address(this)) == 399 ether);
        require(vault.claimFees() == 1 ether && vault.claimFees() == 0);
        series.retire(id, 1 ether);
        require(ndai.balanceOf(address(series.positionCustody())) == 1 ether);
        require(claims.totalSupply() == 399 ether);
        require(ndai.balanceOf(address(series.claimCustody())) == 399 ether);
        require(series.userBacking() == 398 ether && series.feeBacking() == 1 ether);
        vm.warp(series.redemptionTime());
        series.withdraw(id);
        series.redeem(DAY, 399 ether);
        require(claims.totalSupply() == 0 && ndai.balanceOf(address(series.claimCustody())) == 0);
        require(series.userBacking() == 0 && series.feeBacking() == 0);
        require(keccak256(bytes(claims.symbol())) == keccak256("NEW"));
        require(series.dayZero() + uint256(series.REDEMPTION_DAY()) * 1 days == series.redemptionTime());
    }

    function testBuyerBoundsAndCustodyAuthorization() public {
        ndai.mint(address(this), 10 ether);
        uint256 id = series.stake(10 ether, DAY);
        series.extract(id, 4 ether, 4 ether);
        series.approve(BUYER, id);
        NDAICustody claimCustody = series.claimCustody();
        NDAICustody positionCustody = series.positionCustody();
        NDAICustody feeEscrow = vault.feeEscrow();
        vm.expectRevert(NDAICustody.OnlyController.selector);
        claimCustody.pay(BUYER, 1);
        vm.expectRevert(NDAICustody.OnlyController.selector);
        positionCustody.pay(BUYER, 1);
        vm.expectRevert(NDAICustody.OnlyController.selector);
        feeEscrow.pay(BUYER, 1);
        vm.expectRevert(NDAIFeeVault.OnlySeries.selector);
        vault.prepareIssuance();
        vm.expectRevert(NDAIFeeVault.OnlySeries.selector);
        vault.recordFee(1, 0);
        vm.expectRevert(NDAITimeClaim.OnlySeries.selector);
        claims.mint(BUYER, 1);
        vm.expectRevert(NDAITimeClaim.OnlySeries.selector);
        claims.burn(address(this), 1);

        vm.prank(BUYER);
        vm.expectRevert(NDAIStaking.OnlyStakeOwner.selector);
        series.extract(id, 1 ether, 0);
        vm.prank(BUYER);
        vm.expectRevert(NDAIStaking.BuyerBounds.selector);
        series.acceptPosition(address(this), id, 3 ether, 6 ether, START);
        vm.prank(BUYER);
        series.acceptPosition(address(this), id, 4 ether, 6 ether, START);
        require(series.ownerOf(id) == BUYER);

        vm.warp(series.issuanceCutoff());
        vm.prank(BUYER);
        vm.expectRevert(NDAIStaking.IssuanceClosed.selector);
        series.extract(id, 1 ether, 0);
        claims.transfer(BUYER, 1 ether);
        vm.prank(BUYER);
        series.retire(id, 1 ether);
        vm.warp(series.redemptionTime());
        vm.expectRevert(NDAIStaking.OnlyStakeOwner.selector);
        series.withdraw(id);
        vm.prank(BUYER);
        series.withdraw(id);
        require(ndai.balanceOf(BUYER) == 7 ether);
    }

    function testBacklogBlocksIssuanceAndAllowsWithdrawal() public {
        ndai.mint(address(this), 102 ether);
        uint256 id = series.stake(100 ether, DAY);
        vault.deposit(1 ether);
        for (uint256 i = 1; i < 34; ++i) {
            vm.warp(START + i);
            address depositor = address(uint160(5000 + i));
            ndai.mint(depositor, 1 ether);
            vm.prank(depositor);
            ndai.approve(address(vault), 1 ether);
            vm.prank(depositor);
            vault.deposit(1 ether);
        }
        vm.warp(START + 1 days + 33);
        require(vault.dueKeyCount() == 33);
        vm.expectRevert(NDAIFeeVault.CatchUpRequired.selector);
        series.extract(id, 100 ether, 99 ether);
        require(vault.processedKeys() == 0 && claims.totalSupply() == 0);
        vault.withdraw(1 ether);
        require(vault.checkpointUsers(START + 1 days) == 0);
        require(vault.processedKeys() == 0 && vault.dueKeyCount() == 33);
        require(vault.sync() == 32);
        series.extract(id, 100 ether, 99 ether);
        require(vault.eligiblePrincipal() == 33 ether && vault.feesReceived() == 1 ether);
    }

    function testCheckpointPersistsUntilAllTranchesSettle() public {
        ndai.mint(address(this), 202 ether);
        ndai.mint(BUYER, 1 ether);
        uint256 id = series.stake(200 ether, DAY);
        vault.deposit(1 ether);
        vm.warp(START + 1);
        vm.prank(BUYER);
        ndai.approve(address(vault), 1 ether);
        vm.prank(BUYER);
        vault.deposit(1 ether);
        vault.deposit(1 ether);
        vm.warp(START + 1 days);
        series.extract(id, 100 ether, 99 ether);
        vm.warp(START + 1 days + 1);
        series.extract(id, 100 ether, 99 ether);
        uint256 at = START + 1 days + 1;
        require(vault.checkpointUsers(at) == 2 && vault.activationIndex(at) == 1e27);
        vm.prank(BUYER);
        require(vault.claimFees() == 333333333333333333);
        require(vault.checkpointUsers(at) == 1 && vault.activationIndex(at) == 1e27);
        require(vault.claimFees() == 1666666666666666666);
        require(vault.checkpointUsers(at) == 0 && vault.activationIndex(at) == 0);
        require(vault.feesPaid() < vault.feesReceived());
    }

    function testApprovedVaultCapAndCeilingPreserveExits() public {
        uint256 cap = vault.PRINCIPAL_CAP();
        uint256 gross = 100 * vault.FEE_CAP();
        ndai.mint(address(this), gross + cap + 101);
        uint256 id = series.stake(gross + 100, DAY);
        vault.deposit(cap);
        vm.expectRevert(NDAIFeeVault.Capacity.selector);
        vault.deposit(1 ether);
        vm.warp(START + 1 days);
        // A sub-token remainder is allowed and gives the worst-case index denominator.
        vault.withdraw(cap - 1);
        series.extract(id, gross, 0);
        require(vault.eligiblePrincipal() == 1 && vault.rewardIndex() == vault.INDEX_CAP());
        require(vault.feesReceived() == vault.FEE_CAP());
        vm.expectRevert(NDAIFeeVault.AccountingCeiling.selector);
        series.extract(id, 100, 0);
        require(claims.totalSupply() == gross && ndai.balanceOf(address(series.claimCustody())) == gross);
        require(vault.claimFees() == vault.FEE_CAP());
        vault.withdraw(1);
        series.extract(id, 100, 100);
        series.retire(id, 1);
        vm.warp(series.redemptionTime());
        series.withdraw(id);
        series.redeem(DAY, gross + 99);
        require(claims.totalSupply() == 0 && series.userBacking() + series.feeBacking() == 0);
    }
    function testFuzzSeriesCollateralConservation(uint96 rawGross, uint96 rawRetire, bool redeemFirst) public {
        uint256 gross = 101 + uint256(rawGross);
        uint256 position = gross + 1 ether;
        ndai.mint(address(this), position + 1 ether);
        uint256 id = series.stake(position, DAY);
        vault.deposit(1 ether);
        vm.warp(START + 1 days);
        series.extract(id, gross, 1);
        uint256 fee = (gross + 99) / 100;
        require(vault.claimFees() == fee);
        uint256 retired = uint256(rawRetire) % (gross + 1);
        if (retired != 0) series.retire(id, retired);
        uint256 remaining = gross - retired;
        require(claims.totalSupply() == remaining);
        require(ndai.balanceOf(address(series.claimCustody())) == remaining);
        require(series.userBacking() + series.feeBacking() == remaining);
        require(ndai.balanceOf(address(series.positionCustody())) == position - remaining);
        vm.warp(series.redemptionTime());
        if (redeemFirst && remaining != 0) series.redeem(DAY, remaining);
        series.withdraw(id);
        if (!redeemFirst && remaining != 0) series.redeem(DAY, remaining);
        require(ndai.balanceOf(address(this)) == position);
        require(ndai.balanceOf(address(vault)) == 1 ether);
        require(claims.totalSupply() == 0 && ndai.balanceOf(address(series.claimCustody())) == 0);
    }

    function testFuzzFeesAcrossCohortChanges(uint64 first, uint64 second, uint64 third) public {
        uint256 grossA = uint256(first) + 101;
        uint256 grossB = uint256(second) + 101;
        uint256 grossC = uint256(third) + 101;
        uint256 position = grossA + grossB + grossC + 1 ether;
        ndai.mint(address(this), position + 1 ether);
        uint256 id = series.stake(position, DAY);
        vault.deposit(1 ether);
        _otherDeposit(BUYER, 2 ether);

        address late = address(0x102);
        vm.warp(START + 1 days);
        _otherDeposit(late, 3 ether);
        series.extract(id, grossA, 1);
        series.extract(id, grossB, 1);
        uint256 feeAB = (grossA + 99) / 100 + (grossB + 99) / 100;
        uint256 paidA = vault.claimFees();
        require(paidA == feeAB / 3);
        vm.prank(BUYER);
        vault.withdraw(2 ether);
        vm.warp(START + 2 days);
        uint256 carry = (feeAB * 1e27) % (3 ether);
        uint256 feeC = (grossC + 99) / 100;
        series.extract(id, grossC, 1);
        require(vault.reservedDust() == carry);
        uint256 aScaled = (feeAB * 1e27 / (3 ether)) * 1 ether + (feeC * 1e27 / (4 ether)) * 1 ether;
        uint256 paidAAfter = vault.claimFees();
        require(paidA + paidAAfter == aScaled / 1e27);
        vm.prank(BUYER);
        require(vault.claimFees() == (feeAB * 1e27 / (3 ether)) * 2 ether / 1e27);
        vm.prank(late);
        require(vault.claimFees() == (feeC * 1e27 / (4 ether)) * 3 ether / 1e27);
        vm.prank(late);
        require(vault.claimFees() == 0);
        require(vault.feesReceived() == feeAB + feeC);
        require(claims.balanceOf(address(vault.feeEscrow())) + vault.feesPaid() == feeAB + feeC);
        require(claims.totalSupply() == grossA + grossB + grossC);
        require(ndai.balanceOf(address(series.claimCustody())) == claims.totalSupply());
    }

    function _otherDeposit(address account, uint256 amount) private {
        ndai.mint(account, amount);
        vm.prank(account);
        ndai.approve(address(vault), amount);
        vm.prank(account);
        vault.deposit(amount);
    }
    function testSeriesComponentsRejectOtherChains() public {
        vm.chainId(1);
        vm.expectRevert(NDAIStaking.WrongChain.selector);
        new NDAIStaking(ndai, START);
        vm.expectRevert(NDAIFeeVault.WrongChain.selector);
        new NDAIFeeVault(ndai, claims, START, START + 90 days);
        vm.expectRevert(NDAICustody.WrongChain.selector);
        new NDAICustody(ndai);
        vm.expectRevert(NDAITimeClaim.WrongChain.selector);
        new NDAITimeClaim(START + 90 days, 3300);
    }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}







