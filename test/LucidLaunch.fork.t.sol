// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {LucidToken} from "../src/LucidToken.sol";
import {LucidHook} from "../src/LucidHook.sol";
import {LucidLauncher} from "../src/LucidLauncher.sol";
import {LucidLaunchBuilder} from "../script/LucidLaunchBuilder.sol";
import {IProgrammableLaunchStampRouter as R} from "../script/programmable/ProgrammableTypes.sol";

/// @notice The whole LUCID launch through Programmable's real Router, Graph Factory and PoolManager on a mainnet
///         fork. Only the permit authority's EIP-1271 answer is mocked (that signature is Programmable's to give).
///         Run with: ETH_RPC_URL=<mainnet rpc> forge test --match-contract LucidLaunchForkTest -vv
contract LucidLaunchForkTest is Test, LucidLaunchBuilder {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant ROUTER = 0x8622DD5bAb44185f2A458ac90384Ac99248f8d56;
    address constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da; // bundle README recipient, 30 bps

    address launchWallet = makeAddr("lucid-launch-wallet");
    address trader = makeAddr("lucid-trader");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        vm.deal(launchWallet, 1 ether);
        vm.deal(trader, 10 ether);
    }

    function _config() internal returns (LaunchConfig memory c) {
        c = LaunchConfig({
            router: ROUTER,
            launchWallet: launchWallet,
            guardian: makeAddr("guardian-safe"),
            agent: makeAddr("agent-key"),
            buybackVault: makeAddr("buyback-safe"),
            treasury: makeAddr("treasury-safe"),
            liquidityVault: makeAddr("liquidity-safe"),
            platformFeeRecipient: PLATFORM,
            platformFeePpm: 3_000,
            launchTick: 196_200,
            initialBuyWei: 0.001 ether,
            routeNamespace: keccak256(abi.encode("lucid.fork-test", block.number)),
            routeNonce: keccak256(abi.encode("lucid.nonce", block.number)),
            launchId: keccak256(abi.encode("lucid.launch", block.number)),
            validAfter: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 50 minutes),
            tokenDescription: "LUCID is an AI agent that lives in its own Uniswap v4 pool.",
            tokenWebsite: "https://lucid.example/",
            tokenImage: "https://lucid.example/assets/lucid-logo-1024.png",
            tokenX: "https://x.com/lucid_agent"
        });
    }

    function test_fork_fullLaunchThroughProgrammableRouter() public {
        if (!forked) return; // needs ETH_RPC_URL
        LaunchConfig memory c = _config();
        PreparedLaunch memory L = _prepareLaunch(c);

        // Programmable's authority would sign permitDigest; on the fork its EIP-1271 check is mocked.
        address authority = R(ROUTER).PERMIT_AUTHORITY();
        vm.mockCall(authority, abi.encodeWithSelector(bytes4(0x1626ba7e), L.permitDigest), abi.encode(bytes4(0x1626ba7e)));

        vm.prank(launchWallet);
        uint256 gasBefore = gasleft();
        bytes32 stampHash = R(ROUTER).launchAndStampV1{value: c.initialBuyWei}(L.permit, L.stampRequest, L.routePayload, hex"01");
        emit log_named_uint("launch tx gas (execution)", gasBefore - gasleft());
        emit log_named_uint("calldata bytes", L.routePayload.length);
        assertTrue(stampHash != bytes32(0), "stamped");

        // The stamp
        assertEq(R(ROUTER).launchIdByToken(L.token), c.launchId, "token is stamped to this launch");
        R.StampRecordV1 memory s = R(ROUTER).launchStamp(c.launchId);
        assertEq(s.token, L.token);
        assertEq(s.hook, L.hook);
        assertEq(s.launchWallet, launchWallet);

        // The fair launch: everything is in the pool except the initial buy and sub-unit dust
        LucidToken token = LucidToken(L.token);
        IPoolManager pm = IPoolManager(R(ROUTER).POOL_MANAGER());
        uint256 supply = token.totalSupply();
        uint256 bought = token.balanceOf(launchWallet);
        uint256 dust = token.balanceOf(L.launcher);
        assertGt(bought, 0, "initial buy delivered to the launch wallet");
        assertLt(dust, 1e9, "dust only");
        assertEq(LucidLauncher(payable(L.launcher)).tokensInPool(), supply - dust, "100% of the supply was placed");
        assertEq(token.balanceOf(address(pm)) + bought + dust, supply, "nobody else holds LUCID");
        assertEq(LucidHook(payable(L.hook)).platformFeePpm(), 3_000);

        // The market works through the standard swap path afterwards, and pays the platform fee
        vm.warp(block.timestamp + 16 minutes); // past the launch flinch
        PoolSwapTest swapper = new PoolSwapTest(pm);
        uint256 platformBefore = PLATFORM.balance;
        vm.prank(trader);
        swapper.swap{value: 1 ether}(
            L.stampRequest.poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertGt(token.balanceOf(trader), 0, "a buy after launch");
        assertEq(PLATFORM.balance - platformBefore, 0.003 ether, "0.30% to Programmable inside the swap");

        emit log_named_address("launcher", L.launcher);
        emit log_named_address("token   ", L.token);
        emit log_named_address("hook    ", L.hook);
        emit log_named_bytes32("hook salt", L.hookApplicantSalt);
        emit log_named_bytes32("permit digest", L.permitDigest);
        emit log_named_uint("tokens in pool", LucidLauncher(payable(L.launcher)).tokensInPool());
        emit log_named_uint("initial buy tokens", bought);
    }

    function test_fork_permitWithoutAuthoritySignatureIsRejected() public {
        if (!forked) return;
        LaunchConfig memory c = _config();
        PreparedLaunch memory L = _prepareLaunch(c);
        vm.prank(launchWallet);
        vm.expectRevert();
        R(ROUTER).launchAndStampV1{value: c.initialBuyWei}(L.permit, L.stampRequest, L.routePayload, hex"01");
    }
}
