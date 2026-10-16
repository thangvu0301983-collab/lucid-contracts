// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice The launch-facing types and getters of Programmable's Ethereum CustomGraph route, copied field for
///         field from the official bundle (IProgrammableCreate2GraphDeployerV1.sol,
///         IProgrammableLaunchStampRouterV1.sol; Programmable "ethereum-custom-hook-indexing", Router
///         0x8622DD5bAb44185f2A458ac90384Ac99248f8d56, Graph Factory 0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887).
///         Only what LUCID's launch needs; the ABI encoding is identical.
interface IProgrammableGraphFactory {
    struct GraphAuthorization {
        bytes32 routeNamespace;
        bytes32 routeNonce;
        bytes32 topologyHash;
        bytes32 graphCommitment;
        address authorizedLauncher;
        uint256 totalValue;
    }

    struct Target {
        bytes32 targetIdHash;
        bytes32 applicantSalt;
        uint256 deploymentValue;
        uint256 initializerValue;
        bytes initCode;
        bytes initializerCalldata;
    }

    function deployGraph(GraphAuthorization calldata authorization, Target[] calldata targets)
        external
        payable
        returns (address[] memory deployments, bytes32[] memory runtimeCodeHashes, bytes[] memory runtimeCodes, bytes32 graphDeploymentHash);

    function computeGraphCommitment(GraphAuthorization calldata authorization, Target[] calldata targets)
        external
        view
        returns (bytes32 commitment, uint256 targetValueSum);

    function predictTarget(GraphAuthorization calldata authorization, Target calldata target) external view returns (address);

    function TARGET_SALT_TYPEHASH() external view returns (bytes32);
}

interface IProgrammableLaunchStampRouter {
    enum LaunchKindV1 {
        Invalid,
        CustomGraph,
        Classic
    }

    enum ComponentKindV1 {
        Other,
        Token,
        Hook
    }

    enum ComponentScopeV1 {
        Invalid,
        Exclusive,
        SharedInfrastructure
    }

    struct ExpectedGraphOutputV1 {
        uint8 targetIndex;
        bytes32 targetIdHash;
        address account;
        bytes32 runtimeCodeHash;
    }

    struct CustomGraphRouteV1 {
        bytes32 routeNamespace;
        bytes32 routeNonce;
        bytes32 topologyHash;
        bytes32 graphCommitment;
        IProgrammableGraphFactory.Target[] targets;
        ExpectedGraphOutputV1[] expectedOutputs;
        bytes32 expectedGraphDeploymentHash;
    }

    struct ComponentV1 {
        uint8 resultIndex;
        address account;
        bytes32 runtimeCodeHash;
        ComponentKindV1 kind;
        ComponentScopeV1 scope;
    }

    struct StampRequestV1 {
        bytes32 launchId;
        address token;
        bytes32 tokenRuntimeCodeHash;
        PoolKey poolKey;
        bytes32 hookRuntimeCodeHash;
        ComponentV1[] components;
    }

    struct LaunchPermitV1 {
        uint256 chainId;
        address router;
        address launchWallet;
        LaunchKindV1 kind;
        bytes32 routePayloadHash;
        bytes32 expectedResultHash;
        bytes32 stampRequestHash;
        bytes32 nonce;
        uint64 validAfter;
        uint64 deadline;
        uint256 value;
    }

    struct StampRecordV1 {
        LaunchKindV1 kind;
        address launchWallet;
        address token;
        address hook;
        address poolManager;
        bytes32 poolId;
        bytes32 poolKeyHash;
        bytes32 componentSetHash;
        bytes32 routePayloadHash;
        address routeLauncher;
        bytes32 routeLauncherRuntimeCodeHash;
        bytes32 expectedResultHash;
        bytes32 permitDigest;
        bytes32 stampHash;
    }

    function launchAndStampV1(
        LaunchPermitV1 calldata permit,
        StampRequestV1 calldata stampRequest,
        bytes calldata routePayload,
        bytes calldata signature
    ) external payable returns (bytes32 stampHash);

    function permitDigest(LaunchPermitV1 calldata permit) external view returns (bytes32);
    function computeStampRequestHash(StampRequestV1 calldata request) external pure returns (bytes32);
    function launchStamp(bytes32 launchId) external view returns (StampRecordV1 memory);
    function launchIdByToken(address token) external view returns (bytes32);
    function PERMIT_AUTHORITY() external view returns (address);
    function GRAPH_FACTORY() external view returns (address);
    function POOL_MANAGER() external view returns (address);
}
