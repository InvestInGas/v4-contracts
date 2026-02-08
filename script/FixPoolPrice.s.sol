// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {InvestInGasHook} from "../src/InvestInGasHook.sol";

contract FixPoolPrice is Script {
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address constant HOOK = 0xaD599566C6cA5b222d782d152d21cF77efdc80C0;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Lower address is currency0 (USDC < WETH)
        address currency0 = USDC < WETH ? USDC : WETH;
        address currency1 = USDC < WETH ? WETH : USDC;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 500, // Using 0.05% tier
            tickSpacing: 10,
            hooks: IHooks(HOOK)
        });

        // Correct sqrtPriceX96 for ~2500 USDC per ETH
        // Ratio = WETH_units / USDC_units = 400,000,000
        // sqrtPrice = sqrt(400,000,000) = 20,000
        // sqrtPriceX96 = 20,000 * 2^96
        uint160 sqrtPriceX96 = uint160(20000) << 96;

        vm.startBroadcast(deployerPrivateKey);

        // 1. Wrap some ETH into WETH (0.05 ETH)
        (bool success, ) = WETH.call{value: 0.05 ether}(
            abi.encodeWithSignature("deposit()")
        );
        require(success, "WETH deposit failed");
        console.log("Wrapped 0.05 ETH into WETH");

        // 2. Initialize the pool with corrected price
        IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);
        console.log("New Pool Initialized at 0.05% tier!");

        // 3. Update the hook to use the new pool
        InvestInGasHook(HOOK).setPoolKey(key);
        console.log("Hook updated to use the new PoolKey!");

        vm.stopBroadcast();
    }
}
