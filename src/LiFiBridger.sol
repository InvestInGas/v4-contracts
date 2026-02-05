// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiFiBridger} from "./interfaces/ILiFiBridger.sol";

/**
 * @title IWETH
 * @notice Interface for WETH deposit/withdraw
 */
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title LiFiBridger
 * @notice Helper contract to bridge assets via LiFi
 */
contract LiFiBridger is ILiFiBridger {
    using SafeERC20 for IERC20;

    // ============ State Variables ============

    IWETH public immutable weth;
    address public immutable lifiDiamond;
    address public owner;
    address public hook;

    // ============ Errors ============

    error NotHook();
    error NotOwner();
    error TransferFailed();
    error BridgeFailed();
    error ZeroAmount();

    // ============ Events ============

    event BridgeExecuted(
        uint256 indexed chainId,
        address indexed recipient,
        uint256 amount
    );

    event DirectTransferExecuted(address indexed recipient, uint256 amount);

    event HookUpdated(address indexed oldHook, address indexed newHook);

    // ============ Modifiers ============

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ============ Constructor ============

    constructor(address _weth, address _lifiDiamond, address _owner) {
        weth = IWETH(_weth);
        lifiDiamond = _lifiDiamond;
        owner = _owner;
    }

    // ============ Receive ============

    receive() external payable {}

    // ============ Core Functions ============

    /**
     * @inheritdoc ILiFiBridger
     */
    function bridgeToChain(
        uint256 destinationChainId,
        uint256 amount,
        address recipient,
        bytes calldata lifiData
    ) external onlyHook {
        if (amount == 0) revert ZeroAmount();

        // Transfer WETH from hook
        IERC20(address(weth)).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        // Unwrap WETH to ETH
        weth.withdraw(amount);

        // Execute LiFi bridge with ETH via low-level call
        // lifiData must contain the full calldata (selector + args)
        (bool success, ) = lifiDiamond.call{value: amount}(lifiData);
        if (!success) revert BridgeFailed();

        emit BridgeExecuted(destinationChainId, recipient, amount);
    }

    /**
     * @inheritdoc ILiFiBridger
     */
    function directTransfer(
        uint256 amount,
        address recipient
    ) external onlyHook {
        if (amount == 0) revert ZeroAmount();

        // Transfer WETH from hook
        IERC20(address(weth)).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        // Unwrap WETH to ETH
        weth.withdraw(amount);

        // Direct ETH transfer
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit DirectTransferExecuted(recipient, amount);
    }

    // ============ Admin Functions ============

    function setHook(address _hook) external onlyOwner {
        address oldHook = hook;
        hook = _hook;
        emit HookUpdated(oldHook, _hook);
    }

    /**
     * @notice Emergency withdraw ETH
     */
    function emergencyWithdrawETH(address to) external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success, ) = to.call{value: balance}("");
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Emergency withdraw ERC20
     */
    function emergencyWithdrawToken(
        address token,
        address to
    ) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, balance);
    }
}
