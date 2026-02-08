// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    Currency,
    CurrencyLibrary
} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {
    IUnlockCallback
} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    ModifyLiquidityParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract LiquidityHelper is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    struct CallbackData {
        PoolKey key;
        ModifyLiquidityParams params;
        address sender;
    }

    function addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) external {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: 0
        });

        manager.unlock(abi.encode(CallbackData(key, params, msg.sender)));
    }

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == address(manager));
        CallbackData memory cb = abi.decode(data, (CallbackData));

        // 1. Modify Liquidity
        (BalanceDelta delta, ) = manager.modifyLiquidity(cb.key, cb.params, "");

        // 2. Settle the negative deltas (tokens we owe)
        if (delta.amount0() < 0) {
            uint256 amount = uint256(uint128(-delta.amount0()));
            manager.sync(cb.key.currency0);
            IERC20(Currency.unwrap(cb.key.currency0)).transferFrom(
                cb.sender,
                address(manager),
                amount
            );
            manager.settle();
        }
        if (delta.amount1() < 0) {
            uint256 amount = uint256(uint128(-delta.amount1()));
            manager.sync(cb.key.currency1);
            IERC20(Currency.unwrap(cb.key.currency1)).transferFrom(
                cb.sender,
                address(manager),
                amount
            );
            manager.settle();
        }

        return "";
    }
}

contract AddLiquidity is Script {
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address constant HOOK = 0xaD599566C6cA5b222d782d152d21cF77efdc80C0;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Sort currencies
        address currency0 = USDC < WETH ? USDC : WETH;
        address currency1 = USDC < WETH ? WETH : USDC;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(HOOK)
        });

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Helper
        LiquidityHelper helper = new LiquidityHelper(
            IPoolManager(POOL_MANAGER)
        );
        console.log("LiquidityHelper deployed at:", address(helper));

        // 2. Approve Tokens to Helper
        IERC20(USDC).approve(address(helper), type(uint256).max);
        IERC20(WETH).approve(address(helper), type(uint256).max);
        console.log("Tokens approved to Helper");

        // 3. Add Liquidity
        // Around tick 198000 to 198200 (wider range)
        // Liquidity delta: 1e12 is ~0.5 USDC worth
        helper.addLiquidity(key, 198000, 198200, 1e12);

        console.log("Liquidity successfully added to the new 0.05% pool!");

        vm.stopBroadcast();
    }
}
