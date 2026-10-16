#!/usr/bin/env node
// Builds the exact inputs the Programmable Launch CLI (@programmable/launch >= 4.1.6, Ethereum profile 3.6.0)
// packs into a Custom Launch request for LUCID:
//
//   standard-json/lucid-graph.json      exact solc 0.8.26 Standard JSON input (all sources inline)
//   artifacts/{launcher,token,hook}.json compiler artifacts for the three graph targets
//   evidence/*.json                      build and test evidence referenced by agentAttestation
//   programmable-launch.config.json      pack config (schema programmable.launch-pack-config.v3, profile 3.6.0)
//
// Everything here is public launch input: no key, no signature, nothing is sent anywhere.
// Then: programmable-launch pack --config programmable-launch.config.json --output launch.json
//
// Usage: node programmable/build.mjs   (values come from the environment, see programmable/README.md)

import { createHash, randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const rel = (p) => path.join(root, ...p.split("/"));
const sha256 = (bytes) => `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
const fail = (msg) => {
  console.error(`build: ${msg}`);
  process.exit(1);
};

// ------------------------------------------------------------------ fixed chain facts (Ethereum mainnet)
const POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90";
const GRAPH_FACTORY = "0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887"; // CREATE2 deployer, = LucidLauncher.deployer
const NATIVE_ETH = "0x0000000000000000000000000000000000000000";
const SOLC_BUILD = "0.8.26+commit.8a97fa7a";
const TICK_SPACING = 60;
const HOOK_PERMISSIONS = ["beforeInitialize", "beforeSwap", "afterSwap", "beforeSwapReturnDelta", "afterSwapReturnDelta"];

// ------------------------------------------------------------------ public launch inputs
const env = process.env;
const need = (k) => {
  const v = env[k];
  if (v === undefined || v === "") fail(`set ${k}`);
  return v;
};
const addr = (k, fallback) => {
  const v = env[k] ?? fallback;
  if (!/^0x[0-9a-fA-F]{40}$/.test(v ?? "")) fail(`${k} must be a 0x address`);
  return v;
};
const uintStr = (k, fallback) => {
  const v = String(env[k] ?? fallback);
  if (!/^(0|[1-9][0-9]*)$/.test(v)) fail(`${k} must be a decimal integer`);
  return v;
};

const launchWallet = addr("LAUNCH_WALLET"); // must equal the API key's controller wallet
const guardian = addr("GUARDIAN");
const agent = addr("AGENT");
const buyback = addr("BUYBACK");
const treasury = addr("TREASURY");
const liquidityVault = addr("LIQ");
const platformFeeRecipient = addr("PLATFORM_FEE_RECIPIENT", "0xD88539d3c4C460136a733A3Fd60cf6BF269079da");
const platformFeePpm = uintStr("PLATFORM_FEE_PPM", "3000");
const initialBuyWei = uintStr("INITIAL_BUY_WEI", "1000000000000000"); // 0.001 ETH
const launchTick = Number(uintStr("LAUNCH_TICK", "196200"));
if (launchTick % TICK_SPACING !== 0) fail("LAUNCH_TICK must be a multiple of 60");
if (initialBuyWei === "0") fail("INITIAL_BUY_WEI must be nonzero (funding mode wallet-transaction-value)");

const description = need("PROJECT_DESCRIPTION").normalize("NFC").trim();
if (/["\\\u0000-\u001f\u007f]/u.test(description)) fail("PROJECT_DESCRIPTION: no quotes, backslashes or line breaks");
const website = need("WEBSITE_URL");
const imageUri = need("IMAGE_URI");
const xUrl = env.X_URL ?? "https://x.com/lucid_agent";
for (const [k, v] of [["WEBSITE_URL", website], ["IMAGE_URI", imageUri], ["X_URL", xUrl]]) {
  if (!/^https:\/\/[^\s"\\]+$/.test(v)) fail(`${k} must be a public https:// URL`);
}
if (!/^https:\/\/x\.com\/[A-Za-z0-9_]{1,64}$/.test(xUrl)) fail("X_URL must look like https://x.com/<handle>");
const imageSourcePath = env.IMAGE_SOURCE_PATH ?? "assets/lucid-logo-1024.png";
if (!existsSync(rel(imageSourcePath))) fail(`image ${imageSourcePath} not found`);

