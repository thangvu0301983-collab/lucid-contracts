// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {LucidToken} from "../src/LucidToken.sol";
import {LucidHook} from "../src/LucidHook.sol";
import {LucidLauncher} from "../src/LucidLauncher.sol";
import {IProgrammableGraphFactory as F, IProgrammableLaunchStampRouter as R} from "./programmable/ProgrammableTypes.sol";

/// @notice Builds LUCID's Programmable CustomGraph launch, exactly as the canonical Router will execute it:
///           target 0  LucidLauncher(poolManager)                       kind Other, initializer: launch(...)
///           target 1  LucidToken(launcher)        mints 100% to it      kind Token
///           target 2  LucidHook(token, fee config, recipients)          kind Hook, salt mined for its flag bits
///         Addresses follow the Graph Factory's formula (verified against its own predictTarget on a fork):
///           effectiveSalt = keccak256(abi.encode(TARGET_SALT_TYPEHASH, chainId, factory, routeNamespace,
///                                                routeNonce, targetIdHash, applicantSalt, authorizedLauncher))
///           address       = CREATE2(factory, effectiveSalt, keccak256(initCode))
///         The graph is simulated once on a mainnet fork (pranking the Router as the authorized launcher) to read
///         the post-initialization runtime hashes and the graph deployment hash, then everything is bound into the
///         StampRequestV1 and LaunchPermitV1 that Programmable's permit authority signs.
abstract contract LucidLaunchBuilder is CommonBase {
    bytes32 internal constant TARGET_SALT_TYPEHASH = keccak256(
        "ProgrammableCreate2GraphTargetSaltV1(uint256 chainId,address factory,bytes32 routeNamespace,bytes32 routeNonce,bytes32 targetIdHash,bytes32 applicantSalt,address authorizedLauncher)"
    );
    bytes32 internal constant EXPECTED_GRAPH_OUTPUT_TYPEHASH = keccak256(
        "ProgrammableExpectedGraphOutputV1(uint8 targetIndex,bytes32 targetIdHash,address account,bytes32 runtimeCodeHash)"
    );
    bytes32 internal constant EXPECTED_GRAPH_RESULT_TYPEHASH =
        keccak256("ProgrammableExpectedGraphResultV1(bytes32 expectedOutputsHash,bytes32 graphDeploymentHash)");

    bytes32 internal constant LAUNCHER_ID = keccak256("lucid.launcher.v1");
    bytes32 internal constant TOKEN_ID = keccak256("lucid.token.v1");
    bytes32 internal constant HOOK_ID = keccak256("lucid.hook.v1");
    bytes32 internal constant TOPOLOGY = keccak256(
        "LUCID CustomGraph v1: [0] LucidLauncher(poolManager); [1] LucidToken(launcher); [2] LucidHook(token,...); init [0].launch(token, hook)"
    );
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    struct LaunchConfig {
        address router;
        address launchWallet; // sends the launch transaction and receives the initial buy
        address guardian;
        address agent;
        address buybackVault;
        address treasury;
        address liquidityVault;
        address platformFeeRecipient;
        uint256 platformFeePpm;
        int24 launchTick; // multiple of 60; price = 1.0001^launchTick LUCID per ETH
        uint256 initialBuyWei;
        bytes32 routeNamespace;
        bytes32 routeNonce; // = permit.nonce, single use
        bytes32 launchId;
        uint64 validAfter;
        uint64 deadline; // validAfter + at most 1 hour
        string tokenDescription; // fixed in the token forever (it has no owner)
        string tokenWebsite;
        string tokenImage;
        string tokenX;
    }

    struct PreparedLaunch {
        R.LaunchPermitV1 permit;
        R.StampRequestV1 stampRequest;
        R.CustomGraphRouteV1 route;
        bytes routePayload;
        bytes32 permitDigest;
        address launcher;
        address token;
        address hook;
        bytes32 hookApplicantSalt;
    }

    function _effectiveSalt(LaunchConfig memory c, address factory, bytes32 targetId, bytes32 applicantSalt) internal view returns (bytes32) {
        return keccak256(abi.encode(TARGET_SALT_TYPEHASH, block.chainid, factory, c.routeNamespace, c.routeNonce, targetId, applicantSalt, c.router));
    }

    function _create2(address factory, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash)))));
    }

    function _hookInitCode(LaunchConfig memory c, IPoolManager pm, address token) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(LucidHook).creationCode,
            abi.encode(pm, Currency.wrap(token), c.platformFeeRecipient, c.platformFeePpm, c.guardian, c.agent, c.buybackVault, c.treasury, c.liquidityVault)
        );
    }

    /// @notice Everything up to the graph commitment (no simulation): targets, addresses, mined hook salt.
    function _buildTargets(LaunchConfig memory c)
        internal
        view
        returns (F.Target[] memory targets, address launcher, address token, address hook, bytes32 hookSalt)
    {
        address factory = R(c.router).GRAPH_FACTORY();
        IPoolManager pm = IPoolManager(R(c.router).POOL_MANAGER());
        require(F(factory).TARGET_SALT_TYPEHASH() == TARGET_SALT_TYPEHASH, "factory salt formula changed");
        targets = new F.Target[](3);

        bytes memory launcherInit = abi.encodePacked(type(LucidLauncher).creationCode, abi.encode(pm));
        launcher = _create2(factory, _effectiveSalt(c, factory, LAUNCHER_ID, bytes32(0)), keccak256(launcherInit));
        bytes memory tokenInit = abi.encodePacked(
            type(LucidToken).creationCode,
            abi.encode(launcher, c.tokenDescription, c.tokenWebsite, c.tokenImage, c.tokenX)
        );
        token = _create2(factory, _effectiveSalt(c, factory, TOKEN_ID, bytes32(0)), keccak256(tokenInit));
        targets[1] = F.Target({targetIdHash: TOKEN_ID, applicantSalt: bytes32(0), deploymentValue: 0, initializerValue: 0, initCode: tokenInit, initializerCalldata: ""});

        bytes memory hookInit = _hookInitCode(c, pm, token);
        (hook, hookSalt) = _mineHook(c, factory, keccak256(hookInit));
        targets[2] = F.Target({targetIdHash: HOOK_ID, applicantSalt: hookSalt, deploymentValue: 0, initializerValue: 0, initCode: hookInit, initializerCalldata: ""});

        targets[0] = F.Target({
            targetIdHash: LAUNCHER_ID,
            applicantSalt: bytes32(0),
            deploymentValue: 0,
            initializerValue: c.initialBuyWei,
            initCode: launcherInit,
            initializerCalldata: abi.encodeCall(
                LucidLauncher.launch,
                (LucidLauncher.LaunchParams({token: token, hook: hook, tickSpacing: TICK_SPACING, launchTick: c.launchTick, buyRecipient: c.launchWallet}))
            )
        });
    }

    /// @dev Mines the applicant salt so the hook's address carries exactly its permission bits.
    function _mineHook(LaunchConfig memory c, address factory, bytes32 initHash) internal view returns (address hook, bytes32 salt) {
        uint256 freePtr;
        assembly ("memory-safe") {
            freePtr := mload(0x40)
        }
        for (uint256 i; i < 2_000_000; ++i) {
            salt = bytes32(i);
            hook = _create2(factory, _effectiveSalt(c, factory, HOOK_ID, salt), initHash);
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && hook.code.length == 0) return (hook, salt);
            // Each try abi-encodes scratch data; release it so a long search cannot run out of memory.
            assembly ("memory-safe") {
                mstore(0x40, freePtr)
            }
        }
        revert("hook salt not found");
    }

    function _authorization(LaunchConfig memory c, bytes32 commitment) internal pure returns (F.GraphAuthorization memory) {
        return F.GraphAuthorization({
            routeNamespace: c.routeNamespace,
            routeNonce: c.routeNonce,
            topologyHash: TOPOLOGY,
            graphCommitment: commitment,
            authorizedLauncher: c.router,
            totalValue: c.initialBuyWei
        });
    }

    /// @notice Builds and fork-simulates the whole launch, returning the exact tuples to submit for authorization.
    function _prepareLaunch(LaunchConfig memory c) internal returns (PreparedLaunch memory out) {
        require(c.deadline > c.validAfter && c.deadline - c.validAfter <= 1 hours, "permit window must be <= 1 hour");
        require(c.launchTick % TICK_SPACING == 0, "launch tick must be a multiple of 60");
        F.Target[] memory targets;
        (targets, out.launcher, out.token, out.hook, out.hookApplicantSalt) = _buildTargets(c);
        F.GraphAuthorization memory auth = _checkedAuthorization(c, targets, out);
        (address[] memory deployed, bytes32[] memory runtimeHashes, bytes32 graphDeploymentHash) = _simulate(c, auth, targets, out);
        bytes32 outputsHash = _bindRoute(out, c, auth.graphCommitment, targets, deployed, runtimeHashes, graphDeploymentHash);
        _bindStamp(out, c, deployed, runtimeHashes);
        _bindPermit(out, c, outputsHash, graphDeploymentHash);
    }

    function _checkedAuthorization(LaunchConfig memory c, F.Target[] memory targets, PreparedLaunch memory out)
        internal
        view
        returns (F.GraphAuthorization memory auth)
    {
        F factory = F(R(c.router).GRAPH_FACTORY());
        (bytes32 commitment, uint256 valueSum) = factory.computeGraphCommitment(_authorization(c, bytes32(0)), targets);
        require(valueSum == c.initialBuyWei, "value sum");
        auth = _authorization(c, commitment);
        require(factory.predictTarget(auth, targets[0]) == out.launcher, "launcher prediction mismatch with the live factory");
        require(factory.predictTarget(auth, targets[1]) == out.token, "token prediction mismatch with the live factory");
        require(factory.predictTarget(auth, targets[2]) == out.hook, "hook prediction mismatch with the live factory");
    }

    /// @dev Runs the graph exactly as the Router will (the Router is the authorized launcher), then rolls back.
    function _simulate(LaunchConfig memory c, F.GraphAuthorization memory auth, F.Target[] memory targets, PreparedLaunch memory out)
        internal
        returns (address[] memory deployed, bytes32[] memory runtimeHashes, bytes32 graphDeploymentHash)
    {
        F factory = F(R(c.router).GRAPH_FACTORY());
        uint256 snap = vm.snapshotState();
        vm.deal(c.router, c.router.balance + c.initialBuyWei);
        vm.prank(c.router);
        (deployed, runtimeHashes,, graphDeploymentHash) = factory.deployGraph{value: c.initialBuyWei}(auth, targets);
        vm.revertToState(snap);
        require(deployed[0] == out.launcher && deployed[1] == out.token && deployed[2] == out.hook, "simulated addresses");
    }

    function _bindRoute(
        PreparedLaunch memory out,
        LaunchConfig memory c,
        bytes32 commitment,
        F.Target[] memory targets,
        address[] memory deployed,
        bytes32[] memory runtimeHashes,
        bytes32 graphDeploymentHash
    ) internal pure returns (bytes32 outputsHash) {
        R.ExpectedGraphOutputV1[] memory outputs = new R.ExpectedGraphOutputV1[](3);
        bytes32[] memory outputHashes = new bytes32[](3);
        for (uint8 i; i < 3; ++i) {
            outputs[i] = R.ExpectedGraphOutputV1({targetIndex: i, targetIdHash: targets[i].targetIdHash, account: deployed[i], runtimeCodeHash: runtimeHashes[i]});
            outputHashes[i] = keccak256(abi.encode(EXPECTED_GRAPH_OUTPUT_TYPEHASH, i, targets[i].targetIdHash, deployed[i], runtimeHashes[i]));
        }
        out.route = R.CustomGraphRouteV1({
            routeNamespace: c.routeNamespace,
            routeNonce: c.routeNonce,
            topologyHash: TOPOLOGY,
            graphCommitment: commitment,
            targets: targets,
            expectedOutputs: outputs,
            expectedGraphDeploymentHash: graphDeploymentHash
        });
        out.routePayload = abi.encode(out.route);
        outputsHash = keccak256(abi.encodePacked(outputHashes));
    }

    /// @dev Components are sorted by address and point back to their target by resultIndex.
    function _bindStamp(PreparedLaunch memory out, LaunchConfig memory c, address[] memory deployed, bytes32[] memory runtimeHashes) internal pure {
        R.ComponentKindV1[3] memory kinds = [R.ComponentKindV1.Other, R.ComponentKindV1.Token, R.ComponentKindV1.Hook];
        uint8[3] memory order = _sortByAddress(deployed);
        R.ComponentV1[] memory components = new R.ComponentV1[](3);
        for (uint256 j; j < 3; ++j) {
            uint8 t = order[j];
            components[j] = R.ComponentV1({resultIndex: t, account: deployed[t], runtimeCodeHash: runtimeHashes[t], kind: kinds[t], scope: R.ComponentScopeV1.Exclusive});
        }
        out.stampRequest = R.StampRequestV1({
            launchId: c.launchId,
            token: out.token,
            tokenRuntimeCodeHash: runtimeHashes[1],
            poolKey: PoolKey({currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: Currency.wrap(out.token), fee: 0, tickSpacing: TICK_SPACING, hooks: IHooks(out.hook)}),
            hookRuntimeCodeHash: runtimeHashes[2],
            components: components
        });
    }

    function _bindPermit(PreparedLaunch memory out, LaunchConfig memory c, bytes32 outputsHash, bytes32 graphDeploymentHash) internal view {
        R router = R(c.router);
        out.permit = R.LaunchPermitV1({
            chainId: block.chainid,
            router: c.router,
            launchWallet: c.launchWallet,
            kind: R.LaunchKindV1.CustomGraph,
            routePayloadHash: keccak256(out.routePayload),
            expectedResultHash: keccak256(abi.encode(EXPECTED_GRAPH_RESULT_TYPEHASH, outputsHash, graphDeploymentHash)),
            stampRequestHash: router.computeStampRequestHash(out.stampRequest),
            nonce: c.routeNonce,
            validAfter: c.validAfter,
            deadline: c.deadline,
            value: c.initialBuyWei
        });
        out.permitDigest = router.permitDigest(out.permit);
    }

    function _sortByAddress(address[] memory a) internal pure returns (uint8[3] memory order) {
        order = [uint8(0), 1, 2];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (a[order[j]] < a[order[i]]) (order[i], order[j]) = (order[j], order[i]);
            }
        }
    }
}
