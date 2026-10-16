// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {LucidHook} from "../src/LucidHook.sol";
import {LucidToken} from "../src/LucidToken.sol";

contract LucidHookTest is Deployers {
    using PoolIdLibrary for PoolKey;

    LucidHook hook;
    LucidToken lucid;
    PoolKey poolKey;

    address platform = makeAddr("programmable");
    address guardian = makeAddr("guardian");
    address agentKey = makeAddr("agent");
    address buyback = makeAddr("buyback");
    address treasury = makeAddr("treasury");
    address liq = makeAddr("liquidity");
    address trader = makeAddr("trader");
    address holder = makeAddr("holder");

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function setUp() public {
        deployFreshManagerAndRouters();
        lucid = new LucidToken(address(this), "LUCID is an AI agent that lives in its own Uniswap v4 pool.", "https://lucid.example/", "https://lucid.example/assets/lucid-logo-1024.png", "https://x.com/lucid_agent");

        address hookAddr = address(FLAGS | uint160(0xA0C0 << 144));
        deployCodeTo(
            "LucidHook.sol:LucidHook",
            abi.encode(
                IPoolManager(address(manager)), Currency.wrap(address(lucid)), platform, uint256(3_000), guardian, agentKey, buyback, treasury, liq
            ),
            hookAddr
        );
        hook = LucidHook(payable(hookAddr));

        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(lucid)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Deep full-range liquidity (~1,000 ETH / 1,000 LUCID) so tests can push real volume.
        lucid.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.deal(address(this), 5_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 1_100 ether}(
            poolKey,
            ModifyLiquidityParams({tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 1_000e18, salt: 0}),
            ZERO_BYTES
        );

        // Skip the launch flinch for fee-math tests; it has its own test.
        vm.warp(block.timestamp + hook.FLINCH_DURATION() + 1);

        vm.deal(trader, 100_000 ether);
        lucid.transfer(trader, 100_000_000e18);
        vm.prank(trader);
        lucid.approve(address(swapRouter), type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers
    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        uint256 value = 0;
        if (zeroForOne) value = amountSpecified < 0 ? uint256(-amountSpecified) : 500 ether;
        vm.prank(trader);
        return swapRouter.swap{value: value}(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev Push cumulative ETH volume past `target` with round trips (buy, then sell the same ETH back).
    function _pumpVolume(uint256 target) internal {
        while (hook.cumulativeVolumeEth() < target) {
            _swap(true, -int256(2 ether));
            _swap(false, int256(1.9 ether)); // exact-out: sell LUCID for 1.9 ETH
        }
    }

    function _fee() internal view returns (uint16) {
        return hook.effectiveFeeBps();
    }

    function _toInfant() internal {
        _pumpVolume(hook.INFANT_VOLUME());
        vm.warp(hook.launchedAt() + hook.INFANT_AGE());
        assertEq(hook.stage(), hook.INFANT());
    }

    function _toAdult() internal {
        _pumpVolume(hook.ADULT_VOLUME());
        vm.warp(hook.launchedAt() + hook.ADULT_AGE());
        assertEq(hook.stage(), hook.ADULT());
    }

    // ---------------------------------------------------------------- platform fee: set at deployment, capped
    function _deployHookWithPlatformFee(uint256 ppm, address recipient, uint160 tag) internal returns (LucidHook h) {
        address at = address(FLAGS | uint160(tag << 144));
        deployCodeTo(
            "LucidHook.sol:LucidHook",
            abi.encode(
                IPoolManager(address(manager)), Currency.wrap(address(lucid)), recipient, ppm, guardian, agentKey, buyback, treasury, liq
            ),
            at
        );
        h = LucidHook(payable(at));
    }

    function test_platformFeeIsSetAtDeployment() public {
        assertEq(hook.platformFeePpm(), 3_000);
        address other = makeAddr("programmable-v3");
        LucidHook tenBps = _deployHookWithPlatformFee(1_000, other, 0xB0C0);
        assertEq(tenBps.platformFeePpm(), 1_000);
        assertEq(tenBps.platformFeeRecipient(), other);
        (uint256 platformFee,) = tenBps.quoteFees(1 ether, true);
        assertEq(platformFee, 0.001 ether, "0.10% of the ETH leg");
        LucidHook onePct = _deployHookWithPlatformFee(10_000, other, 0xB0C1);
        (platformFee,) = onePct.quoteFees(1 ether, false);
        assertEq(platformFee, 0.01 ether, "the 1% ceiling is allowed");
    }

    function test_platformFeeZeroOrAboveCapIsRejected() public {
        vm.expectRevert(LucidHook.PlatformFeeOutOfBounds.selector);
        new LucidHook(IPoolManager(address(manager)), Currency.wrap(address(lucid)), platform, 10_001, guardian, agentKey, buyback, treasury, liq);
        vm.expectRevert(LucidHook.PlatformFeeOutOfBounds.selector);
        new LucidHook(IPoolManager(address(manager)), Currency.wrap(address(lucid)), platform, 0, guardian, agentKey, buyback, treasury, liq);
    }

    // ---------------------------------------------------------------- binding
    function test_permissionsAndBinding() public view {
        assertTrue(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(poolKey.toId()));
        assertEq(hook.stage(), hook.NEWBORN());
        assertEq(_fee(), 100);
    }

    function test_rejectsSecondPool() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 120;
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_callbacksOnlyFromPoolManager() public {
        vm.expectRevert(LucidHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), poolKey, SQRT_PRICE_1_1);
    }

    // ---------------------------------------------------------------- reflexes: fee math
    function test_buyExactIn_feesOnGrossEthInput() public {
        uint256 before = platform.balance;
        _swap(true, -int256(1 ether));
        assertEq(platform.balance - before, 0.003 ether, "platform 0.3%");
        assertEq(hook.accruedProjectFees(), 0.01 ether, "project 1%");
        assertEq(hook.cumulativeVolumeEth(), 1 ether, "volume tracked");
    }

    function test_sellExactIn_feesOnGrossEthOutput() public {
        uint256 platformBefore = platform.balance;
        uint256 traderBefore = trader.balance;
        BalanceDelta d = _swap(false, -int256(1_000e18));
        uint256 platformFee = platform.balance - platformBefore;
        uint256 projectFee = hook.accruedProjectFees();
        uint256 gross = uint256(uint128(d.amount0())) + platformFee + projectFee;
        assertEq(platformFee, gross * 3_000 / 1_000_000);
        assertEq(projectFee, gross * 100 / 10_000);
        assertEq(trader.balance - traderBefore, gross - platformFee - projectFee);
    }

    function test_buyExactOut_and_sellExactOut_charge() public {
        uint256 before = platform.balance;
        _swap(true, int256(1e18));
        assertGt(platform.balance - before, 0);
        before = platform.balance;
        uint256 accrued = hook.accruedProjectFees();
        _swap(false, int256(0.5 ether));
        assertEq(platform.balance - before, 0.5 ether * 3_000 / 1_000_000);
        assertEq(hook.accruedProjectFees() - accrued, 0.5 ether * 100 / 10_000);
    }

    function test_launchFlinchDecays() public {
        vm.warp(hook.launchedAt());
        assertEq(hook.currentBuyFeeBps(), 100 + 900);
        vm.warp(hook.launchedAt() + hook.FLINCH_DURATION() / 2);
        assertEq(hook.currentBuyFeeBps(), 100 + 450);
        vm.warp(hook.launchedAt() + hook.FLINCH_DURATION());
        assertEq(hook.currentBuyFeeBps(), 100);
        assertEq(hook.currentSellFeeBps(), 100);
    }

    function test_distributeDefaultNightBurns() public {
        _swap(true, -int256(10 ether));
        assertEq(hook.accruedProjectFees(), 0.1 ether);
        hook.distribute();
        assertEq(buyback.balance, 0.06 ether, "60% mood pot burns by default");
        assertEq(treasury.balance, 0.03 ether);
        assertEq(liq.balance, 0);
        assertEq(hook.synapsePool(), 0.01 ether);
    }

    function test_nightRewardKeepsMoodPotForSynapses() public {
        uint8 reward = hook.NIGHT_REWARD();
        vm.prank(agentKey);
        hook.setNightAction(reward, keccak256("a tender dream"));
        _swap(true, -int256(10 ether));
        hook.distribute();
        assertEq(buyback.balance, 0);
        assertEq(hook.synapsePool(), 0.07 ether, "60% + 10% stay for synapses");
        assertEq(address(hook).balance, 0.07 ether);
    }

    function test_nightSwitchSettlesFeesEarnedUnderThePreviousNight() public {
        // Fees earned while the night was "burn" must burn, even though the new vote says "reward".
        _swap(true, -int256(10 ether)); // 0.1 ETH project fee under burn (the default)
        uint8 reward = hook.NIGHT_REWARD();
        vm.prank(agentKey);
        hook.setNightAction(reward, keccak256("a serene dream"));
        assertEq(hook.accruedProjectFees(), 0, "settled at the switch");
        assertEq(buyback.balance, 0.06 ether, "old fees followed the old night");
        assertEq(hook.synapsePool(), 0.01 ether);
        // New fees follow the new night.
        _swap(true, -int256(10 ether));
        hook.distribute();
        assertEq(buyback.balance, 0.06 ether, "nothing new burnt");
        assertEq(hook.synapsePool(), 0.08 ether, "0.01 + 60% + 10% of the new fees");
    }

    function test_distributeJustBeforeSwitchGainsNothing() public {
        _swap(true, -int256(10 ether));
        hook.distribute(); // a front-runner distributes first: same result as the switch itself
        uint256 burnt = buyback.balance;
        uint8 deepen = hook.NIGHT_DEEPEN();
        vm.prank(agentKey);
        hook.setNightAction(deepen, keccak256("an epic dream"));
        assertEq(burnt, 0.06 ether);
        assertEq(liq.balance, 0, "earlier fees never reach the new route");
    }

    function test_nightDeepenFeedsLiquidity() public {
        uint8 deepen = hook.NIGHT_DEEPEN();
        vm.prank(agentKey);
        hook.setNightAction(deepen, keccak256("an epic dream"));
        _swap(true, -int256(10 ether));
        hook.distribute();
        assertEq(liq.balance, 0.06 ether);
        assertEq(buyback.balance, 0);
    }

    function test_nightActionOncePerNightAndBounded() public {
        vm.startPrank(agentKey);
        vm.expectRevert(LucidHook.BadAction.selector);
        hook.setNightAction(3, bytes32(0));
        hook.setNightAction(1, bytes32("d1"));
        vm.expectRevert(LucidHook.CooldownActive.selector);
        hook.setNightAction(2, bytes32("d2"));
        vm.warp(block.timestamp + 20 hours);
        hook.setNightAction(2, bytes32("d2"));
        vm.stopPrank();
        assertEq(hook.nightAction(), 2);
        vm.prank(trader);
        vm.expectRevert(LucidHook.NotAgent.selector);
        hook.setNightAction(0, bytes32(0));
    }

    // ---------------------------------------------------------------- growth stages
    function test_newbornIsLocked() public {
        vm.prank(agentKey);
        vm.expectRevert(LucidHook.StageLocked.selector);
        hook.setPolicy(110, bytes32(0));
    }

    function test_ageAloneDoesNotGrowTheMind() public {
        vm.warp(hook.launchedAt() + 365 days);
        assertEq(hook.stage(), hook.NEWBORN(), "no volume, no growth");
    }

    function test_volumeAloneDoesNotGrowTheMind() public {
        _pumpVolume(hook.INFANT_VOLUME());
        assertEq(hook.stage(), hook.NEWBORN(), "too young");
    }

    function test_infantBounds() public {
        _toInfant();
        vm.startPrank(agentKey);
        vm.expectRevert(LucidHook.StepTooLarge.selector);
        hook.setPolicy(150, bytes32(0)); // +50 > step 25
        hook.setPolicy(125, keccak256("calm market, lowering friction? no: raising vs bots"));
        assertEq(_fee(), 125);
        vm.expectRevert(LucidHook.CooldownActive.selector);
        hook.setPolicy(150, bytes32(0));
        vm.warp(block.timestamp + 6 hours);
        hook.setPolicy(150, bytes32(0));
        vm.warp(block.timestamp + 6 hours);
        vm.expectRevert(LucidHook.FeeOutOfBounds.selector);
        hook.setPolicy(175, bytes32(0)); // infant ceiling 150
        vm.stopPrank();
    }

    function test_adultReachesFullRange() public {
        _toAdult();
        vm.startPrank(agentKey);
        uint16[5] memory path = [uint16(150), 200, 250, 300, 300];
        for (uint256 i = 0; i < 4; i++) {
            hook.setPolicy(path[i], bytes32(i));
            vm.warp(block.timestamp + 1 hours);
        }
        assertEq(_fee(), 300);
        vm.expectRevert(LucidHook.FeeOutOfBounds.selector);
        hook.setPolicy(350, bytes32(0));
        vm.stopPrank();
    }

    function test_groundingDropsOneStageAndClampsFee() public {
        _toAdult();
        vm.startPrank(agentKey);
        hook.setPolicy(150, bytes32(0));
        vm.warp(block.timestamp + 1 hours);
        hook.setPolicy(200, bytes32(0));
        vm.stopPrank();
        assertEq(_fee(), 200);

        vm.prank(guardian);
        hook.safeMode();
        assertEq(hook.stage(), hook.CHILD(), "grounded: acts one stage younger");
        assertEq(_fee(), 100, "fee reset");

        vm.warp(block.timestamp + 14 days);
        assertEq(hook.stage(), hook.ADULT(), "grounding expires");
    }

    function test_groundedInfantFeeClampedToNewborn() public {
        _toInfant();
        vm.prank(agentKey);
        hook.setPolicy(125, bytes32(0));
        // Agent goes silent; anyone can ground it after 7 days.
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(trader);
        hook.safeMode();
        assertEq(hook.stage(), hook.NEWBORN());
        assertEq(_fee(), 100);
        vm.prank(agentKey);
        vm.expectRevert(LucidHook.StageLocked.selector);
        hook.setPolicy(110, bytes32(0));
    }

    function test_deadManSwitchNeedsSilence() public {
        vm.prank(agentKey);
        hook.dream(keccak256("dream #1"));
        vm.prank(trader);
        vm.expectRevert(LucidHook.AgentNotStale.selector);
        hook.safeMode();
    }

    function test_onlyAgentActs() public {
        vm.startPrank(trader);
        vm.expectRevert(LucidHook.NotAgent.selector);
        hook.setPolicy(100, bytes32(0));
        vm.expectRevert(LucidHook.NotAgent.selector);
        hook.dream(bytes32(0));
        vm.expectRevert(LucidHook.NotAgent.selector);
        hook.rewardSynapse(trader, 1, bytes32(0));
        vm.stopPrank();
    }

    function test_guardianRotatesAgent() public {
        address newAgent = makeAddr("agent2");
        vm.prank(guardian);
        hook.setAgent(newAgent);
        vm.prank(newAgent);
        hook.dream(bytes32("ok"));
        vm.prank(agentKey);
        vm.expectRevert(LucidHook.NotAgent.selector);
        hook.dream(bytes32("no"));
    }

    // ---------------------------------------------------------------- synapses
    function test_synapseRewardAndCaps() public {
        _swap(true, -int256(100 ether)); // 1 ETH project fee
        hook.distribute(); // 0.1 ETH synapse pool (night = burn)
        uint256 pool = hook.synapsePool();
        assertEq(pool, 0.1 ether);

        vm.startPrank(agentKey);
        vm.expectRevert(LucidHook.SynapseCapExceeded.selector);
        hook.rewardSynapse(holder, pool / 10 + 1, keccak256("idea-1")); // > 10% per payment

        hook.rewardSynapse(holder, pool / 10, keccak256("idea-1"));
        assertEq(holder.balance, 0.01 ether);
        assertEq(hook.synapseWeight(holder), 1);

        hook.rewardSynapse(holder, hook.synapsePool() / 10, keccak256("idea-2"));
        // day budget = 25% of 0.1 = 0.025; spent 0.01 + 0.009 = 0.019; next 0.0081 would exceed
        uint256 next = hook.synapsePool() / 10;
        vm.expectRevert(LucidHook.SynapseCapExceeded.selector);
        hook.rewardSynapse(holder, next, keccak256("idea-3"));

        vm.warp(block.timestamp + 1 days); // new day, new budget
        hook.rewardSynapse(holder, next, keccak256("idea-3"));
        vm.stopPrank();
        assertEq(hook.synapseWeight(holder), 3);
    }

    // ---------------------------------------------------------------- fuzz
    function testFuzz_platformFeeIsFloor3000ppm(uint96 ethIn) public {
        ethIn = uint96(bound(ethIn, 0.001 ether, 50 ether));
        uint256 before = platform.balance;
        _swap(true, -int256(uint256(ethIn)));
        assertEq(platform.balance - before, uint256(ethIn) * 3_000 / 1_000_000);
    }
}
