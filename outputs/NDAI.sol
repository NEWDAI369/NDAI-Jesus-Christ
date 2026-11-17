// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPulseXRouter {
    function factory() external view returns (address);
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256);
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapTokensForExactTokens(uint256 amountOut, uint256 amountInMax, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts);
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts);
    function addLiquidity(address tokenA, address tokenB, uint256 desiredA, uint256 desiredB, uint256 minA, uint256 minB, address to, uint256 deadline) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

interface IPulseXFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

contract PermanentTokenLock {
    constructor() {
        if (block.chainid != 369) revert();
    }
}

interface IPulseXPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

contract NDAI is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 public immutable LAUNCH_TIME;
    uint256 public cumulativeDaiFunded;
    uint256 public cumulativeMinted;

    address public constant PDAI = address(bytes20(hex"75c84ca7ec3f14e4f53acabf6edd628cd1b22bc1"));
    address public constant DAI = address(bytes20(hex"efd766ccb38eaf1dfd701853bfce31359239f305"));
    address public constant PLSX = address(bytes20(hex"95b303987a60c71504d99aa1b13b4da07b0790ab"));
    address public constant WPLS = address(bytes20(hex"a1077a294dde1b09bb078844df40758a5d0f9a27"));
    address public constant PULSEX_FACTORY = address(bytes20(hex"1715a3e4a142d8b698131108995174f37aeBA10D"));
    address public constant PULSEX_ROUTER = 0x98bf93ebf5c380C0e6Ae8e192A7e2AE08edAcc02;

    IPulseXRouter public immutable router;
    address public immutable liquidityRecipient;
    address public immutable reserveWallet;

    address public stakingContract;

    struct MintParams {
        uint256 ndaiOut;
        uint256 maxPdaiIn;
        uint256 minPlsxOut;
        uint256 minPdaiAdded;
        uint256 minPlsxAdded;
        uint256 minLpOut;
        uint256 deadline;
    }

    error InvalidConfiguration();
    error InvalidMint();
    error LaunchPending();
    error PaymentLimitExceeded();
    error UnexpectedTokenBalance();
    error InsufficientLiquidityTokens();
    error InsufficientLiquidityDeposit();
    error ReserveFraction();

    event ReserveFunded(address indexed account, uint256 daiLocked);
    event Minted(address indexed account, uint256 ndaiMinted, uint256 pdaiForDai, uint256 pdaiForPlsx, uint256 pdaiAdded, uint256 plsxAdded, uint256 lpMinted, uint256 pdaiRefund, uint256 plsxRefund);

    constructor(IPulseXRouter pulseRouter, uint256 launchTime) ERC20("NDAI", "NDAI") Ownable(msg.sender) {
        if (block.chainid != 369 || launchTime == 0 || address(pulseRouter) != PULSEX_ROUTER || PULSEX_ROUTER.code.length == 0) {
            revert InvalidConfiguration();
        }
        if (pulseRouter.factory() != PULSEX_FACTORY || PDAI.code.length == 0 || IERC20Metadata(DAI).decimals() != decimals()) revert InvalidConfiguration();

        IPulseXFactory factory = IPulseXFactory(PULSEX_FACTORY);
        if (factory.getPair(PDAI, PLSX) == address(0) || factory.getPair(PLSX, WPLS) == address(0) || factory.getPair(WPLS, DAI) == address(0)) revert InvalidConfiguration();

        LAUNCH_TIME = launchTime;
        router = pulseRouter;
        liquidityRecipient = address(new PermanentTokenLock());
        reserveWallet = address(new PermanentTokenLock());
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function reserveDaiBalance() external view returns (uint256) {
        return IERC20(DAI).balanceOf(reserveWallet);
    }

    function setStakingContract(address _staking) external onlyOwner {
        require(stakingContract == address(0), "Already set");
        require(_staking != address(0), "Zero address");
        stakingContract = _staking;
    }

    function mintYield(address to, uint256 amount) external {
        require(msg.sender == stakingContract, "Only staking");
        _mint(to, amount);
    }

    function mintWithPdai(MintParams calldata params) external nonReentrant {
        if (block.timestamp < LAUNCH_TIME) revert LaunchPending();
        if (params.ndaiOut < 1 ether || params.ndaiOut > 100 ether || params.minPlsxOut == 0 || params.minPdaiAdded == 0 || params.minPlsxAdded == 0 || params.minLpOut == 0 || block.timestamp > params.deadline || params.deadline - block.timestamp > 5 minutes) revert InvalidMint();

        address[] memory path = new address[](4);
        path[0] = PDAI;
        path[1] = PLSX;
        path[2] = WPLS;
        path[3] = DAI;

        uint256 daiOut = params.ndaiOut;
        uint256[] memory amounts = router.getAmountsIn(daiOut, path);
        uint256 pdaiForDai = amounts[0];
        uint256 contribution = pdaiForDai / 5;
        if (contribution < 2) revert InvalidMint();
        uint256 payment = pdaiForDai + contribution;
        if (payment > params.maxPdaiIn) revert PaymentLimitExceeded();
        _checkRoute(path, amounts, contribution / 2);

        IERC20 pdai = IERC20(PDAI);
        uint256 initialPdai = pdai.balanceOf(address(this));
        pdai.safeTransferFrom(msg.sender, address(this), payment);
        if (pdai.balanceOf(address(this)) != initialPdai + payment) revert UnexpectedTokenBalance();

        _fundReserve(path, daiOut, pdaiForDai, params.deadline);
        _addLiquidity(params, pdaiForDai, contribution);
        cumulativeMinted += params.ndaiOut;
        _mint(msg.sender, params.ndaiOut);
    }

    function _checkRoute(address[] memory path, uint256[] memory amounts, uint256 supplementalIn) private view {
        for (uint256 i; i < 3; ++i) {
            (uint256 input, uint256 output) = _reserves(path[i], path[i + 1]);
            _checkFraction(amounts[i], input);
            _checkFraction(amounts[i + 1], output);
            if (i == 0) {
                uint256 afterInput = input + amounts[0];
                uint256 afterOutput = output - amounts[1];
                uint256 supplementalOut = router.getAmountOut(supplementalIn, afterInput, afterOutput);
                _checkFraction(supplementalIn, afterInput);
                _checkFraction(supplementalOut, afterOutput);
                _checkFraction(amounts[0] + supplementalIn, input);
                _checkFraction(amounts[1] + supplementalOut, output);
            }
        }
    }

    function _reserves(address input, address output) private view returns (uint256, uint256) {
        IPulseXPair pair = IPulseXPair(IPulseXFactory(PULSEX_FACTORY).getPair(input, output));
        (uint112 r0, uint112 r1,) = pair.getReserves();
        return pair.token0() == input ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _checkFraction(uint256 amount, uint256 reserve) private pure {
        if (reserve == 0 || amount > reserve * 4 / 100) revert ReserveFraction();
    }

    function _fundReserve(address[] memory path, uint256 daiOut, uint256 pdaiForDai, uint256 deadline) private {
        uint256 initialDai = IERC20(DAI).balanceOf(reserveWallet);
        IERC20(PDAI).forceApprove(address(router), pdaiForDai);
        uint256[] memory spent = router.swapTokensForExactTokens(daiOut, pdaiForDai, path, reserveWallet, deadline);
        IERC20(PDAI).forceApprove(address(router), 0);
        uint256 received = IERC20(DAI).balanceOf(reserveWallet) - initialDai;
        if (spent[0] != pdaiForDai || received < daiOut) revert UnexpectedTokenBalance();
        cumulativeDaiFunded += received;
        emit ReserveFunded(msg.sender, received);
    }

    function _addLiquidity(MintParams calldata params, uint256 pdaiForDai, uint256 contribution) private {
        IERC20 pdai = IERC20(PDAI);
        IERC20 plsx = IERC20(PLSX);
        uint256 initialPlsx = plsx.balanceOf(address(this));
        uint256 pdaiForPlsx = contribution / 2;
        uint256 pdaiForPool = contribution - pdaiForPlsx;

        address[] memory path = new address[](2);
        path[0] = PDAI;
        path[1] = PLSX;

        (uint256 input, uint256 output) = _reserves(PDAI, PLSX);
        _checkFraction(pdaiForPlsx, input);
        _checkFraction(router.getAmountOut(pdaiForPlsx, input, output), output);
        pdai.forceApprove(address(router), pdaiForPlsx);
        router.swapExactTokensForTokens(pdaiForPlsx, params.minPlsxOut, path, address(this), params.deadline);
        uint256 plsxReceived = plsx.balanceOf(address(this)) - initialPlsx;
        if (plsxReceived < params.minPlsxOut) revert UnexpectedTokenBalance();

        pdai.forceApprove(address(router), pdaiForPool);
        plsx.forceApprove(address(router), plsxReceived);
        IERC20 lpToken = IERC20(IPulseXFactory(PULSEX_FACTORY).getPair(PDAI, PLSX));
        uint256 initialLp = lpToken.balanceOf(liquidityRecipient);
        (uint256 pdaiAdded, uint256 plsxAdded, uint256 lpMinted) = router.addLiquidity(PDAI, PLSX, pdaiForPool, plsxReceived, params.minPdaiAdded, params.minPlsxAdded, liquidityRecipient, params.deadline);
        if (pdaiAdded < params.minPdaiAdded || plsxAdded < params.minPlsxAdded) revert InsufficientLiquidityDeposit();
        if (lpMinted < params.minLpOut || lpToken.balanceOf(liquidityRecipient) - initialLp != lpMinted) revert InsufficientLiquidityTokens();
        pdai.forceApprove(address(router), 0);
        plsx.forceApprove(address(router), 0);

        uint256 pdaiRefund = pdaiForPool - pdaiAdded;
        uint256 plsxRefund = plsxReceived - plsxAdded;
        if (pdaiRefund != 0) pdai.safeTransfer(msg.sender, pdaiRefund);
        if (plsxRefund != 0) plsx.safeTransfer(msg.sender, plsxRefund);

        emit Minted(msg.sender, params.ndaiOut, pdaiForDai, pdaiForPlsx, pdaiAdded, plsxAdded, lpMinted, pdaiRefund, plsxRefund);
    }
}
