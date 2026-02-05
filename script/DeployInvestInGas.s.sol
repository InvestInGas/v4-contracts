// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {InvestInGasHook} from "../src/InvestInGasHook.sol";
import {LiFiBridger} from "../src/LiFiBridger.sol";

/**
 * @title DeployInvestInGas
 * @notice Deploys InvestInGasHook and LiFiBridger to Sepolia testnet
 */
contract DeployInvestInGas is Script {
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543; // Uniswap v4 PoolManager on Sepolia
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // Circle USDC on Sepolia
    address constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9; // WETH on Sepolia
    address constant LIFI_DIAMOND = 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE; // LiFi Diamond

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address relayer = vm.envOr("RELAYER_ADDRESS", deployer);

        console.log("Deployer:", deployer);
        console.log("Relayer:", relayer);

        // Hook flags: beforeSwap, afterSwap
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        // Constructor args for InvestInGasHook
        bytes memory constructorArgs = abi.encode(
            POOL_MANAGER,
            USDC,
            WETH,
            relayer,
            deployer
        );

        // Mine hook address
        console.log("Mining hook address...");
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(InvestInGasHook).creationCode,
            constructorArgs
        );
        console.log("Hook address will be:", hookAddress);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy InvestInGasHook
        InvestInGasHook hook = new InvestInGasHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            USDC,
            WETH,
            relayer,
            deployer
        );
        require(address(hook) == hookAddress, "Hook address mismatch");
        console.log("InvestInGasHook deployed at:", address(hook));

        // 2. Deploy LiFiBridger
        LiFiBridger bridger = new LiFiBridger(WETH, LIFI_DIAMOND, deployer);
        console.log("LiFiBridger deployed at:", address(bridger));

        // 3. Configure: Set bridger in hook
        hook.setLiFiBridger(address(bridger));
        console.log("LiFiBridger set in hook");

        // 4. Configure: Set hook in bridger
        bridger.setHook(address(hook));
        console.log("Hook set in bridger");

        vm.stopBroadcast();

        // Output for verification
        console.log("\n=== Deployment Summary ===");
        console.log("InvestInGasHook:", address(hook));
        console.log("LiFiBridger:", address(bridger));
        console.log("USDC:", USDC);
        console.log("WETH:", WETH);
        console.log("PoolManager:", POOL_MANAGER);
    }
}