const sourceUrl = need("SOURCE_URL"); // public repository holding these exact bytes
const sourceRevision = need("SOURCE_REVISION"); // exact 40-character commit
if (!/^https:\/\//.test(sourceUrl)) fail("SOURCE_URL must be https");
if (!/^[0-9a-f]{40}$/.test(sourceRevision)) fail("SOURCE_REVISION must be the lowercase 40-character commit");

const nonce = env.LAUNCH_NONCE ?? `0x${randomBytes(32).toString("hex")}`;
if (!/^0x[0-9a-f]{64}$/.test(nonce) || /^0x0{64}$/.test(nonce)) fail("LAUNCH_NONCE must be a nonzero lowercase bytes32");
const now = Math.floor(Date.now() / 1000);
const validAfter = uintStr("VALID_AFTER", String(now - 60));
const deadline = uintStr("DEADLINE", String(Number(validAfter) + 86_400)); // the 24-hour router allows up to one day
if (BigInt(deadline) - BigInt(validAfter) > 86_400n) fail("DEADLINE - VALID_AFTER must be <= 86400");

// Declared project fee, hundredths of a bip (1% = 10000). LUCID's fee is agent-set within on-chain stage limits:
// at most 3% steady state, and a buy right at launch pays up to +9% extra (the launch flinch, decaying to 0 in
// 15 minutes), so the declaration states the maxima the hook can ever charge.
const applicantBuy = uintStr("APPLICANT_BUY_HBIP", "100000");
const applicantSell = uintStr("APPLICANT_SELL_HBIP", "30000");

// ------------------------------------------------------------------ Standard JSON (same settings as foundry.toml)
const REMAPPINGS = readFileSync(rel("remappings.txt"), "utf8").split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
const ENTRYPOINTS = ["src/LucidLauncher.sol", "src/LucidToken.sol", "src/LucidHook.sol"];

function resolveImport(fromUnit, spec) {
  if (spec.startsWith(".")) return path.posix.normalize(path.posix.join(path.posix.dirname(fromUnit), spec));
  let best = null;
  for (const r of REMAPPINGS) {
    const [prefix, target] = r.split("=");
    if (spec.startsWith(prefix) && (!best || prefix.length > best[0].length)) best = [prefix, target];
  }
  return best ? best[1] + spec.slice(best[0].length) : spec;
}

const sources = new Map();
const pending = [...ENTRYPOINTS];
while (pending.length) {
  const unit = pending.shift();
  if (sources.has(unit)) continue;
  if (unit.startsWith("../") || path.posix.isAbsolute(unit)) fail(`unsafe source ${unit}`);
  const content = readFileSync(rel(unit), "utf8");
  sources.set(unit, content);
  const re = /^\s*import\s+(?:[^;]*?\sfrom\s+)?["']([^"']+)["']\s*;/gmu;
  for (let m = re.exec(content); m; m = re.exec(content)) {
    const next = resolveImport(unit, m[1]);
    if (!sources.has(next)) pending.push(next);
  }
}
const sortedUnits = [...sources.keys()].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
const standardJson = {
  language: "Solidity",
  sources: Object.fromEntries(sortedUnits.map((u) => [u, { content: sources.get(u) }])),
  settings: {
    remappings: [...REMAPPINGS].sort(),
    optimizer: { enabled: true, runs: 1000 },
    evmVersion: "cancun",
    viaIR: false,
    metadata: { bytecodeHash: "none", appendCBOR: false, useLiteralContent: true },
    libraries: {},
    outputSelection: {
      "*": {
        "*": [
          "abi",
          "metadata",
          "evm.bytecode.object",
          "evm.bytecode.linkReferences",
          "evm.deployedBytecode.object",
          "evm.deployedBytecode.linkReferences",
          "evm.deployedBytecode.immutableReferences",
        ],
        "": ["ast"],
      },
    },
  },
};
const standardJsonBytes = Buffer.from(`${JSON.stringify(standardJson)}\n`, "utf8");
mkdirSync(rel("standard-json"), { recursive: true });
writeFileSync(rel("standard-json/lucid-graph.json"), standardJsonBytes);

// ------------------------------------------------------------------ compile with exact solc 0.8.26
const requireFrom = createRequire(env.SOLCJS_DIR ? path.join(env.SOLCJS_DIR, "package.json") : path.join(root, "package.json"));
const solc = requireFrom("solc");
if (!solc.version().startsWith(SOLC_BUILD)) fail(`solc ${solc.version()} is not ${SOLC_BUILD}`);
const output = JSON.parse(solc.compile(standardJsonBytes.toString("utf8")));
const errors = (output.errors ?? []).filter((e) => e.severity === "error");
if (errors.length) fail(`solc:\n${errors.map((e) => e.formattedMessage).join("\n")}`);

const TARGETS = {
  launcher: ["src/LucidLauncher.sol", "LucidLauncher"],
  token: ["src/LucidToken.sol", "LucidToken"],
  hook: ["src/LucidHook.sol", "LucidHook"],
};
mkdirSync(rel("artifacts"), { recursive: true });
const compiled = {};
const artifactDigests = {};
for (const [id, [unit, name]] of Object.entries(TARGETS)) {
  const c = output.contracts?.[unit]?.[name];
  if (!c?.evm?.bytecode?.object || !c?.evm?.deployedBytecode?.object) fail(`no output for ${unit}:${name}`);
  compiled[id] = c;
  const bytes = Buffer.from(
    `${JSON.stringify({ abi: c.abi, bytecode: c.evm.bytecode, deployedBytecode: c.evm.deployedBytecode, metadata: c.metadata })}\n`,
    "utf8",
  );
  writeFileSync(rel(`artifacts/${id}.json`), bytes);
  artifactDigests[id] = sha256(bytes);
}

// Cross-check against the bytecode Foundry tested (forge build), when present.
const forgeMatch = {};
for (const [id, [unit, name]] of Object.entries(TARGETS)) {
  const f = rel(`out/${path.posix.basename(unit)}/${name}.json`);
  if (!existsSync(f)) {
    forgeMatch[id] = "forge-artifact-absent";
    continue;
  }
  const fa = JSON.parse(readFileSync(f, "utf8"));
  const same = fa.bytecode?.object?.replace(/^0x/, "") === compiled[id].evm.bytecode.object;
  if (!same) fail(`${id}: solc creation bytecode differs from forge out/ (run forge build with the same foundry.toml)`);
  forgeMatch[id] = "creation-bytecode-identical";
}

// ------------------------------------------------------------------ runtime immutables
const immutableNames = new Map();
const walk = (node) => {
  if (!node || typeof node !== "object") return;
  if (node.nodeType === "VariableDeclaration" && node.mutability === "immutable") immutableNames.set(String(node.id), node.name);
  for (const v of Object.values(node)) {
    if (Array.isArray(v)) v.forEach(walk);
    else if (v && typeof v === "object") walk(v);
  }
};
for (const s of Object.values(output.sources ?? {})) walk(s.ast);

const IMMUTABLE_VALUES = {
  launcher: {
    poolManager: { abiType: "address", literal: POOL_MANAGER },
    deployer: { abiType: "address", literal: GRAPH_FACTORY },
  },
  token: {},
  hook: {
    poolManager: { abiType: "address", literal: POOL_MANAGER },
    token: { abiType: "address", target: "token" },
    platformFeeRecipient: { abiType: "address", literal: platformFeeRecipient },
    platformFeePpm: { abiType: "uint256", literal: platformFeePpm },
  },
};
const runtimeImmutables = {};
for (const id of Object.keys(TARGETS)) {
  const refs = compiled[id].evm.deployedBytecode.immutableReferences ?? {};
  runtimeImmutables[id] = Object.keys(refs)
    .sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : 1))
    .map((immutableId) => {
      const name = immutableNames.get(immutableId);
      const v = IMMUTABLE_VALUES[id][name];
      if (!v) fail(`${id}: no value bound for immutable ${name} (#${immutableId})`);
      return { immutableId, ...v };
    });
  const bound = Object.keys(IMMUTABLE_VALUES[id]).length;
  if (bound !== runtimeImmutables[id].length) fail(`${id}: ${bound} immutables bound, compiler has ${runtimeImmutables[id].length}`);
}

