// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LucidHook} from "../src/LucidHook.sol";
import {LucidToken} from "../src/LucidToken.sol";

/// @notice Local mainnet-fork E2E (anvil --fork-url, test keys only). Not for production.
///   1. deploy(): token + hook through the CREATE2 deployer with the salts from MineHookSalt
///      (GRAPH_FACTORY=0x4e59b44847b379578588920cA78FbF26c0B4956C), test routers, initialize
///      the ETH/LUCID pool on the real PoolManager and add full-range liquidity.
///   2. swaps(): round trips (buy exact-in ETH, sell exact-in LUCID) so the hook accrues fees.
contract ForkE2E is Script {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function _key(address token, address hook) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    function deploy() external {
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        vm.startBroadcast(pk);
        LucidToken token = new LucidToken{salt: vm.envBytes32("TOKEN_SALT")}(vm.addr(pk), "LUCID is an AI agent that lives in its own Uniswap v4 pool.", "https://lucid.example/", "https://lucid.example/assets/lucid-logo-1024.png", "https://x.com/lucid_agent");
        require(address(token) == vm.envAddress("EXPECT_TOKEN"), "token address != mined");
        LucidHook hook = new LucidHook{salt: bytes32(vm.envUint("HOOK_SALT"))}(
            pm,
            Currency.wrap(address(token)),
            vm.envAddress("PLATFORM_FEE_RECIPIENT"),
            vm.envUint("PLATFORM_FEE_PPM"),
            vm.envAddress("GUARDIAN"),
            vm.envAddress("AGENT"),
            vm.envAddress("BUYBACK"),
            vm.envAddress("TREASURY"),
            vm.envAddress("LIQ")
        );
        require(address(hook) == vm.envAddress("EXPECT_HOOK"), "hook address != mined");
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        PoolSwapTest sw = new PoolSwapTest(pm);

        PoolKey memory key = _key(address(token), address(hook));
        pm.initialize(key, SQRT_PRICE_1_1);
        token.approve(address(lp), type(uint256).max);
        token.approve(address(sw), type(uint256).max);
        lp.modifyLiquidity{value: 110 ether}(
            key, ModifyLiquidityParams({tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 100e18, salt: 0}), ""
        );
        vm.stopBroadcast();

        console2.log("TOKEN", address(token));
        console2.log("HOOK", address(hook));
        console2.log("LP_ROUTER", address(lp));
        console2.log("SWAP_ROUTER", address(sw));
    }

    function swaps(address token, address hook, address router, uint256 n) external {
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        PoolKey memory key = _key(token, hook);
        PoolSwapTest sw = PoolSwapTest(payable(router));
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.startBroadcast(pk);
        for (uint256 i = 0; i < n; i++) {
            // buy: exact-in 1 ETH (fee taken in beforeSwap)
            sw.swap{value: 1 ether}(
                key, SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), ts, ""
            );
            // sell: exact-in 0.9 LUCID (fee taken from the ETH output in afterSwap)
            sw.swap(
                key, SwapParams({zeroForOne: false, amountSpecified: -0.9 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), ts, ""
            );
        }
        vm.stopBroadcast();
        console2.log("accruedProjectFees", LucidHook(payable(hook)).accruedProjectFees());
        console2.log("cumulativeVolumeEth", LucidHook(payable(hook)).cumulativeVolumeEth());
    }
}
