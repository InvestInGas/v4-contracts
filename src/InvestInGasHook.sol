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

    // ============ Structs ============

    /**
     * @notice Represents a locked gas position
     * @param wethAmount Initial WETH amount locked
     * @param remainingWethAmount Remaining WETH after partial redemptions
     * @param lockedGasPriceWei Gas price in wei at time of purchase
     * @param purchaseTimestamp Timestamp when position was created
     * @param expiry Position expiry timestamp
     * @param targetChain Chain where gas will be delivered (e.g. "sepolia", "arbitrum", "base")
     */
    struct GasPosition {
        uint256 wethAmount;
        uint256 remainingWethAmount;
        uint96 lockedGasPriceWei;
        uint40 purchaseTimestamp;
        uint40 expiry;
        string targetChain;
    }

    // ============ State Variables ============

    /// @notice Token used for purchasing (USDC)
    IERC20 public immutable purchaseToken;

    /// @notice WETH token for internal accounting
    IERC20 public immutable weth;

    /// @notice LiFi bridger contract for cross-chain gas delivery
    ILiFiBridger public liFiBridger;

    /// @notice Authorized relayer address for submitting transactions
    address public relayer;

    /// @notice Owner address for admin functions
    address public owner;

    /// @notice Protocol fee in basis points (e.g. 50 = 0.5%)
    uint16 public constant PROTOCOL_FEE_BPS = 50;

    /// @notice Expiry refund fee in basis points (e.g. 200 = 2%)
    uint16 public constant EXPIRY_REFUND_FEE_BPS = 200;

    /// @notice Maximum slippage allowed in basis points (e.g. 100 = 1%)
    uint16 public constant MAX_SLIPPAGE_BPS = 100;

    /// @notice Next token ID for minting
    uint256 private _nextTokenId;

    /// @notice Position data by token ID
    mapping(uint256 => GasPosition) public positions;

    /// @notice Pool key for USDC/WETH pool
    PoolKey public poolKey;

    /// @notice Chain IDs for supported chains
    mapping(string => uint256) public chainIds;

    /// @notice Accumulated protocol fees in WETH
    uint256 public accumulatedFees;

    // ============ Events ============

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

        // Set up supported chain IDs
        chainIds["sepolia"] = 11155111;
        chainIds["arbitrum"] = 421614; // Arbitrum Sepolia
        chainIds["base"] = 84532; // Base Sepolia
        chainIds["polygon"] = 80002; // Polygon Amoy
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
     * @notice Purchase a gas position using USDC
     * @param usdcAmount Amount of USDC to spend
     * @param minWethOut Minimum WETH to receive (slippage protection)
     * @param lockedGasPriceWei Gas price to lock in (from oracle)
     * @param targetChain Chain where gas will be delivered
     * @param expiryDuration Duration until position expires (seconds)
     * @param buyer Address of the position buyer
     * @return tokenId The minted position NFT ID
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

        // Transfer USDC from buyer
        purchaseToken.safeTransferFrom(buyer, address(this), usdcAmount);

        // Approve PoolManager to spend USDC
        purchaseToken.approve(address(poolManager), usdcAmount);

        // Execute swap: USDC -> WETH via PoolManager
        uint256 wethReceived = _executeSwap(usdcAmount, minWethOut);

        // Deduct protocol fee
        uint256 feeAmount = (wethReceived * PROTOCOL_FEE_BPS) / 10000;
        uint256 netWethAmount = wethReceived - feeAmount;
        accumulatedFees += feeAmount;

        // Mint position NFT
        tokenId = _nextTokenId++;
        _mint(buyer, tokenId);

        // Store position data
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
     * @notice Redeem all or part of a gas position
     * @param tokenId Position NFT ID
     * @param wethAmount Amount of WETH to redeem
     * @param lifiData Calldata for LiFi bridge (empty for same-chain)
     * @param recipient Address to receive gas on target chain
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

        // If fully redeemed, burn the NFT
        if (pos.remainingWethAmount == 0) {
            _burn(tokenId);
        }

        // Execute redemption via LiFi or direct transfer
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

        // Deduct expiry fee
        uint256 feeAmount = (remaining * EXPIRY_REFUND_FEE_BPS) / 10000;
        uint256 refundAmount = remaining - feeAmount;
        accumulatedFees += feeAmount;

        // Clear position and burn NFT
        pos.remainingWethAmount = 0;
        _burn(tokenId);

        // Refund WETH to user
        weth.safeTransfer(posOwner, refundAmount);

        emit PositionExpiryClaimed(tokenId, posOwner, refundAmount, feeAmount);
    }

    // ============ Internal Functions ============

    function _executeSwap(
        uint256 usdcAmount,
        uint256 minWethOut
    ) internal returns (uint256 wethReceived) {
        // Build swap params: exact input of USDC for WETH
        SwapParams memory params = SwapParams({
            zeroForOne: true, // USDC (token0) -> WETH (token1) convention
            amountSpecified: -int256(usdcAmount), // Negative = exact input
            sqrtPriceLimitX96: 0 // No price limit, rely on slippage check
        });

        // Execute swap
        BalanceDelta delta = poolManager.swap(poolKey, params, "");

        // Extract WETH received (token1)
        wethReceived = uint256(uint128(delta.amount1()));

        // Slippage check
        if (wethReceived < minWethOut) revert SlippageExceeded();
    }

    function _executeRedemption(
        uint256 wethAmount,
        string memory targetChain,
        bytes calldata lifiData,
        address recipient
    ) internal {
        // Approve WETH for bridger
        weth.approve(address(liFiBridger), wethAmount);

        // Check if same-chain (Sepolia)
        if (keccak256(bytes(targetChain)) == keccak256(bytes("sepolia"))) {
            // Direct transfer - no bridge needed
            liFiBridger.directTransfer(wethAmount, recipient);
        } else {
            // Cross-chain bridge via LiFi
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
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Only allow swaps on our designated pool
        // Additional validation can be added here
        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Post-swap accounting if needed
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
