// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {LucidLaunchBuilder} from "./LucidLaunchBuilder.sol";
import {IProgrammableGraphFactory as F, IProgrammableLaunchStampRouter as R} from "./programmable/ProgrammableTypes.sol";

/// @notice Shared environment for preparing and executing LUCID's launch. Both scripts rebuild the exact same
///         tuples from the same inputs (everything is deterministic), so the digest Programmable signs is the
///         digest that executes.
///
///   ROUTER=0x8622DD5bAb44185f2A458ac90384Ac99248f8d56   refresh from https://developers.programmable.family/api/v2/manifest
///   LAUNCH_WALLET=0x...            sends the launch transaction, receives the initial buy
///   GUARDIAN=0x... AGENT=0x... BUYBACK=0x... TREASURY=0x... LIQ=0x...
///   PLATFORM_FEE_RECIPIENT=0x...   as Programmable confirms in review
///   PLATFORM_FEE_PPM=3000          as Programmable confirms in review (bundle README: 3,000 = 0.30%)
///   LAUNCH_TICK=196200             multiple of 60; 1.0001^tick LUCID per ETH (196200 ~ a 3 ETH starting valuation)
///   INITIAL_BUY_WEI=1000000000000000
///   ROUTE_NONCE=0x...              32 random bytes, single use (it is also the permit nonce)
///   ROUTE_NAMESPACE=0x...          optional, default keccak256("lucid.custom-graph.v1")
///   LAUNCH_ID=0x...                optional, default keccak256("lucid.launch.v1")
///   VALID_AFTER=<unix> DEADLINE=<unix>   the execution window Programmable signs, at most 1 hour
abstract contract LucidLaunchEnv is Script, LucidLaunchBuilder {
    function _configFromEnv() internal view returns (LaunchConfig memory c) {
        c.router = vm.envOr("ROUTER", address(0x8622DD5bAb44185f2A458ac90384Ac99248f8d56));
        c.launchWallet = vm.envAddress("LAUNCH_WALLET");
        c.guardian = vm.envAddress("GUARDIAN");
        c.agent = vm.envAddress("AGENT");
        c.buybackVault = vm.envAddress("BUYBACK");
        c.treasury = vm.envAddress("TREASURY");
        c.liquidityVault = vm.envAddress("LIQ");
        c.platformFeeRecipient = vm.envAddress("PLATFORM_FEE_RECIPIENT");
        c.platformFeePpm = vm.envOr("PLATFORM_FEE_PPM", uint256(3_000));
        c.launchTick = int24(vm.envOr("LAUNCH_TICK", int256(196_200)));
        c.initialBuyWei = vm.envOr("INITIAL_BUY_WEI", uint256(0.001 ether));
        c.routeNamespace = vm.envOr("ROUTE_NAMESPACE", keccak256("lucid.custom-graph.v1"));
        c.routeNonce = vm.envBytes32("ROUTE_NONCE");
        c.launchId = vm.envOr("LAUNCH_ID", keccak256("lucid.launch.v1"));
        c.validAfter = uint64(vm.envUint("VALID_AFTER"));
        c.deadline = uint64(vm.envUint("DEADLINE"));
        c.tokenDescription = vm.envString("TOKEN_DESCRIPTION");
        c.tokenWebsite = vm.envString("TOKEN_WEBSITE");
        c.tokenImage = vm.envString("TOKEN_IMAGE");
        c.tokenX = vm.envOr("TOKEN_X", string("https://x.com/lucid_agent"));
    }
}

