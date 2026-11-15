// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NDAI, IPulseXRouter, IPulseXPair} from "../outputs/NDAI.sol";
import {NDAIStaking, NDAITimeClaim} from "../outputs/NDAIStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm, IFundingRouter} from "./NDAIV2.t.sol";

interface PoolFactory {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
}

interface PoolPair is IPulseXPair {
    function token1() external view returns (address);
}

contract NDAIPoolForkTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant START = 1798185600;
    address private constant ROUTER = 0x98bf93ebf5c380C0e6Ae8e192A7e2AE08edAcc02;

    function testUserInitializesAndAddsLiquidityToNewNdaiPair() public {
        vm.warp(START);
        NDAI ndai = new NDAI(IPulseXRouter(ROUTER), START);
        IPulseXRouter router = ndai.router();
        address[] memory funding = new address[](3);
        funding[0] = ndai.WPLS();
        funding[1] = ndai.PLSX();
        funding[2] = ndai.PDAI();
        uint256 fundCost = router.getAmountsIn(2500 ether, funding)[0];
        vm.deal(address(this), fundCost);
        IFundingRouter(ROUTER).swapETHForExactTokens{value: fundCost}(
            2500 ether, funding, address(this), START + 5 minutes
        );
        address[] memory path = new address[](4);
        path[0] = ndai.PDAI();
        path[1] = ndai.PLSX();
        path[2] = ndai.WPLS();
        path[3] = ndai.DAI();
        uint256 cost = router.getAmountsIn(100 ether, path)[0];
        IERC20(ndai.PDAI()).approve(address(ndai), cost + cost / 5);
        ndai.mintWithPdai(NDAI.MintParams(100 ether, cost + cost / 5, 1, 1, 1, 1, START + 5 minutes));

        NDAIStaking staking = new NDAIStaking(ndai, START);
        ndai.approve(address(staking), 50 ether);
        uint256 id = staking.stake(50 ether, 90);
        staking.extract(id, 40 ether, 40 ether);
        NDAITimeClaim claim = staking.claimToken();
        require(keccak256(bytes(claim.symbol())) == keccak256("NEW"));
        PoolFactory factory = PoolFactory(router.factory());
        require(factory.getPair(address(ndai), address(claim)) == address(0));

        address pair = factory.createPair(address(ndai), address(claim));
        require(pair == factory.getPair(address(claim), address(ndai)));
        (uint112 reserve0, uint112 reserve1,) = IPulseXPair(pair).getReserves();
        require(reserve0 == 0 && reserve1 == 0);
        address token0 = IPulseXPair(pair).token0();
        address token1 = PoolPair(pair).token1();
        require(
            (token0 == address(ndai) && token1 == address(claim)) ||
            (token0 == address(claim) && token1 == address(ndai))
        );

        ndai.approve(ROUTER, 20 ether);
        claim.approve(ROUTER, 10 ether);
        (uint256 spentNdai, uint256 spentClaim, uint256 lp) = router.addLiquidity(
            address(ndai), address(claim), 20 ether, 10 ether, 20 ether, 10 ether,
            address(this), START + 5 minutes
        );
        require(spentNdai == 20 ether && spentClaim == 10 ether && lp > 0);
        require(IERC20(pair).balanceOf(address(this)) == lp);
        (reserve0, reserve1,) = IPulseXPair(pair).getReserves();
        if (token0 == address(ndai)) require(reserve0 == 20 ether && reserve1 == 10 ether);
        else require(reserve0 == 10 ether && reserve1 == 20 ether);
        require(ndai.balanceOf(address(this)) == 30 ether && claim.balanceOf(address(this)) == 30 ether);
        ndai.approve(ROUTER, 4 ether);
        claim.approve(ROUTER, 3 ether);
        vm.expectRevert();
        router.addLiquidity(
            address(ndai), address(claim), 4 ether, 3 ether, 4 ether, 3 ether,
            address(this), START + 5 minutes
        );
        (uint112 after0, uint112 after1,) = IPulseXPair(pair).getReserves();
        require(after0 == reserve0 && after1 == reserve1);
        require(IERC20(pair).balanceOf(address(this)) == lp);
        require(ndai.balanceOf(address(this)) == 30 ether && claim.balanceOf(address(this)) == 30 ether);
        require(ndai.reserveDaiBalance() == 100 ether);
        require(ndai.balanceOf(address(staking.claimCustody())) == 40 ether);
        require(staking.feeVault().totalPrincipal() == 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}


