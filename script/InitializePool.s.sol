// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract InitializePool is Script {
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address constant HOOK = 0xB3c188FC3bA89fEa109e69dBA81BDA4138B880c0;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Currency ordering
        address currency0 = USDC < WETH ? USDC : WETH;
        address currency1 = USDC < WETH ? WETH : USDC;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        // sqrtPriceX96 for ~2500 USDC per ETH
        // Price = 10^18 / (2500 * 10^6) = 4 * 10^8
        // sqrtPrice = 20000
        // sqrtPriceX96 = 20000 * 2^96
        uint160 sqrtPriceX96 = 1584563250285286751870879006720;

        vm.startBroadcast(deployerPrivateKey);
        IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);
        console.log("Pool initialized!");
        vm.stopBroadcast();
    }
}
