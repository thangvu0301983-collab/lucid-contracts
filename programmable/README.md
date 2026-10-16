# Packing the LUCID Custom Launch request

Requirements: Node 24.14+, Foundry, `npm install` in the repository root (installs `solc` 0.8.26), and the
Programmable Launch CLI 4.1.6 installed from its verified immutable release:

```bash
d="$(mktemp -d)"; u=https://github.com/programmablehq/PROGRAMMABLE/releases/download/programmable-launch-v4.1.6
curl -fL -o "$d/programmable-launch-4.1.6.tgz" "$u/programmable-launch-4.1.6.tgz"
curl -fL -o "$d/programmable-launch-4.1.6.tgz.sha256" "$u/programmable-launch-4.1.6.tgz.sha256"
(cd "$d" && sha256sum -c programmable-launch-4.1.6.tgz.sha256)   # a6d7f5ef…202e8f
npm install --global "$d/programmable-launch-4.1.6.tgz"
```

## 1. Public inputs (environment)

| Variable | Meaning |
|---|---|
| `LAUNCH_WALLET` | Controller wallet bound to the Programmable API key. Sends the launch transaction, pays the initial buy, receives the LUCID it buys. |
| `GUARDIAN` | Guardian (a Safe): can ground the agent, set hook metadata. |
| `AGENT` | The agent's hot wallet: sets the fee inside stage limits and the night action. |
| `BUYBACK`, `TREASURY`, `LIQ` | Fee destinations (Safes). |
| `PROJECT_DESCRIPTION` | Optional override of `programmable/description.txt`: the full public disclosure, also stored in the token forever. No quotes, backslashes or line breaks. |
| `WEBSITE_URL` | `https://` website, stored in the token forever. |
| `IMAGE_URI` | Public `https://` URL serving exactly `assets/lucid-logo-1024.png` (CORS-readable), stored in the token forever. A commit-pinned `https://raw.githubusercontent.com/<owner>/<repo>/<commit>/assets/lucid-logo-1024.png` works. |
| `X_URL` | Default `https://x.com/lucid_agent`. |
| `SOURCE_URL`, `SOURCE_REVISION` | This public repository and the exact commit being submitted. |
| optional | `INITIAL_BUY_WEI` (0.001 ETH), `LAUNCH_TICK` (196200), `PLATFORM_FEE_PPM` (3000), `PLATFORM_FEE_RECIPIENT` (`0xD88539d3c4C460136a733A3Fd60cf6BF269079da`), `APPLICANT_BUY_HBIP` (40000), `APPLICANT_SELL_HBIP` (30000), `VALID_AFTER` / `DEADLINE` (now, +24 h), `LAUNCH_NONCE` (random). |

The platform fee values must equal `currentTradeFeePolicy` in https://api.programmable.market/v3/capabilities
at packing time; the CLI refuses a mismatching payout recipient.

## 2. Build, pack, validate

```bash
forge build
node programmable/build.mjs              # runs forge test and writes programmable-launch.config.json
programmable-launch pack --config programmable-launch.config.json --output launch.json
programmable-launch validate launch.json --config programmable-launch.config.json
programmable-launch validate launch.json --config programmable-launch.config.json --remote   # preflight, needs PROGRAMMABLE_API_KEY
```

On Windows add `--import ./programmable/win-dir-fsync-shim.mjs` after `node` when running the CLI's
`bin/programmable-launch.mjs` (Windows refuses fsync on a directory; the shim ignores only that case).

Preflight persists nothing, allocates no nonce and consumes no launch quota.

## 3. Submit and launch

```bash
programmable-launch submit launch.json --config programmable-launch.config.json
programmable-launch status <REQUEST_UUID> --watch --until authorized
```

Programmable reviews manually (target 24 hours). At `authorized`, open the returned `walletHandoffUrl` with the
launch wallet, review the exact Router transaction (value = `INITIAL_BUY_WEI`) and sign it there, before the
approval expires. Then:

```bash
programmable-launch status <REQUEST_UUID> --watch --until finalized
```

Never reuse request bytes with a new idempotency key, and never resend after a timeout without reconciling.
