// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {LucidVault} from "../src/LucidVault.sol";

interface IProtectedToken {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function walletTokenLimit() external view returns (uint256);
    function startedAt() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IProtectedHook {
    function poolKey() external view returns (PoolKey memory);
    function feeVault() external view returns (address);
    function openingTaxVault() external view returns (address);
    function module() external view returns (address);
    function creatorBuyFeeBps() external view returns (uint16);
}

interface IProtectedInitializer {
    function initialize(address hook, address token, int24 startTick, address buyer, uint256 minTokenOut) external payable;
    function openingFdvUsd() external view returns (uint256);
    function lockedLiquidity() external view returns (uint128);
}

interface IFeeVault {
    function creatorAccrued() external view returns (uint256);
    function platformAccrued() external view returns (uint256);
    function creatorRecipient() external view returns (address);
    function claimCreator() external returns (uint256);
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice LUCID on Programmable's mandatory launch-protection package v1 (CLI 4.1.7), on a mainnet fork:
///         the exact published creation bytecode of the initializer, token and hook, with LucidVault as the
///         immutable creator-fee recipient. Run: ETH_RPC_URL=<rpc> forge test --match-contract LucidProtectedLaunchForkTest -vv
contract LucidProtectedLaunchForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    bytes32 constant FEED_HASH = 0x4b79b5c8aee6da0f7b393e8b53e6265ef7320a1d16184c65bd3841b5aa3d700d;
    address constant ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    bytes32 constant ROUTER_HASH = 0x41ccd905c8e4de29ce9536ff49233b79e3085a0987d490664e703ee1e7b1dc49;
    address constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint16 constant CREATOR_BPS = 200;

    address dev = makeAddr("lucid-dev");
    address trader = makeAddr("lucid-trader");
    address guardian = makeAddr("guardian-safe");
    address agent = makeAddr("agent");
    bool forked;

    IProtectedInitializer initializer;
    IProtectedToken token;
    IProtectedHook hook;
    LucidVault vault;
    int24 startTick;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        vm.deal(dev, 1 ether);
        vm.deal(trader, 10 ether);
    }

    function _code(string memory name) internal view returns (bytes memory) {
        string memory json = vm.readFile(string.concat("test/fixtures/launch-protection/", name, ".artifact.json"));
        return vm.parseJsonBytes(json, ".creationBytecode");
    }

