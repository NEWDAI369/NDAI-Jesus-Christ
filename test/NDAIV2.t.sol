// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NDAI, IPulseXRouter, IPulseXFactory} from "../outputs/NDAI.sol";
import {NDAIStaking, NDAITimeClaim} from "../outputs/NDAIStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function deal(address account, uint256 balance) external;
    function snapshotState() external returns (uint256);
    function revertToState(uint256 snapshot) external returns (bool);
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata data) external;
    function expectRevert() external;
    function prank(address sender) external;
    function warp(uint256 timestamp) external;
}

interface IFundingRouter is IPulseXRouter {
    function swapETHForExactTokens(uint256 amount, address[] calldata path, address to, uint256 deadline)
        external payable returns (uint256[] memory);
}

contract NDAIV2Test {
    error MintRange();
    error ReserveFraction();
    uint256 private constant LAUNCH_TIME = 1798185600;
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant ROUTER = 0x98bf93ebf5c380C0e6Ae8e192A7e2AE08edAcc02;
    uint32 private constant DAY = 90;
    bytes32 private constant MINTED_EVENT =
        keccak256("Minted(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
    address private constant NFT_HOLDER = address(0x101);
    address private constant CLAIM_HOLDER = address(0x102);

    NDAI private ndai;
    IERC20 private pdai;
    IERC20 private lp;

    function setUp() public {
        vm.warp(LAUNCH_TIME);
        initializeForkBenchmark();
    }

    function initializeForkBenchmark() public {
        require(address(ndai) == address(0));
        ndai = new NDAI(IPulseXRouter(ROUTER), LAUNCH_TIME);
        pdai = IERC20(ndai.PDAI());
        lp = IERC20(IPulseXFactory(ndai.PULSEX_FACTORY()).getPair(ndai.PDAI(), ndai.PLSX()));
    }

    function prepareGuardedMintBenchmark() external {
        _fund(2_500 ether, false);
    }

    function benchmarkGuardedMint(uint256 amount) external {
        ndai.mintWithPdai(_params(amount));
        require(ndai.reserveDaiBalance() == amount && ndai.totalSupply() == amount);
    }
    function testGuardedMintEndpoints() public {
        _fund();
        uint256 snapshot = vm.snapshotState();
        ndai.mintWithPdai(_params(1 ether));
        require(ndai.reserveDaiBalance() == 1 ether);
        require(vm.revertToState(snapshot));
        ndai.mintWithPdai(_params(100 ether));
        require(ndai.reserveDaiBalance() == 100 ether);
        require(lp.balanceOf(ndai.liquidityRecipient()) != 0);
    }

    function testGuardedMintRejectsOutsideRange() public {
        NDAI.MintParams memory params;
        params.ndaiOut = 1 ether - 1;
        vm.expectRevert(NDAI.InvalidMint.selector);
        ndai.mintWithPdai(params);
        params.ndaiOut = 100 ether + 1;
        vm.expectRevert(NDAI.InvalidMint.selector);
        ndai.mintWithPdai(params);
    }

    function testGuardedMintRevertsOnReserveFraction() public {
        _fund(8_000 ether, true);
        // Reduce the terminal DAI reserve to increase the upstream swap amounts.
        address[] memory path = new address[](2);
        path[0] = ndai.WPLS();
        path[1] = ndai.DAI();
        uint256 cost = IPulseXRouter(ROUTER).getAmountsIn(90_000 ether, path)[0];
        vm.deal(address(this), cost);
        IFundingRouter(ROUTER).swapETHForExactTokens{value: cost}(
            90_000 ether, path, address(this), block.timestamp + 1 hours
        );
        require(pdai.approve(address(ndai), type(uint256).max));
        uint256 balance = pdai.balanceOf(address(this));
        NDAI.MintParams memory params = _params(100 ether);
        vm.expectRevert(NDAI.ReserveFraction.selector);
        ndai.mintWithPdai(params);
        require(ndai.totalSupply() == 0 && ndai.reserveDaiBalance() == 0);
        require(lp.balanceOf(ndai.liquidityRecipient()) == 0 && pdai.balanceOf(address(this)) == balance);
    }

    function testMintFundedPositionAndFeeVaultLifecycle() public {
        _fund();
        ndai.mintWithPdai(_params(100 ether));
        NDAIStaking staking = new NDAIStaking(ndai, LAUNCH_TIME);
        ndai.approve(address(staking), 90 ether);
        uint256 id = staking.stake(90 ether, DAY);
        ndai.approve(address(staking.feeVault()), 10 ether);
        staking.feeVault().deposit(10 ether);
        vm.warp(LAUNCH_TIME + 1 days);
        staking.extract(id, 50 ether, 49.5 ether);
        require(staking.feeVault().claimFees() == 0.5 ether);
        staking.retire(id, 0.5 ether);
        staking.feeVault().withdraw(10 ether);
        require(ndai.totalSupply() < 100 ether && ndai.cumulativeMinted() == 100 ether);
        vm.warp(staking.redemptionTime());
        staking.redeem(DAY, 49.5 ether);
        staking.withdraw(id);
        require(ndai.balanceOf(address(this)) == ndai.totalSupply());
        require(ndai.cumulativeDaiFunded() == 100 ether && ndai.reserveDaiBalance() == 100 ether);
        require(lp.balanceOf(ndai.liquidityRecipient()) > 0);
    }
    function testMintAndStakeOpenAtLaunch() public {
        NDAIStaking staking = new NDAIStaking(IERC20(address(ndai)), LAUNCH_TIME);
        _fund();
        NDAI.MintParams memory params = _params(100 ether);
        vm.warp(LAUNCH_TIME - 1);
        vm.expectRevert(NDAI.LaunchPending.selector);
        ndai.mintWithPdai(params);
        vm.expectRevert(NDAIStaking.LaunchPending.selector);
        staking.stake(100 ether, DAY);

        vm.warp(LAUNCH_TIME);
        ndai.mintWithPdai(params);
        require(ndai.approve(address(staking), 100 ether), "stake approval failed");
        staking.stake(100 ether, DAY);
        require(ndai.balanceOf(address(staking.positionCustody())) == 100 ether, "stake did not open");
    }

    function testMint100DepositsDaiAndLp() public {
        _fund();
        NDAI.MintParams memory params = _params(100 ether);
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        ndai.mintWithPdai(params);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(vm.revertToState(snapshot), "could not reset quote simulation");

        params = _applyLiquidityLimits(params, logs);
        ndai.mintWithPdai(params);
        require(ndai.balanceOf(address(this)) == 100 ether, "wrong NDAI balance");
        require(ndai.totalSupply() == 100 ether, "wrong NDAI supply");
        require(ndai.reserveDaiBalance() == 100 ether, "wrong reserve");
        require(lp.balanceOf(ndai.liquidityRecipient()) > 0, "LP lock empty");
    }

    function _applyLiquidityLimits(NDAI.MintParams memory params, Vm.Log[] memory logs)
        private view returns (NDAI.MintParams memory)
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(ndai) || entry.topics[0] != MINTED_EVENT) continue;
            (,,, uint256 pdaiAdded, uint256 plsxAdded, uint256 lpMinted,, uint256 plsxRefund) =
                abi.decode(entry.data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            // Rehearse with 1% tolerance around the simulated liquidity outputs.
            params.minPlsxOut = (plsxAdded + plsxRefund) * 99 / 100;
            params.minPdaiAdded = pdaiAdded * 99 / 100;
            params.minPlsxAdded = plsxAdded * 99 / 100;
            params.minLpOut = lpMinted * 99 / 100;
            return params;
        }
        revert("mint event missing");
    }

    function testSpendingCapRejectsMint() public {
        NDAI.MintParams memory params = _params(100 ether);
        params.maxPdaiIn = 0;
        vm.expectRevert(NDAI.PaymentLimitExceeded.selector);
        ndai.mintWithPdai(params);
    }

    function testImpossibleLpMinimumRollsBackMint() public {
        _fund();
        ndai.mintWithPdai(_params(100 ether));
        NDAI.MintParams memory params = _params(1 ether);
        params.minLpOut = type(uint256).max;
        _assertMintRollsBack(params, NDAI.InsufficientLiquidityTokens.selector);
    }

    function testImpossiblePdaiDepositRollsBackMint() public {
        _fund();
        NDAI.MintParams memory params = _params(100 ether);
        params.minPdaiAdded = type(uint256).max;
        _assertMintRollsBack(params, bytes4(0));
    }

    function testImpossiblePlsxDepositRollsBackMint() public {
        _fund();
        NDAI.MintParams memory params = _params(100 ether);
        params.minPlsxAdded = type(uint256).max;
        _assertMintRollsBack(params, bytes4(0));
    }

    function _assertMintRollsBack(NDAI.MintParams memory params, bytes4 expectedError) private {
        uint256 reserveBefore = ndai.reserveDaiBalance();
        uint256 lpBefore = lp.balanceOf(ndai.liquidityRecipient());
        uint256 supplyBefore = ndai.totalSupply();
        uint256 paymentBefore = pdai.balanceOf(address(this));

        if (expectedError == bytes4(0)) vm.expectRevert();
        else vm.expectRevert(expectedError);
        ndai.mintWithPdai(params);

        require(ndai.reserveDaiBalance() == reserveBefore, "reserve changed");
        require(lp.balanceOf(ndai.liquidityRecipient()) == lpBefore, "LP lock changed");
        require(ndai.totalSupply() == supplyBefore, "supply changed");
        require(pdai.balanceOf(address(this)) == paymentBefore, "payment changed");
    }

    function testTransferredStakeAndClaimsPayAtMaturityOnlyOnce() public {
        _fund();
        ndai.mintWithPdai(_params(100 ether));
        vm.warp(LAUNCH_TIME + 10 days);
        NDAIStaking staking = new NDAIStaking(IERC20(address(ndai)), LAUNCH_TIME);
        require(staking.maturityTime(DAY) == LAUNCH_TIME + uint256(DAY) * 1 days, "wrong maturity");
        require(ndai.approve(address(staking), 100 ether), "stake approval failed");
        uint256 id = staking.stake(100 ether, DAY);
        staking.extract(id, 60 ether, 60 ether);
        NDAITimeClaim maturityToken = staking.maturityTokens(DAY);
        require(keccak256(bytes(maturityToken.symbol())) == keccak256("NEW"), "wrong symbol");
        staking.transferFrom(address(this), NFT_HOLDER, id);
        require(maturityToken.transfer(CLAIM_HOLDER, 60 ether), "claim transfer failed");

        vm.prank(NFT_HOLDER);
        vm.expectRevert(NDAIStaking.MaturityPending.selector);
        staking.withdraw(id);
        vm.prank(CLAIM_HOLDER);
        vm.expectRevert(NDAIStaking.MaturityPending.selector);
        staking.redeem(DAY, 60 ether);

        vm.warp(staking.maturityTime(DAY));
        vm.prank(NFT_HOLDER);
        staking.withdraw(id);
        vm.prank(CLAIM_HOLDER);
        staking.redeem(DAY, 60 ether);

        require(ndai.balanceOf(NFT_HOLDER) == 40 ether, "wrong NFT payout");
        require(ndai.balanceOf(CLAIM_HOLDER) == 60 ether, "wrong claim payout");
        require(maturityToken.totalSupply() == 0, "claims still outstanding");
        require(ndai.balanceOf(address(staking)) == 0, "stake balance remains");

        vm.prank(CLAIM_HOLDER);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", CLAIM_HOLDER, 0, 60 ether)
        );
        staking.redeem(DAY, 60 ether);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _fund() private {
        _fund(2_500 ether, true);
    }

    function _fund(uint256 amount, bool useCheatcode) private {
        address[] memory path = new address[](3);
        path[0] = ndai.WPLS();
        path[1] = ndai.PLSX();
        path[2] = ndai.PDAI();
        uint256 cost = IPulseXRouter(ROUTER).getAmountsIn(amount, path)[0];
        if (useCheatcode) vm.deal(address(this), cost);
        IFundingRouter(ROUTER).swapETHForExactTokens{value: cost}(
            amount, path, address(this), block.timestamp + 1 hours
        );
        require(pdai.approve(address(ndai), amount), "mint approval failed");
    }

    function _params(uint256 amount) private view returns (NDAI.MintParams memory) {
        address[] memory path = new address[](4);
        path[0] = ndai.PDAI();
        path[1] = ndai.PLSX();
        path[2] = ndai.WPLS();
        path[3] = ndai.DAI();
        uint256 cost = IPulseXRouter(ROUTER).getAmountsIn(amount, path)[0];
        return NDAI.MintParams(amount, cost + cost / 5, 1, 1, 1, 1, block.timestamp + 5 minutes);
    }
}