/// @notice Step 1 (no broadcast). Run against an Ethereum RPC:
///   forge script script/LucidLaunch.s.sol:PrepareLucidLaunch --rpc-url $ETH_RPC_URL
/// Writes launch-out/lucid-launch-request.json in the format of Programmable's direct-launch-request template,
/// with the permit digest to send to Programmable for its EIP-1271 authority signature.
contract PrepareLucidLaunch is LucidLaunchEnv {
    function run() external {
        LaunchConfig memory c = _configFromEnv();
        PreparedLaunch memory L = _prepareLaunch(c);
        vm.writeFile("launch-out/lucid-launch-request.json", _json(L));
        console2.log("launcher       ", L.launcher);
        console2.log("token          ", L.token);
        console2.log("hook           ", L.hook);
        console2.log("permit digest  ");
        console2.logBytes32(L.permitDigest);
        console2.log("written        launch-out/lucid-launch-request.json");
    }

    function _h(bytes32 v) private pure returns (string memory) {
        return string.concat('"', vm.toString(v), '"');
    }

    function _a(address v) private pure returns (string memory) {
        return string.concat('"', vm.toString(v), '"');
    }

    function _n(uint256 v) private pure returns (string memory) {
        return string.concat('"', vm.toString(v), '"');
    }

    function _b(bytes memory v) private pure returns (string memory) {
        return string.concat('"', vm.toString(v), '"');
    }

    function _json(PreparedLaunch memory L) private pure returns (string memory) {
        return string.concat(
            '{\n  "format": "programmable.direct-router-launch-input.example.v1",\n  "chainId": 1,\n',
            '  "permit": ', _permit(L.permit), ',\n',
            '  "stampRequest": ', _stamp(L.stampRequest), ',\n',
            '  "route": ', _route(L.route), ',\n',
            '  "routePayload": ', _b(L.routePayload), ',\n',
            '  "permitDigest": ', _h(L.permitDigest), ',\n',
            '  "permitAuthoritySignature": null\n}\n'
        );
    }

    function _permit(R.LaunchPermitV1 memory p) private pure returns (string memory) {
        return string.concat(
            '{"chainId": ', _n(p.chainId), ', "router": ', _a(p.router), ', "launchWallet": ', _a(p.launchWallet),
            ', "kind": 1, "routePayloadHash": ', _h(p.routePayloadHash), ', "expectedResultHash": ', _h(p.expectedResultHash),
            ', "stampRequestHash": ', _h(p.stampRequestHash), ', "nonce": ', _h(p.nonce), ', "validAfter": ', _n(p.validAfter),
            ', "deadline": ', _n(p.deadline), ', "value": ', _n(p.value), '}'
        );
    }

    function _stamp(R.StampRequestV1 memory s) private pure returns (string memory out) {
        out = string.concat(
            '{"launchId": ', _h(s.launchId), ', "token": ', _a(s.token), ', "tokenRuntimeCodeHash": ', _h(s.tokenRuntimeCodeHash),
            ', "poolKey": {"currency0": ', _a(address(0)), ', "currency1": ', _a(s.token), ', "fee": "0", "tickSpacing": "60", "hooks": ',
            _a(address(s.poolKey.hooks)), '}, "hookRuntimeCodeHash": ', _h(s.hookRuntimeCodeHash), ', "components": ['
        );
        for (uint256 i; i < s.components.length; ++i) {
            R.ComponentV1 memory k = s.components[i];
            out = string.concat(
                out, i == 0 ? "" : ", ", '{"resultIndex": ', _n(k.resultIndex), ', "account": ', _a(k.account), ', "runtimeCodeHash": ',
                _h(k.runtimeCodeHash), ', "kind": ', _n(uint8(k.kind)), ', "scope": ', _n(uint8(k.scope)), '}'
            );
        }
        out = string.concat(out, ']}');
    }

    function _route(R.CustomGraphRouteV1 memory r) private pure returns (string memory out) {
        out = string.concat(
            '{"routeNamespace": ', _h(r.routeNamespace), ', "routeNonce": ', _h(r.routeNonce), ', "topologyHash": ', _h(r.topologyHash),
            ', "graphCommitment": ', _h(r.graphCommitment), ', "targets": ['
        );
        for (uint256 i; i < r.targets.length; ++i) {
            F.Target memory t = r.targets[i];
            out = string.concat(
                out, i == 0 ? "" : ", ", '{"targetIdHash": ', _h(t.targetIdHash), ', "applicantSalt": ', _h(t.applicantSalt),
                ', "deploymentValue": ', _n(t.deploymentValue), ', "initializerValue": ', _n(t.initializerValue), ', "initCode": ',
                _b(t.initCode), ', "initializerCalldata": ', _b(t.initializerCalldata), '}'
            );
        }
        out = string.concat(out, '], "expectedOutputs": [');
        for (uint256 i; i < r.expectedOutputs.length; ++i) {
            R.ExpectedGraphOutputV1 memory o = r.expectedOutputs[i];
            out = string.concat(
                out, i == 0 ? "" : ", ", '{"targetIndex": ', _n(o.targetIndex), ', "targetIdHash": ', _h(o.targetIdHash), ', "account": ',
                _a(o.account), ', "runtimeCodeHash": ', _h(o.runtimeCodeHash), '}'
            );
        }
        out = string.concat(out, '], "expectedGraphDeploymentHash": ', _h(r.expectedGraphDeploymentHash), '}');
    }
}

/// @notice Step 2, inside the signed window, from the launch wallet:
///   PERMIT_SIGNATURE=0x... forge script script/LucidLaunch.s.sol:ExecuteLucidLaunch --rpc-url $ETH_RPC_URL --account launch --broadcast
/// Rebuilds the same tuples, refuses to send if the digest differs from EXPECTED_PERMIT_DIGEST, and forge
/// simulates the fully authorized transaction before broadcasting it.
contract ExecuteLucidLaunch is LucidLaunchEnv {
    function run() external {
        LaunchConfig memory c = _configFromEnv();
        PreparedLaunch memory L = _prepareLaunch(c);
        require(L.permitDigest == vm.envBytes32("EXPECTED_PERMIT_DIGEST"), "digest differs from the one Programmable signed");
        bytes memory signature = vm.envBytes("PERMIT_SIGNATURE");
        vm.startBroadcast(c.launchWallet);
        bytes32 stampHash = R(c.router).launchAndStampV1{value: c.initialBuyWei}(L.permit, L.stampRequest, L.routePayload, signature);
        vm.stopBroadcast();
        console2.log("token", L.token);
        console2.log("hook ", L.hook);
        console2.logBytes32(stampHash);
    }
}