    function _deploy(bytes memory initCode) internal returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(a != address(0), "deploy failed");
    }

    /// @dev Highest 60-aligned tick whose opening FDV is still >= $15,000 (same search as the package helper).
    function _tickFor15k() internal view returns (int24) {
        (, int256 answer,,,) = IFeed(FEED).latestRoundData();
        int256 lo = -14786;
        int256 hi = 14786;
        while (lo < hi) {
            int256 mid = (lo + hi + 1) / 2;
            if (_fdvUsd(int24(mid * 60), uint256(answer)) >= 15_000) lo = mid;
            else hi = mid - 1;
        }
        return int24(lo * 60);
    }

    function _fdvUsd(int24 tick, uint256 answer) internal pure returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint256 nativeValue = FullMath.mulDiv(uint256(1) << 192, SUPPLY, uint256(sqrtP) * sqrtP);
        return FullMath.mulDiv(nativeValue, answer, 1 ether * 1e8);
    }

    function _launch(uint256 initialBuy) internal {
        initializer = IProtectedInitializer(_deploy(abi.encodePacked(
            _code("ProtectedNativeInitializerV1"), abi.encode(PM, address(this), FEED, FEED_HASH)
        )));
        token = IProtectedToken(_deploy(abi.encodePacked(
            _code("ProtectedLaunchTokenV1"), abi.encode("LUCID", "LUCID", SUPPLY, address(initializer), PM)
        )));
        vault = new LucidVault(guardian, agent, makeAddr("lucid-fork-buyback-vault"), makeAddr("lucid-fork-treasury-vault"), makeAddr("lucid-fork-liquidity-vault"));
        startTick = _tickFor15k();

        bytes memory hookInit = abi.encodePacked(_code("ProtectedNative30HookV1"), _hookArgs());
        bytes32 initHash = keccak256(hookInit);
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            address predicted = vm.computeCreate2Address(salt, initHash, address(this));
            if (uint160(predicted) & 0x3fff == 0x20cc) break;
        }
        address h;
        assembly ("memory-safe") {
            h := create2(0, add(hookInit, 0x20), mload(hookInit), salt)
        }
        require(h != address(0), "hook deploy failed");
        hook = IProtectedHook(h);

        vm.deal(address(this), initialBuy);
        initializer.initialize{value: initialBuy}(address(hook), address(token), startTick, dev, 1);
    }

    struct PoolConfig {
        address token;
        uint24 lpFee;
        int24 tickSpacing;
        uint160 initialSqrtPriceX96;
        address initializer;
        address creatorFeeRecipient;
        uint16 creatorBuyFeeBps;
        uint16 creatorSellFeeBps;
        address module;
        uint24 maxModuleLpFeePips;
    }

    function _hookArgs() internal view returns (bytes memory) {
        PoolConfig memory c = PoolConfig({
            token: address(token),
            lpFee: 0,
            tickSpacing: 60,
            initialSqrtPriceX96: TickMath.getSqrtPriceAtTick(startTick),
            initializer: address(initializer),
            creatorFeeRecipient: address(vault),
            creatorBuyFeeBps: CREATOR_BPS,
            creatorSellFeeBps: CREATOR_BPS,
            module: address(0),
            maxModuleLpFeePips: 0
        });
        address[6] memory exempt;
        return abi.encode(PM, c, dev, ROUTER, ROUTER_HASH, exempt);
    }

    function _buy(address who, uint256 amount) internal returns (uint256 got) {
        PoolSwapTest swapper = new PoolSwapTest(PM);
        uint256 before = token.balanceOf(who);
        PoolKey memory key = hook.poolKey();
        vm.prank(who);
        swapper.swap{value: amount}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        got = token.balanceOf(who) - before;
    }

    function test_fork_protectedLaunchAndVaultFeeFlow() public {
        if (!forked) return;
        _launch(0.03 ether);

        // Opening valuation and the fair launch
        uint256 fdv = initializer.openingFdvUsd();
        emit log_named_uint("opening FDV (USD)", fdv);
        emit log_named_int("start tick", startTick);
        assertGe(fdv, 15_000, "USD floor");
        assertLt(fdv, 15_300, "opened at the minimum valuation");
        uint256 devTokens = token.balanceOf(dev);
        emit log_named_uint("initial buy tokens (0.03 ETH)", devTokens / 1e18);
        assertGt(devTokens, 0);
        assertLe(devTokens, token.walletTokenLimit(), "initial buy within the 2% limit");
        assertApproxEqAbs(token.balanceOf(address(PM)) + devTokens, SUPPLY, 1e6, "everything else is in the pool (rounding dust only)");
        assertGt(initializer.lockedLiquidity(), 0);

        // Fee plumbing points at LUCID
        IFeeVault fees = IFeeVault(hook.feeVault());
        assertEq(fees.creatorRecipient(), address(vault), "creator fees go to the LUCID Vault");
        assertEq(hook.creatorBuyFeeBps(), CREATOR_BPS);

        // During the 300-second protection window only the canonical router may buy
        vm.expectRevert(); // PoolManager WrappedError(hook, beforeSwap, UnsupportedRouter())
        this.externalBuy(trader, 0.1 ether);

        // After the window, an ordinary buy and sell
        vm.warp(block.timestamp + 301);
        uint256 got = _buy(trader, 1 ether);
        assertGt(got, 0, "buy after protection");
        emit log_named_uint("1 ETH buys (tokens)", got / 1e18);

        uint256 creatorBefore = fees.creatorAccrued();
        uint256 platformBefore = fees.platformAccrued();
        emit log_named_uint("creator fees accrued (wei)", creatorBefore);
        emit log_named_uint("platform fees accrued (wei)", platformBefore);
        // Initial 0.03 ETH buy + 1 ETH buy: platform 0.30% of 1.03 ETH, creator 2% of 1.03 ETH (each rounded up per trade)
        assertApproxEqAbs(platformBefore, 0.00309 ether, 1e9, "platform 0.30%");
        assertApproxEqAbs(creatorBefore, 0.0206 ether, 1e9, "creator 2%");

        // Anyone pushes creator fees to the vault; the vault routes them
        uint256 claimed = fees.claimCreator();
        assertEq(address(vault).balance, claimed, "vault received the creator fees");
        vault.distribute();
        assertEq(makeAddr("lucid-fork-treasury-vault").balance, claimed * 3000 / 10_000, "30% treasury");
        assertEq(makeAddr("lucid-fork-buyback-vault").balance, claimed * 6000 / 10_000, "60% mood pot to buyback (default BURN)");
        assertEq(vault.synapsePool(), claimed - claimed * 3000 / 10_000 - claimed * 6000 / 10_000, "10% synapse");
    }

    function test_fork_initialBuyAbove2PercentReverts() public {
        if (!forked) return;
        vm.expectRevert();
        this.externalLaunch(3 ether);
    }

    function externalBuy(address who, uint256 amount) external returns (uint256) {
        return _buy(who, amount);
    }

    function externalLaunch(uint256 amount) external {
        _launch(amount);
    }
}