// ------------------------------------------------------------------ evidence
mkdirSync(rel("evidence"), { recursive: true });
const checkedAt = new Date().toISOString();
const buildEvidence = {
  schemaVersion: "lucid.programmable-build-evidence.v1",
  checkedAt,
  compiler: SOLC_BUILD,
  settings: { optimizerRuns: 1000, evmVersion: "cancun", viaIR: false, bytecodeHash: "none", appendCBOR: false },
  standardJsonSha256: sha256(standardJsonBytes),
  sourceCount: sortedUnits.length,
  artifacts: artifactDigests,
  forgeBytecodeCrossCheck: forgeMatch,
  graph: "launcher(PoolManager) -> token(launcher, metadata) -> hook(PoolManager, token, fee, roles); init launcher.launch(token, hook)",
  hookPermissions: HOOK_PERMISSIONS,
  sourceRevision,
};
writeFileSync(rel("evidence/build.json"), `${JSON.stringify(buildEvidence, null, 2)}\n`);

let testEvidence = { schemaVersion: "lucid.forge-test-evidence.v1", checkedAt, status: "not-run" };
if (env.SKIP_FORGE_TEST !== "1") {
  let raw;
  try {
    raw = execFileSync("forge", ["test", "--json"], { cwd: root, encoding: "utf8", maxBuffer: 64 * 1024 * 1024, env });
  } catch (e) {
    fail(`forge test failed:\n${e.stdout ?? e.message}`);
  }
  const suites = JSON.parse(raw.slice(raw.indexOf("{")));
  const results = [];
  for (const [suite, r] of Object.entries(suites)) {
    for (const [test, t] of Object.entries(r.test_results ?? {})) results.push({ suite, test, status: t.status });
  }
  const failed = results.filter((r) => r.status !== "Success");
  if (failed.length) fail(`forge tests failed: ${failed.map((f) => f.test).join(", ")}`);
  testEvidence = {
    schemaVersion: "lucid.forge-test-evidence.v1",
    checkedAt,
    status: "passed",
    forkTestsIncluded: Boolean(env.ETH_RPC_URL),
    passed: results.length,
    results,
  };
}
writeFileSync(rel("evidence/forge-tests.json"), `${JSON.stringify(testEvidence, null, 2)}\n`);

