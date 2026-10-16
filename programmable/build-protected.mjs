#!/usr/bin/env node
// Builds LUCID's Custom Launch request on Programmable's mandatory launch-protection package v1
// (@programmable/launch 4.1.7). It follows buildProtectedEthereumLaunchV1 exactly (same sealed initializer,
// token and hook runtimes, same opening-price search, same salts and pack profile) with one difference:
// the hook's immutable creator-fee recipient is LucidVault, deployed as a fourth target in the same graph,
// instead of the launch wallet. Nothing is signed or sent.
//
// Usage (from this repository):
//   PL_DIR=<installed @programmable/launch 4.1.7 dir> SOLCJS_DIR=<dir with solc 0.8.26> ETH_RPC_URL=<mainnet rpc> \
//   LAUNCH_WALLET=0x.. GUARDIAN=0x.. AGENT=0x.. BUYBACK=0x.. TREASURY=0x.. LIQ=0x.. \
//   WEBSITE_URL=https://.. IMAGE_URI=https://.. SOURCE_URL=https://github.com/.. SOURCE_REVISION=<commit> \
//   node programmable/build-protected.mjs
// Then from protected/: programmable-launch validate launch.json --config protected-launch.config.json [--remote]

import { createHash, randomBytes } from "node:crypto";
import { mkdir, readFile, writeFile, copyFile } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const root = path.join(repo, "protected");
const env = process.env;
const fail = (m) => { console.error("build-protected: " + m); process.exit(1); };
const need = (k) => env[k] || fail("set " + k);
if (!env.PL_DIR) fail("set PL_DIR to the installed @programmable/launch 4.1.7 package directory");
const pl = (p) => pathToFileURL(path.join(env.PL_DIR, p)).href;

const viem = await import(pathToFileURL(createRequire(path.join(env.PL_DIR, "package.json")).resolve("viem")).href);
const { createPublicClient, http, encodeAbiParameters, encodeDeployData, getAddress, getContractAddress,
  getCreate2Address, keccak256, parseAbi, parseAbiParameters, stringToHex, toHex, encodeFunctionData } = viem;
const { PROTECTED_LAUNCH_POLICY_V1, PROTECTED_LAUNCH_CHAIN_PINS_V1, protectedOpeningPriceV1, protectedLaunchExemptionsV1,
  protectedSqrtPriceAtTickV1 } = await import(pl("src/launch-protection-v1.mjs"));
const { buildLaunch } = await import(pl("src/pack.mjs"));
const { buildSourceBundle } = await import(pl("src/source-bundle.mjs"));
const { deriveRouteNamespace } = await import(pl("src/graph.mjs"));
const { resolveDirectNativeProfile } = await import(pl("src/profile-direct-native-v1.mjs"));
const { GRAPH_TARGET_SALT_TYPE, LAUNCH_SEEDED_CONCENTRATED_LIQUIDITY_VECTORS } = await import(pl("src/constants.mjs"));
const kitDir = path.join(env.PL_DIR, "contracts/launch-protection-v1");
const ZERO = "0x0000000000000000000000000000000000000000";
const sha = (b) => "sha256:" + createHash("sha256").update(b).digest("hex");

