// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {InvestInGasHook} from "../src/InvestInGasHook.sol";

/**
 * @title AlignExistingHook
 * @notice Aligns the existing deployed hook with the correct pool tier.
 */
contract AlignExistingHook is Script {
    address constant HOOK = 0xaD599566C6cA5b222d782d152d21cF77efdc80C0;
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        InvestInGasHook hook = InvestInGasHook(HOOK);

        // Sort currencies
        address currency0 = USDC < WETH ? USDC : WETH;
        address currency1 = USDC < WETH ? WETH : USDC;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 500, // 0.05% tier
            tickSpacing: 10,
            hooks: IHooks(HOOK)
        });

        vm.startBroadcast(deployerPrivateKey);

        // 1. Update PoolKey in the hook
        hook.setPoolKey(key);
        console.log("Updated hook poolKey to 0.05% tier");

        vm.stopBroadcast();
    }
}
