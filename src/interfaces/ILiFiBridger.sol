// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ILiFiBridger
 * @notice Interface for LiFi cross-chain bridging
 */
interface ILiFiBridger {
    /**
     * @notice Bridge WETH to target chain as native gas token
     * @param destinationChainId Target chain ID
     * @param amount WETH amount to bridge
     * @param recipient Address to receive gas on target chain
     * @param lifiData LiFi route data
     */
    function bridgeToChain(
        uint256 destinationChainId,
        uint256 amount,
        address recipient,
        bytes calldata lifiData
    ) external;

    /**
     * @notice Direct transfer for same-chain redemption
     * @param amount WETH amount to unwrap and transfer
     * @param recipient Address to receive ETH
     */
    function directTransfer(uint256 amount, address recipient) external;
}