// ------------------------------------------------------------------ public inputs
const addr = (k) => { const v = need(k); if (!/^0x[0-9a-fA-F]{40}$/.test(v)) fail(k + " must be an address"); return getAddress(v); };
const launchWallet = addr("LAUNCH_WALLET");
const roles = { guardian: addr("GUARDIAN"), agent: addr("AGENT"), buyback: addr("BUYBACK"), treasury: addr("TREASURY"), liquidity: addr("LIQ") };
const creatorBps = Number(env.CREATOR_BPS ?? 200);
const initialBuyWei = String(env.INITIAL_BUY_WEI ?? "30000000000000000");
const targetFdvUsd = String(env.TARGET_FDV_USD ?? "17000");
const minOutBps = BigInt(env.MIN_OUT_BPS ?? 9900);
const nonce = env.LAUNCH_NONCE ?? "0x" + randomBytes(32).toString("hex");
const description = (env.PROJECT_DESCRIPTION ?? readFileSync(path.join(repo, "programmable/description-protected.txt"), "utf8")).normalize("NFC").trim();
if (/["\\\u0000-\u001f\u007f]/u.test(description)) fail("description: no quotes, backslashes or line breaks");
const website = need("WEBSITE_URL"), imageUri = need("IMAGE_URI"), xUrl = env.X_URL ?? "https://x.com/lucid_agent";
const sourceUrl = need("SOURCE_URL"), revision = need("SOURCE_REVISION");
if (!/^[0-9a-f]{40}$/.test(revision)) fail("SOURCE_REVISION must be a 40-character commit");
const now = Math.floor(Date.now() / 1000);
const permitWindow = { validAfter: String(env.VALID_AFTER ?? now - 60), deadline: String(env.DEADLINE ?? now - 60 + 86_400) };

// ------------------------------------------------------------------ live chain and capabilities
const client = createPublicClient({ transport: http(need("ETH_RPC_URL")) });
const capabilities = await (await fetch("https://api.programmable.market/v3/capabilities")).json();
if (capabilities.chain?.id !== "1" || capabilities.profile?.profileVersion !== "3.6.0" || capabilities.profile?.productionLaunchAuthorized !== true) {
  fail("current Ethereum capabilities are required");
}
const status = await (await fetch("https://api.programmable.market/v1/launch-protection")).json();
if (status.policyVersion !== "programmable.launch-protection.v1" || status.minimumFdvUsd !== PROTECTED_LAUNCH_POLICY_V1.minimumFdvUsd) {
  fail("live launch-protection policy differs from the installed package");
}

// The helper's exact launch profile selection.
const selection = { schemaVersion: "programmable.direct-native-hook-graph-profile-selection.v3",
  profileId: "programmable.direct-native-hook-graph.v1", profileRevision: 3,
  targetRoles: { tokenTargetId: "token", hookTargetId: "hook", initializerTargetId: "initializer", platformFeeBindingTargetId: "hook" },
  fundingMode: "wallet-transaction-value", accountingMode: "inclusive-selected-total",
  assessmentBase: "executed-gross-declared-quote", feeCurrency: "declared-quote-currency",
  claimMode: "immutable-payout-recipient", payoutRecipient: PROTECTED_LAUNCH_POLICY_V1.treasury,
  applicantSelectedBuyHundredthsOfBip: String((creatorBps + 30) * 100),
  applicantSelectedSellHundredthsOfBip: String((creatorBps + 30) * 100),
  liquidityModel: { schemaVersion: "programmable.direct-native-liquidity-model-intent.v1", model: "launch-seeded-concentrated-liquidity",
    declaredLaunchState: "assessment_required", liquidityTargetId: "initializer", assessment: {
      schemaVersion: "programmable.direct-native-liquidity-model-assessment.v1", status: "required", requestClaimsExecution: false,
      requiredVectorIds: [...LAUNCH_SEEDED_CONCENTRATED_LIQUIDITY_VECTORS] } },
};
const profile = resolveDirectNativeProfile(selection, { profileVersion: "3.6.0", programmableTradeFeePolicy: capabilities.programmableTradeFeePolicy?.policy });

// ------------------------------------------------------------------ write the exact package sources + LucidVault
async function exactFile(file, content) {
  await mkdir(path.dirname(file), { recursive: true });
  if (existsSync(file)) {
    if (!(await readFile(file)).equals(Buffer.from(content))) fail("refusing to overwrite a different file: " + file);
    return;
  }
  await writeFile(file, content);
}
const standardBytes = await readFile(path.join(kitDir, "standard-json.json"));
for (const [source, value] of Object.entries(JSON.parse(standardBytes).sources)) await exactFile(path.join(root, source), value.content);
await exactFile(path.join(root, "protection/standard-json.json"), standardBytes);
const kitNames = { initializer: "ProtectedNativeInitializerV1", token: "ProtectedLaunchTokenV1", hook: "ProtectedNative30HookV1",
  module: "LaunchProtectionModuleV1", feeVault: "EthereumNativeFeeVaultV3", openingTaxVault: "EthereumNativeFeeVaultV3" };
const artifacts = {};
for (const [role, name] of Object.entries(kitNames)) {
  const bytes = await readFile(path.join(kitDir, name + ".artifact.json"));
  artifacts[role] = JSON.parse(bytes);
  if (artifacts[role].sourceArtifactHash !== sha(standardBytes)) fail("protected source package changed");
  if (["initializer", "token", "hook"].includes(role)) await exactFile(path.join(root, `protection/artifacts/${role}.json`), bytes);
}
await exactFile(path.join(root, "protection/evidence.json"), JSON.stringify({ schemaVersion: "programmable.launch-protection-build.v1",
  policy: PROTECTED_LAUNCH_POLICY_V1, signing: false, broadcast: false }) + "\n");

// LucidVault: its own exact compilation unit (solc 0.8.26, no CBOR metadata).
const vaultSource = await readFile(path.join(repo, "src/LucidVault.sol"), "utf8");
await mkdir(path.join(root, "lucid"), { recursive: true });
await writeFile(path.join(root, "lucid/LucidVault.sol"), vaultSource);
const vaultStandard = { language: "Solidity", sources: { "lucid/LucidVault.sol": { content: vaultSource } },
  settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: "cancun", viaIR: false,
    metadata: { bytecodeHash: "none", appendCBOR: false, useLiteralContent: true }, libraries: {}, remappings: [],
    outputSelection: { "*": { "*": ["abi", "metadata", "evm.bytecode.object", "evm.bytecode.linkReferences",
      "evm.deployedBytecode.object", "evm.deployedBytecode.linkReferences", "evm.deployedBytecode.immutableReferences"] } } } };
const vaultStandardBytes = Buffer.from(JSON.stringify(vaultStandard) + "\n");
await writeFile(path.join(root, "lucid/standard-json.json"), vaultStandardBytes);
const solc = createRequire(path.join(need("SOLCJS_DIR"), "package.json"))("solc");
if (!solc.version().startsWith("0.8.26+commit.8a97fa7a")) fail("solc 0.8.26+commit.8a97fa7a required");
const out = JSON.parse(solc.compile(vaultStandardBytes.toString()));
const errs = (out.errors ?? []).filter((e) => e.severity === "error");
if (errs.length) fail(errs.map((e) => e.formattedMessage).join("\n"));
const v = out.contracts["lucid/LucidVault.sol"].LucidVault;
if (Object.keys(v.evm.deployedBytecode.immutableReferences ?? {}).length) fail("LucidVault must have no immutables");
await mkdir(path.join(root, "lucid/artifacts"), { recursive: true });
await writeFile(path.join(root, "lucid/artifacts/vault.json"),
  JSON.stringify({ abi: v.abi, bytecode: v.evm.bytecode, deployedBytecode: v.evm.deployedBytecode, metadata: v.metadata }) + "\n");

// Image and evidence
const imageSourcePath = "assets/lucid-logo-1024.png";
await mkdir(path.join(root, "assets"), { recursive: true });
await copyFile(path.join(repo, imageSourcePath), path.join(root, imageSourcePath));
await mkdir(path.join(root, "lucid/evidence"), { recursive: true });
const testEvidencePath = path.join(repo, "evidence/forge-tests.json");
await writeFile(path.join(root, "lucid/evidence/tests.json"), existsSync(testEvidencePath)
  ? await readFile(testEvidencePath) : JSON.stringify({ status: "not-run" }) + "\n");

// ------------------------------------------------------------------ addresses (same derivation as the helper)
const sourcePaths = ["src", "lib", "protection", "lucid"];
const source = await buildSourceBundle(root, [...sourcePaths, imageSourcePath]);
const namespace = deriveRouteNamespace(source.bundleContentSha256, launchWallet, profile);
const saltType = keccak256(stringToHex(GRAPH_TARGET_SALT_TYPE));
function deriveRootAddress({ role, initCodeHash, applicantSalt }) {
  const field = Buffer.from(role), length = Buffer.alloc(4); length.writeUInt32BE(field.length);
  const targetIdHash = keccak256("0x" + Buffer.concat([Buffer.from("programmable.create2-graph-target-id.v1"), Buffer.from([0]), length, field]).toString("hex"));
  const salt = keccak256(encodeAbiParameters(parseAbiParameters("bytes32,uint256,address,bytes32,bytes32,bytes32,bytes32,address"),
    [saltType, 1n, profile.graphFactory, namespace, nonce, targetIdHash, applicantSalt, profile.router]));
  return { salt, address: getCreate2Address({ from: profile.graphFactory, salt, bytecodeHash: initCodeHash }) };
}

const pins = PROTECTED_LAUNCH_CHAIN_PINS_V1[1];
const owner = launchWallet;
const supply = 1_000_000_000n * 10n ** 18n;
const exemptions = protectedLaunchExemptionsV1(owner, []);
const block = await client.getBlock();
const [feedCode, routerCode, round, decimals] = await Promise.all([
  client.getCode({ address: pins.feed, blockNumber: block.number }), client.getCode({ address: pins.router, blockNumber: block.number }),
  client.readContract({ address: pins.feed, abi: parseAbi(["function latestRoundData() view returns(uint80,int256,uint256,uint256,uint80)"]), functionName: "latestRoundData", blockNumber: block.number }),
  client.readContract({ address: pins.feed, abi: parseAbi(["function decimals() view returns(uint8)"]), functionName: "decimals", blockNumber: block.number }),
]);
if (keccak256(feedCode) !== pins.feedCodeHash || keccak256(routerCode) !== pins.routerCodeHash) fail("trusted infrastructure runtime differs");
if (block.timestamp - round[3] > pins.maxAge) fail("USD feed expired");
const price = protectedOpeningPriceV1({ supply: String(supply), answer: round[1], feedDecimals: decimals, targetFdvUsd });

// Expected initial buy output at that price: the developer pays the normal fee only (exempt from the opening tax).
const initialBuy = BigInt(initialBuyWei);
const normalFee = (initialBuy * BigInt((30 + creatorBps) * 100) + 999_999n) / 1_000_000n;
const netIn = initialBuy - normalFee;
const Q96 = 1n << 96n;
const sqrtUpper = price.sqrtPriceX96, sqrtLower = protectedSqrtPriceAtTickV1(-887220);
const L = supply * Q96 / (sqrtUpper - sqrtLower);
const sqrtNext = (L * Q96 * sqrtUpper) / (L * Q96 + netIn * sqrtUpper);
const expectedOut = L * (sqrtUpper - sqrtNext) / Q96;
const minimumTokensOut = expectedOut * minOutBps / 10_000n;
if (minimumTokensOut > supply / 50n) fail("initial buy would exceed the 2% limit");

const salt = (role, attempt = 0n) => keccak256(encodeAbiParameters(parseAbiParameters("uint256,address,bytes32,string,uint256"), [1n, owner, nonce, role, attempt]));
function graphRoot(role, abiOwner, args, flags) {
  const initCode = encodeDeployData({ abi: abiOwner.abi, bytecode: abiOwner.creationBytecode ?? abiOwner.bytecode, args });
  const initCodeHash = keccak256(initCode);
  for (let attempt = 0n; attempt < 262144n; attempt++) {
    const applicantSalt = salt(role, attempt);
    const d = deriveRootAddress({ role, initCodeHash, applicantSalt });
    if (flags === undefined || (BigInt(d.address) & 0x3fffn) === BigInt(flags)) return { ...d, applicantSalt, args, initCode };
  }
  fail("address search exhausted for " + role);
}
const vaultArtifact = { abi: v.abi, bytecode: "0x" + v.evm.bytecode.object };
const vault = graphRoot("vault", vaultArtifact, [roles.guardian, roles.agent, roles.buyback, roles.treasury, roles.liquidity]);
const init = graphRoot("initializer", artifacts.initializer, [pins.manager, profile.graphFactory, pins.feed, pins.feedCodeHash]);
const token = graphRoot("token", artifacts.token, ["LUCID", "LUCID", supply, init.address, pins.manager]);
const config = [token.address, 0, 60, price.sqrtPriceX96, init.address, vault.address, creatorBps, creatorBps, ZERO, 0];
const hook = graphRoot("hook", artifacts.hook, [pins.manager, config, owner, pins.router, pins.routerCodeHash, exemptions], 0x20cc);
const feeVault = getContractAddress({ from: hook.address, nonce: 1n });
const protectionModule = getContractAddress({ from: hook.address, nonce: 2n });
const openingTaxVault = getContractAddress({ from: hook.address, nonce: 3n });

// Runtime immutables, materialized exactly as the package helper does.
const word = (value) => typeof value === "string" && /^0x[0-9a-f]{64}$/i.test(value) ? value.toLowerCase() : toHex(BigInt(value), { size: 32 });
function immutables(a, values) {
  let runtime = a.runtimeTemplateHex; const list = [];
  for (const w of a.immutableWords) {
    if (values[w.name] === undefined) fail("missing immutable " + w.name);
    const val = word(values[w.name]);
    for (const offset of w.byteOffsets) runtime = runtime.slice(0, 2 + offset * 2) + val.slice(2) + runtime.slice(2 + offset * 2 + 64);
    list.push({ immutableId: a.immutableIds[w.name], abiType: "bytes32", literal: val });
  }
  list.sort((x, y) => Number(BigInt(x.immutableId) - BigInt(y.immutableId)));
  return { list, runtimeCodeHash: keccak256(runtime) };
}
const moduleRuntime = immutables(artifacts.module, { kernel: hook.address, token: token.address, developer: owner,
  router: pins.router, routerCodeHash: pins.routerCodeHash, normalBuyFeePpm: (30 + creatorBps) * 100 });
const imm = {
  initializer: immutables(artifacts.initializer, { poolManager: pins.manager, graphFactory: profile.graphFactory, nativeUsdFeed: pins.feed,
    feedCodeHash: pins.feedCodeHash, feedDecimals: decimals, MAX_FEED_AGE: pins.maxAge }),
  token: immutables(artifacts.token, { initializer: init.address, poolManager: pins.manager, launchSupply: supply, walletTokenLimit: supply / 50n }),
  hook: immutables(artifacts.hook, { poolManager: pins.manager, CANONICAL_POOL_MANAGER: pins.manager, CHAIN_ID: 1, token: token.address,
    lpFee: 0, tickSpacing: 60, initialSqrtPriceX96: price.sqrtPriceX96, initializer: init.address, creatorBuyFeeBps: creatorBps,
    creatorSellFeeBps: creatorBps, module: protectionModule, moduleCodeHash: moduleRuntime.runtimeCodeHash, maxModuleLpFeePips: 0, feeVault, openingTaxVault }),
};

// ------------------------------------------------------------------ pack config
const base = (role, d, unit, artifact, kind) => ({ targetId: role, compilationUnitId: unit, artifact, applicantSalt: d.applicantSalt,
  deploymentValueWei: "0", initializerValueWei: "0", initializer: null, componentKind: kind, declaredHookPermissions: null,
  runtimeImmutables: imm[role]?.list ?? [] });
const metadata = { schemaVersion: "programmable.project-metadata-input.v1", token: { name: "LUCID", symbol: "LUCID" },
  presentation: { description, image: { sourcePath: imageSourcePath, uri: imageUri },
    links: [{ kind: "website", uri: website }, { kind: "x", uri: xUrl }] } };
const targets = [
  { ...base("initializer", init, "launch-protection-v1", "protection/artifacts/initializer.json", "other"),
    constructorArguments: [pins.manager, profile.graphFactory, pins.feed, pins.feedCodeHash],
    initializer: { function: "initialize", arguments: [{ target: "hook" }, { target: "token" }, price.initialTick, owner, String(minimumTokensOut)] },
    initializerValueWei: initialBuyWei },
  { ...base("token", token, "launch-protection-v1", "protection/artifacts/token.json", "token"),
    constructorArguments: ["LUCID", "LUCID", String(supply), { target: "initializer" }, pins.manager] },
  { ...base("hook", hook, "launch-protection-v1", "protection/artifacts/hook.json", "hook"),
    constructorArguments: [pins.manager, [{ target: "token" }, 0, 60, String(price.sqrtPriceX96), { target: "initializer" }, { target: "vault" },
      creatorBps, creatorBps, ZERO, 0], owner, pins.router, pins.routerCodeHash, exemptions],
    declaredHookPermissions: ["beforeInitialize", "beforeSwap", "afterSwap", "beforeSwapReturnDelta", "afterSwapReturnDelta"] },
  { ...base("vault", vault, "lucid-vault", "lucid/artifacts/vault.json", "other"),
    constructorArguments: [roles.guardian, roles.agent, roles.buyback, roles.treasury, roles.liquidity] },
];
// No profileVersion: the CLI then binds the live /v3/capabilities profile (3.6.0) and its exact fee policy.
const cfg = { schemaVersion: "programmable.launch-pack-config.v3", chainId: "1", launchWallet, nonce,
  source: { root: ".", paths: sourcePaths, sourceLineageNonce: env.SOURCE_LINEAGE_NONCE ?? "1", publicOrigin: { url: sourceUrl, revision } },
  compilationUnits: [{ compilationUnitId: "launch-protection-v1", standardJson: "protection/standard-json.json" },
    { compilationUnitId: "lucid-vault", standardJson: "lucid/standard-json.json" }],
  targets, pool: { tokenTargetId: "token", hookTargetId: "hook", fee: 0, tickSpacing: 60, quoteCurrency: ZERO },
  projectMetadata: metadata, launchProfile: selection, permitWindow,
  agentAttestation: { agentId: "lucid-claude-code-builder", checkedAt: new Date().toISOString(),
    checks: [{ checkId: "protected-source-package", evidence: "protection/evidence.json" },
      { checkId: "lucid-vault-and-protected-fork-tests", evidence: "lucid/evidence/tests.json" }] } };
const configPath = path.join(root, "protected-launch.config.json");
await writeFile(configPath, JSON.stringify(cfg, null, 2) + "\n");
const built = await buildLaunch({ configPath, directNativeTradeFeePolicy: capabilities.programmableTradeFeePolicy?.policy });
for (const [role, d] of Object.entries({ initializer: init, token, hook, vault })) {
  if (built.predictions.find((x) => x.targetId === role)?.predictedAddress.toLowerCase() !== d.address.toLowerCase()) fail("prediction differs for " + role);
}

console.log(JSON.stringify({ ok: true, config: path.relative(repo, configPath), nonce,
  openingFdvUsd: String(price.openingFdvUsd), startTick: price.initialTick, ethUsd: String(round[1]),
  initialBuyWei, expectedInitialTokens: String(expectedOut / 10n ** 18n), minimumTokensOut: String(minimumTokensOut / 10n ** 18n),
  addresses: { initializer: init.address, token: token.address, hook: hook.address, vault: vault.address, feeVault, protectionModule, openingTaxVault },
  permitWindow }, null, 2));
