// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NDAICustody} from "./NDAICustody.sol";
import {NDAIFeeVault} from "./NDAIFeeVault.sol";

uint32 constant NDAI_LAUNCH_REDEMPTION_DAY = 3300;

contract NDAITimeClaim is ERC20 {
    address public immutable series;
    uint256 public immutable redemptionTime;

    error WrongChain();
    error OnlySeries();

    constructor(uint256 maturity, uint32 day)
        ERC20(
            string.concat("NEW Time Token ", Strings.toString(day)),
            day == NDAI_LAUNCH_REDEMPTION_DAY ? "NEW" : string.concat("NEW-", Strings.toString(day))
        )
    {
        if (block.chainid != 369) revert WrongChain();
        series = msg.sender;
        redemptionTime = maturity;
    }

    function mint(address account, uint256 amount) external {
        if (msg.sender != series) revert OnlySeries();
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        if (msg.sender != series) revert OnlySeries();
        _burn(account, amount);
    }
}

/// @notice One fixed redemption series. The fee vault is independent of position collateral.
contract NDAIStaking is ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint32 public constant MATURITY_DAY = 90; // Existing position interface uses days from launch.
    uint32 public constant REDEMPTION_DAY = NDAI_LAUNCH_REDEMPTION_DAY;
    uint256 public immutable dayZero;

    struct Stake {
        uint32 maturityDay;
        uint256 principal;
        uint256 issued;
    }

    IERC20 public immutable ndai;
    uint256 public immutable LAUNCH_TIME;
    uint256 public immutable redemptionTime;
    uint256 public immutable issuanceCutoff;
    NDAITimeClaim public immutable claimToken;
    NDAIFeeVault public immutable feeVault;
    NDAICustody public immutable positionCustody;
    NDAICustody public immutable claimCustody;

    uint256 public stakeCount;
    uint256 public userBacking;
    uint256 public feeBacking;
    mapping(uint256 => Stake) public stakes;

    error WrongChain();
    error InvalidStake();
    error LaunchPending();
    error IssuanceClosed();
    error OnlyStakeOwner();
    error MaturityReached();
    error MaturityPending();
    error InvalidAmount();
    error UnexpectedReceipt();
    error BuyerBounds();

    event Staked(uint256 indexed id, address indexed owner, uint32 maturityDay, uint256 amount);
    event Extracted(uint256 indexed id, uint256 gross, uint256 fee, uint256 net);
    event Retired(uint256 indexed id, uint256 amount);
    event Withdrawn(uint256 indexed id, uint256 amount);
    event Redeemed(uint32 indexed maturityDay, address indexed holder, uint256 amount);

    constructor(IERC20 asset, uint256 start) ERC721("NDAI Stake Position", "NDAI-STK") {
        if (block.chainid != 369) revert WrongChain();
        if (start < uint256(REDEMPTION_DAY - MATURITY_DAY) * 1 days || start > 253402300799 - 90 days || address(asset).code.length == 0
            || IERC20Metadata(address(asset)).decimals() != 18) revert InvalidStake();
        ndai = asset;
        LAUNCH_TIME = start;
        uint256 maturity = start + 90 days;
        redemptionTime = maturity;
        issuanceCutoff = maturity - 1 days;
        dayZero = maturity - uint256(REDEMPTION_DAY) * 1 days;
        claimToken = new NDAITimeClaim(maturity, REDEMPTION_DAY);
        feeVault = new NDAIFeeVault(asset, IERC20(address(claimToken)), start, maturity);
        positionCustody = new NDAICustody(asset);
        claimCustody = new NDAICustody(asset);
    }

    function maturityTime(uint32 day) external view returns (uint256) {
        if (day != MATURITY_DAY) revert InvalidStake();
        return redemptionTime;
    }

    function maturityTokens(uint32 day) external view returns (NDAITimeClaim) {
        if (day != MATURITY_DAY) revert InvalidStake();
        return claimToken;
    }

    function stake(uint256 amount, uint32 day) external nonReentrant returns (uint256 id) {
        _checkIssuanceWindow();
        if (day != MATURITY_DAY || amount < 1 ether) revert InvalidStake();
        id = ++stakeCount;
        stakes[id] = Stake(day, amount, 0);
        address custody = address(positionCustody);
        uint256 before = ndai.balanceOf(custody);
        ndai.safeTransferFrom(msg.sender, custody, amount);
        if (ndai.balanceOf(custody) - before != amount) revert UnexpectedReceipt();
        _safeMint(msg.sender, id);
        emit Staked(id, msg.sender, day, amount);
    }

    /// @notice The buyer accepts the current owner's ERC-721 approval with transaction-signed bounds.
    function acceptPosition(address seller, uint256 id, uint256 maxDebt, uint256 minFree, uint256 deadline)
        external nonReentrant
    {
        if (block.timestamp > deadline || ownerOf(id) != seller || !_isAuthorized(seller, msg.sender, id)) {
            revert BuyerBounds();
        }
        Stake storage position = stakes[id];
        if (position.issued > maxDebt || position.principal - position.issued < minFree) revert BuyerBounds();
        _safeTransfer(seller, msg.sender, id);
    }

    function extract(uint256 id, uint256 gross, uint256 minNet) external nonReentrant {
        if (_ownerOf(id) != msg.sender) revert OnlyStakeOwner();
        _checkIssuanceWindow();
        Stake storage position = stakes[id];
        if (gross == 0 || gross > position.principal - position.issued) revert InvalidAmount();

        uint256 eligible = feeVault.prepareIssuance();
        uint256 fee = eligible == 0 ? 0 : Math.ceilDiv(gross, 100);
        if (fee >= gross || gross - fee < minNet) revert InvalidAmount();
        uint256 net = gross - fee;
        position.issued += gross;
        userBacking += net;
        feeBacking += fee;

        address reserve = address(claimCustody);
        uint256 before = ndai.balanceOf(reserve);
        positionCustody.pay(reserve, gross);
        if (ndai.balanceOf(reserve) - before != gross) revert UnexpectedReceipt();

        claimToken.mint(msg.sender, net);
        if (fee != 0) {
            address escrow = address(feeVault.feeEscrow());
            uint256 escrowBefore = claimToken.balanceOf(escrow);
            claimToken.mint(escrow, fee);
            feeVault.recordFee(fee, escrowBefore);
        }
        emit Extracted(id, gross, fee, net);
    }

    function retire(uint256 id, uint256 amount) external nonReentrant {
        if (_ownerOf(id) != msg.sender) revert OnlyStakeOwner();
        if (block.timestamp >= redemptionTime) revert MaturityReached();
        Stake storage position = stakes[id];
        if (amount == 0 || amount > position.issued) revert InvalidAmount();
        claimToken.burn(msg.sender, amount);
        position.issued -= amount;
        _consumeBacking(amount);
        claimCustody.pay(address(positionCustody), amount);
        emit Retired(id, amount);
    }

    function withdraw(uint256 id) external nonReentrant {
        if (_ownerOf(id) != msg.sender) revert OnlyStakeOwner();
        if (block.timestamp < redemptionTime) revert MaturityPending();
        Stake memory position = stakes[id];
        delete stakes[id];
        _burn(id);
        uint256 amount = position.principal - position.issued;
        if (amount != 0) positionCustody.pay(msg.sender, amount);
        emit Withdrawn(id, amount);
    }

    function redeem(uint32 day, uint256 amount) external nonReentrant {
        if (day != MATURITY_DAY || amount == 0) revert InvalidAmount();
        if (block.timestamp < redemptionTime) revert MaturityPending();
        claimToken.burn(msg.sender, amount);
        _consumeBacking(amount);
        claimCustody.pay(msg.sender, amount);
        emit Redeemed(day, msg.sender, amount);
    }

    function _consumeBacking(uint256 amount) private {
        uint256 userDebit = Math.min(userBacking, amount);
        userBacking -= userDebit;
        feeBacking -= amount - userDebit;
    }

    function _checkIssuanceWindow() private view {
        if (block.timestamp < LAUNCH_TIME) revert LaunchPending();
        if (block.timestamp >= issuanceCutoff) revert IssuanceClosed();
    }
}