// ------------------------------------------------------------------ pack config
const sourcePaths = [...new Set([...sortedUnits, imageSourcePath, "foundry.toml", "remappings.txt", "programmable/build.mjs"])]
  .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));

const config = {
  schemaVersion: "programmable.launch-pack-config.v3",
  // No profileVersion: a fresh pack then binds the live /v3/capabilities profile and its exact fee policy.
  ...(env.PROFILE_VERSION ? { profileVersion: env.PROFILE_VERSION } : {}),
  launchWallet,
  chainId: "1",
  nonce,
  source: {
    root: ".",
    paths: sourcePaths,
    sourceLineageNonce: uintStr("SOURCE_LINEAGE_NONCE", "1"),
    publicOrigin: { url: sourceUrl, revision: sourceRevision },
  },
  compilationUnits: [{ compilationUnitId: "lucid-graph", standardJson: "standard-json/lucid-graph.json" }],
  targets: [
    {
      targetId: "launcher",
      compilationUnitId: "lucid-graph",
      artifact: "artifacts/launcher.json",
      applicantSalt: `0x${"01".repeat(32)}`,
      constructorArguments: [POOL_MANAGER],
      initializer: {
        function: "launch",
        arguments: [[{ target: "token" }, { target: "hook" }, TICK_SPACING, launchTick, launchWallet]],
      },
      deploymentValueWei: "0",
      initializerValueWei: initialBuyWei,
      componentKind: "other",
      declaredHookPermissions: null,
      runtimeImmutables: runtimeImmutables.launcher,
    },
    {
      targetId: "token",
      compilationUnitId: "lucid-graph",
      artifact: "artifacts/token.json",
      applicantSalt: `0x${"02".repeat(32)}`,
      constructorArguments: [{ target: "launcher" }, description, website, imageUri, xUrl],
      initializer: null,
      deploymentValueWei: "0",
      initializerValueWei: "0",
      componentKind: "token",
      declaredHookPermissions: null,
      runtimeImmutables: runtimeImmutables.token,
    },
    {
      targetId: "hook",
      compilationUnitId: "lucid-graph",
      artifact: "artifacts/hook.json",
      applicantSalt: { mode: "deterministic-hook-permission-grind-v1", start: "0", maxAttempts: "262144" },
      constructorArguments: [
        POOL_MANAGER,
        { target: "token" },
        platformFeeRecipient,
        platformFeePpm,
        guardian,
        agent,
        buyback,
        treasury,
        liquidityVault,
      ],
      initializer: null,
      deploymentValueWei: "0",
      initializerValueWei: "0",
      componentKind: "hook",
      declaredHookPermissions: HOOK_PERMISSIONS,
      runtimeImmutables: runtimeImmutables.hook,
    },
  ],
  pool: { tokenTargetId: "token", hookTargetId: "hook", fee: 0, tickSpacing: TICK_SPACING, quoteCurrency: NATIVE_ETH },
  projectMetadata: {
    schemaVersion: "programmable.project-metadata-input.v1",
    token: { name: "LUCID", symbol: "LUCID" },
    presentation: {
      description,
      image: { sourcePath: imageSourcePath, uri: imageUri },
      links: [
        { kind: "website", uri: website },
        { kind: "x", uri: xUrl },
      ],
    },
  },
  launchProfile: {
    schemaVersion: "programmable.direct-native-hook-graph-profile-selection.v3",
    profileId: "programmable.direct-native-hook-graph.v1",
    profileRevision: 3,
    targetRoles: { tokenTargetId: "token", hookTargetId: "hook", initializerTargetId: "launcher", platformFeeBindingTargetId: "hook" },
    liquidityModel: {
      schemaVersion: "programmable.direct-native-liquidity-model-intent.v1",
      model: "launch-seeded-concentrated-liquidity",
      declaredLaunchState: "assessment_required",
      liquidityTargetId: "launcher",
      assessment: {
        schemaVersion: "programmable.direct-native-liquidity-model-assessment.v1",
        status: "required",
        requestClaimsExecution: false,
        requiredVectorIds: [
          "liquidity.seeded.pool-active-liquidity",
          "liquidity.seeded.position-custody-and-withdrawal",
          "liquidity.seeded.buy-and-sell",
        ],
      },
    },
    fundingMode: "wallet-transaction-value",
    accountingMode: "additive-platform-share",
    assessmentBase: "executed-gross-declared-quote",
    feeCurrency: "declared-quote-currency",
    claimMode: "immutable-payout-recipient",
    payoutRecipient: platformFeeRecipient,
    applicantSelectedBuyHundredthsOfBip: applicantBuy,
    applicantSelectedSellHundredthsOfBip: applicantSell,
  },
  permitWindow: { validAfter, deadline },
  agentAttestation: {
    agentId: "lucid-claude-code-builder",
    checkedAt,
    checks: [
      { checkId: "exact-solc-build-matches-forge", evidence: "evidence/build.json" },
      { checkId: "forge-test-suite", evidence: "evidence/forge-tests.json" },
    ],
  },
};
writeFileSync(rel("programmable-launch.config.json"), `${JSON.stringify(config, null, 2)}\n`);

console.log(
  JSON.stringify(
    {
      ok: true,
      config: "programmable-launch.config.json",
      sources: sortedUnits.length,
      standardJsonBytes: standardJsonBytes.length,
      artifacts: artifactDigests,
      forgeBytecodeCrossCheck: forgeMatch,
      runtimeImmutables: Object.fromEntries(Object.entries(runtimeImmutables).map(([k, v]) => [k, v.length])),
      tests: testEvidence.status === "passed" ? `${testEvidence.passed} passed` : testEvidence.status,
      permitWindow: { validAfter, deadline },
      next: "programmable-launch pack --config programmable-launch.config.json --output launch.json",
    },
    null,
    2,
  ),
);
