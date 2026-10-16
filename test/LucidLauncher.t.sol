// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {LucidHook} from "../src/LucidHook.sol";
import {LucidToken} from "../src/LucidToken.sol";
import {LucidLauncher} from "../src/LucidLauncher.sol";

/// @notice The fair launch: the launcher creates the pool, locks 100% of the supply in it and makes the initial buy.
contract LucidLauncherTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    int24 constant SPACING = 60;
    int24 constant LAUNCH_TICK = 196_200; // ~3.3e8 LUCID per ETH: a ~3 ETH starting valuation

    address platform = makeAddr("programmable");
    address launchWallet = makeAddr("launch-wallet");
    address trader = makeAddr("trader");

    LucidLauncher launcher;
    LucidToken lucid;
    LucidHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        // Graph order: launcher (deployed by "the factory" = this test), token minting to it, then the hook.
        launcher = new LucidLauncher(manager);
        lucid = new LucidToken(address(launcher), "LUCID is an AI agent that lives in its own Uniswap v4 pool.", "https://lucid.example/", "https://lucid.example/assets/lucid-logo-1024.png", "https://x.com/lucid_agent");
        address hookAddr = address(FLAGS | uint160(0x1A0C << 144));
        deployCodeTo(
            "LucidHook.sol:LucidHook",
            abi.encode(
                IPoolManager(address(manager)), Currency.wrap(address(lucid)), platform, uint256(3_000),
                makeAddr("guardian"), makeAddr("agent"), makeAddr("buyback"), makeAddr("treasury"), makeAddr("liq")
            ),
            hookAddr
        );
        hook = LucidHook(payable(hookAddr));
        vm.deal(address(this), 10 ether);
        vm.deal(trader, 100 ether);
    }

    function _params() internal view returns (LucidLauncher.LaunchParams memory) {
        return LucidLauncher.LaunchParams({
            token: address(lucid), hook: address(hook), tickSpacing: SPACING, launchTick: LAUNCH_TICK, buyRecipient: launchWallet
        });
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: Currency.wrap(address(lucid)), fee: 0, tickSpacing: SPACING, hooks: IHooks(address(hook))
        });
    }

    function test_launchLocksTheWholeSupplyInThePool() public {
        launcher.launch{value: 0.01 ether}(_params());

        (uint160 sqrtPrice, int24 tick,,) = manager.getSlot0(_key().toId());
        assertGt(sqrtPrice, 0, "pool initialized");
        assertLt(tick, LAUNCH_TICK, "the initial buy moved the price into the position");
        assertEq(hook.launchedAt(), block.timestamp, "the hook knows its birth");

        uint256 supply = lucid.totalSupply();
        uint256 inPool = lucid.balanceOf(address(manager));
        uint256 bought = lucid.balanceOf(launchWallet);
        uint256 dust = lucid.balanceOf(address(launcher));
        assertEq(inPool + bought + dust, supply, "every token is accounted for");
        assertGt(bought, 0, "the launch wallet got the initial buy");
        assertLt(dust, 1e9, "less than a billionth of a token stays in the launcher");
        assertEq(launcher.tokensInPool(), supply - dust, "100% of the supply went into the position");
        assertEq(launcher.initialBuyTokens(), bought);

        assertEq(manager.getLiquidity(_key().toId()), launcher.liquidity(), "one position, owned by the launcher");
        assertEq(address(launcher).balance, 0, "no ETH left behind");
        assertGt(platform.balance, 0, "the platform fee was paid on the initial buy");
    }

    function test_onlyTheDeployerOnlyOnce() public {
        vm.prank(trader);
        vm.expectRevert(LucidLauncher.NotDeployer.selector);
        launcher.launch(_params());

        launcher.launch(_params());
        vm.expectRevert(LucidLauncher.AlreadyLaunched.selector);
        launcher.launch(_params());
    }

    function test_rejectsMisalignedTick() public {
        LucidLauncher.LaunchParams memory p = _params();
        p.launchTick = LAUNCH_TICK + 1;
        vm.expectRevert(LucidLauncher.BadParams.selector);
        launcher.launch(p);
    }

    function test_nobodyCanTouchThePositionAfterwards() public {
        launcher.launch(_params());
        // The callback is only reachable inside its own launch.
        vm.prank(address(manager));
        vm.expectRevert(LucidLauncher.NotPoolManager.selector);
        launcher.unlockCallback(abi.encode(trader, uint256(0)));
        vm.expectRevert(LucidLauncher.NotPoolManager.selector);
        launcher.unlockCallback(abi.encode(trader, uint256(0)));
    }

    function test_theMarketTradesAfterLaunch() public {
        // A real launch always includes the initial buy (Programmable requires one), so the pool holds ETH.
        launcher.launch{value: 0.01 ether}(_params());
        // On mainnet the PoolManager is the singleton for every v4 pool and always holds ETH; the hook takes its
        // fees from it during the swap, before the swapper settles. Give the local PoolManager the same float.
        vm.deal(address(manager), address(manager).balance + 100 ether);
        vm.warp(block.timestamp + hook.FLINCH_DURATION() + 1);
        PoolKey memory key = _key();
        uint256 platformBefore = platform.balance;

        vm.prank(trader);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        uint256 got = lucid.balanceOf(trader);
        assertGt(got, 0, "buy works");
        assertEq(platform.balance - platformBefore, 0.003 ether, "0.30% of the ETH leg to the platform");

        vm.startPrank(trader);
        lucid.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(got / 2), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        vm.stopPrank();
        assertEq(lucid.balanceOf(trader), got - got / 2, "sell works");
    }
}
