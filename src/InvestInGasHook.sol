// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {
    IPoolManager,
    SwapParams,
    ModifyLiquidityParams
} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {
    Currency,
    CurrencyLibrary
} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILiFiBridger} from "./interfaces/ILiFiBridger.sol";

/**
 * @title InvestInGasHook
 * @notice Uniswap v4 hook for gas futures with ERC721 positions
 * @dev Users deposit USDC, receive WETH position NFT, redeem as native gas on target chains
 */
contract InvestInGasHook is BaseHook, ERC721 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    struct GasPosition {
        uint256 wethAmount;
        uint256 remainingWethAmount;
        uint96 lockedGasPriceWei;
        uint40 purchaseTimestamp;
        uint40 expiry;
        string targetChain;
    }

    IERC20 public immutable purchaseToken;
    IERC20 public immutable weth;

    ILiFiBridger public liFiBridger;

    address public relayer;
    address public owner;

    uint16 public constant PROTOCOL_FEE_BPS = 50;
    uint16 public constant EXPIRY_REFUND_FEE_BPS = 200;
    uint16 public constant MAX_SLIPPAGE_BPS = 100;

    uint256 private _nextTokenId;

    mapping(uint256 => GasPosition) public positions;

    PoolKey public poolKey;

    mapping(string => uint256) public chainIds;

    uint256 public accumulatedFees;

    event PositionPurchased(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 usdcAmount,
        uint256 wethAmount,
        uint96 lockedGasPriceWei,
        string targetChain,
        uint40 expiry
    );

    event PositionRedeemed(
        uint256 indexed tokenId,
        address indexed redeemer,
        uint256 wethAmount,
        string targetChain,
        bool isPartial
    );

    event PositionExpiryClaimed(
        uint256 indexed tokenId,
        address indexed claimer,
        uint256 wethRefunded,
        uint256 feeDeducted
    );

    event RelayerUpdated(
        address indexed oldRelayer,
        address indexed newRelayer
    );
    event LiFiBridgerUpdated(
        address indexed oldBridger,
        address indexed newBridger
    );
    event PoolKeySet(PoolId indexed poolId);
    event FeesWithdrawn(address indexed to, uint256 amount);

    // ============ Errors ============

    error NotRelayer();
    error NotOwner();
    error NotPositionOwner();
    error PositionNotExpired();
    error PositionExpired();
    error InsufficientRemainingAmount();
    error SlippageExceeded();
    error InvalidChain();
    error ZeroAmount();
    error PoolNotSet();

    // ============ Modifiers ============

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert NotRelayer();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ============ Constructor ============

    constructor(
        IPoolManager _poolManager,
        address _purchaseToken,
        address _weth,
        address _relayer,
        address _owner
    ) BaseHook(_poolManager) ERC721("InvestInGas Position", "IIGPOS") {
        purchaseToken = IERC20(_purchaseToken);
        weth = IERC20(_weth);
        relayer = _relayer;
        owner = _owner;

        chainIds["ethereum"] = 11155111;
        chainIds["arbitrum"] = 421614;
        chainIds["base"] = 84532;
        chainIds["polygon"] = 80002;
        chainIds["optimism"] = 11155420;
    }

    // ============ Hook Permissions ============

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // Track swaps for accounting
                afterSwap: true, // Finalize position after swap
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // ============ Core Functions ============

    /**
     * Purchase a gas position using USDC
     */
    function purchasePosition(
        uint256 usdcAmount,
        uint256 minWethOut,
        uint96 lockedGasPriceWei,
        string calldata targetChain,
        uint40 expiryDuration,
        address buyer
    ) external onlyRelayer returns (uint256 tokenId) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (chainIds[targetChain] == 0) revert InvalidChain();
        if (poolKey.tickSpacing == 0) revert PoolNotSet();

        purchaseToken.safeTransferFrom(buyer, address(this), usdcAmount);
        purchaseToken.approve(address(poolManager), usdcAmount);

        uint256 wethReceived = _executeSwap(usdcAmount, minWethOut);

        uint256 feeAmount = (wethReceived * PROTOCOL_FEE_BPS) / 10000;
        uint256 netWethAmount = wethReceived - feeAmount;
        accumulatedFees += feeAmount;

        tokenId = _nextTokenId++;
        _mint(buyer, tokenId);

        positions[tokenId] = GasPosition({
            wethAmount: netWethAmount,
            remainingWethAmount: netWethAmount,
            lockedGasPriceWei: lockedGasPriceWei,
            purchaseTimestamp: uint40(block.timestamp),
            expiry: uint40(block.timestamp + expiryDuration),
            targetChain: targetChain
        });

        emit PositionPurchased(
            tokenId,
            buyer,
            usdcAmount,
            netWethAmount,
            lockedGasPriceWei,
            targetChain,
            uint40(block.timestamp + expiryDuration)
        );
    }

    /**
     * Redeem all or part of a gas position
     */
    function redeemPosition(
        uint256 tokenId,
        uint256 wethAmount,
        bytes calldata lifiData,
        address recipient
    ) external onlyRelayer {
        if (ownerOf(tokenId) == address(0)) revert NotPositionOwner();

        GasPosition storage pos = positions[tokenId];

        if (block.timestamp >= pos.expiry) revert PositionExpired();
        if (wethAmount > pos.remainingWethAmount)
            revert InsufficientRemainingAmount();
        if (wethAmount == 0) revert ZeroAmount();

        bool isPartial = wethAmount < pos.remainingWethAmount;
        pos.remainingWethAmount -= wethAmount;

        if (pos.remainingWethAmount == 0) {
            _burn(tokenId);
        }
        _executeRedemption(wethAmount, pos.targetChain, lifiData, recipient);

        emit PositionRedeemed(
            tokenId,
            recipient,
            wethAmount,
            pos.targetChain,
            isPartial
        );
    }

    /**
     * @notice Claim expired position (user must claim after expiry)
     * @param tokenId Position NFT ID
     */
    function claimExpired(uint256 tokenId) external {
        address posOwner = ownerOf(tokenId);
        if (msg.sender != posOwner) revert NotPositionOwner();

        GasPosition storage pos = positions[tokenId];
        if (block.timestamp < pos.expiry) revert PositionNotExpired();

        uint256 remaining = pos.remainingWethAmount;
        if (remaining == 0) revert ZeroAmount();

        uint256 feeAmount = (remaining * EXPIRY_REFUND_FEE_BPS) / 10000;
        uint256 refundAmount = remaining - feeAmount;
        accumulatedFees += feeAmount;
        pos.remainingWethAmount = 0;
        _burn(tokenId);

        weth.safeTransfer(posOwner, refundAmount);

        emit PositionExpiryClaimed(tokenId, posOwner, refundAmount, feeAmount);
    }

    // ============ Internal Functions ============

    function _executeSwap(
        uint256 usdcAmount,
        uint256 minWethOut
    ) internal returns (uint256 wethReceived) {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(usdcAmount),
            sqrtPriceLimitX96: 0
        });

        BalanceDelta delta = poolManager.swap(poolKey, params, "");

        wethReceived = uint256(uint128(delta.amount1()));

        if (wethReceived < minWethOut) revert SlippageExceeded();
    }

    function _executeRedemption(
        uint256 wethAmount,
        string memory targetChain,
        bytes calldata lifiData,
        address recipient
    ) internal {
        weth.approve(address(liFiBridger), wethAmount);

        if (keccak256(bytes(targetChain)) == keccak256(bytes("ethereum"))) {
            liFiBridger.directTransfer(wethAmount, recipient);
        } else {
            liFiBridger.bridgeToChain(
                chainIds[targetChain],
                wethAmount,
                recipient,
                lifiData
            );
        }
    }

    // ============ Hook Callbacks ============

    function _beforeSwap(
        address,
        PoolKey calldata /* key */,
        SwapParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4, BeforeSwapDelta, uint24) {
        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata /* key */,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal pure override returns (bytes4, int128) {
        return (BaseHook.afterSwap.selector, 0);
    }

    // ============ Admin Functions ============

    function setPoolKey(PoolKey calldata _poolKey) external onlyOwner {
        poolKey = _poolKey;
        emit PoolKeySet(_poolKey.toId());
    }

    function setRelayer(address _relayer) external onlyOwner {
        address oldRelayer = relayer;
        relayer = _relayer;
        emit RelayerUpdated(oldRelayer, _relayer);
    }

    function setLiFiBridger(address _liFiBridger) external onlyOwner {
        address oldBridger = address(liFiBridger);
        liFiBridger = ILiFiBridger(_liFiBridger);
        emit LiFiBridgerUpdated(oldBridger, _liFiBridger);
    }

    function addChain(
        string calldata chainName,
        uint256 chainId
    ) external onlyOwner {
        chainIds[chainName] = chainId;
    }

    function withdrawFees(address to) external onlyOwner {
        uint256 fees = accumulatedFees;
        accumulatedFees = 0;
        weth.safeTransfer(to, fees);
        emit FeesWithdrawn(to, fees);
    }

    // ============ View Functions ============

    function getPosition(
        uint256 tokenId
    ) external view returns (GasPosition memory) {
        return positions[tokenId];
    }

    function getGasUnitsAvailable(
        uint256 tokenId
    ) external view returns (uint256) {
        GasPosition memory pos = positions[tokenId];
        if (pos.lockedGasPriceWei == 0) return 0;
        return pos.remainingWethAmount / pos.lockedGasPriceWei;
    }
}
