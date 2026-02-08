// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract CheckPoolState is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant HOOK = 0xaD599566C6cA5b222d782d152d21cF77efdc80C0;
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

    function run() public view {
        IPoolManager manager = IPoolManager(POOL_MANAGER);

        // Sort currencies
        address currency0 = USDC < WETH ? USDC : WETH;
        address currency1 = USDC < WETH ? WETH : USDC;

        // 0.3% Pool
        checkPool(manager, currency0, currency1, 3000, 60);

        // 0.05% Pool
        checkPool(manager, currency0, currency1, 500, 10);

        // 1.0% Pool
        checkPool(manager, currency0, currency1, 10000, 200);
    }

    function checkPool(
        IPoolManager manager,
        address c0,
        address c1,
        uint24 fee,
        int24 ts
    ) internal view {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: ts,
            hooks: IHooks(HOOK)
        });

        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 tick, , ) = manager.getSlot0(id);
        uint128 liquidity = manager.getLiquidity(id);

        console.log("--- Pool Tier:", fee);
        console.log("Pool ID:");
        console.logBytes32(PoolId.unwrap(id));
        console.log("Sqrt Price:", sqrtPriceX96);
        console.log("Current Tick:", tick);
        console.log("Liquidity:", liquidity);
    }
}
