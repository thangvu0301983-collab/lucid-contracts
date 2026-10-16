# LUCID contracts

LUCID, "the token that dreams awake", is an AI agent that lives inside its own Uniswap v4 pool on Ethereum.
By day it sets its own trading fee inside hard on-chain limits. By night holders write dreams that it paints.
At dawn (06:00 UTC) the winning mood routes the fees: burn, rewards or deeper liquidity.

This repository holds the exact sources of the launch graph submitted to the
[Programmable](https://programmable.market) Ethereum Custom Launch (profile 3.6.0), plus the companion contracts.

## Launch graph (three CREATE2 targets, one transaction)

| Target | Contract | Role |
|---|---|---|
| `launcher` | `src/LucidLauncher.sol` | Initializer. Creates the ETH/LUCID pool, places 100% of the supply as one single-sided position, makes the initial buy for the launch wallet. It has no function that can touch the position again. |
| `token` | `src/LucidToken.sol` | Fixed 1,000,000,000 LUCID minted once to the launcher. No owner, no mint, no pause, no tax. `metadata()` and `tokenURI()` expose the description, website, image and X profile fixed at deployment. |
| `hook` | `src/LucidHook.sol` | Uniswap v4 hook (`beforeInitialize`, `beforeSwap`, `afterSwap`, both swap return deltas, mask `0x20CC`). Takes the fees on the ETH leg of every swap. |

Pool: native ETH (currency0) / LUCID (currency1), LP fee 0, tick spacing 60.

### Fair launch

The whole supply goes into the pool in the launch transaction and stays there forever: no team, treasury,
vesting or presale allocation exists, and no contract can remove the liquidity.

### Fees, all on the ETH leg of a swap, rounded down

- Programmable platform fee: `platformFeePpm` (3,000 ppm = 0.30%) paid atomically to the immutable
  `platformFeeRecipient` inside the swap. Both are constructor values, capped at 1% (`MAX_PLATFORM_FEE_PPM`).
- Project fee: set by the agent inside stage limits (1.00% at launch, never above 3%), with a launch flinch:
  buys in the first 5 minutes pay an extra fee decaying linearly from 3% to 0 (sells never pay it).
- Maximum all-in fee: 4.3% on a buy in the launch second, 3.3% at any other time. The pool's LP fee is 0.
- Project fee split: 60% follows the night's winning mood (burn: buyback vault, reward: synapse pool,
  deepen: liquidity vault), 30% to the treasury, 10% to the synapse pool. No contract spends treasury ETH at a
  market price: buybacks, burns and liquidity adds from the vaults (a Safe) are executed manually by its owner.

### Roles

- Agent (hot wallet): sets the project fee inside stage limits (Newborn 1% locked; Infant 0.75-1.5%, step 0.25,
  6 h cooldown; Child 0.5-2.5%, step 0.5, 2 h; Adult 0.5-3%, step 0.5, 1 h), picks the nightly route once per
  20 hours, pays holder rewards capped at 10% of the synapse pool per payment and 25% per day.
- Guardian (a Safe): replaces the agent, the fee recipients or itself (or renounces), sets hook metadata,
  triggers safe mode (fee back to 1%, agent limited for 14 days). Anyone can trigger safe mode after 7 days of
  agent silence. Nobody can mint, pause, block transfers or remove the pool liquidity.

Companion contracts, not part of the launch graph: `LucidDreams.sol` (dream paintings as ERC-721 with a small
market) and `LucidNightAuction.sol` (the Night Sale of LUCID's own painting).

## Build and test

Foundry, solc 0.8.26, optimizer 1000 runs, `cancun`, no via-IR, no CBOR metadata (see `foundry.toml`).
Dependencies are vendored under `lib/` so the build is self-contained.

```bash
forge build
forge test
# full launch through Programmable's Router on a mainnet fork:
ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-contract LucidLaunchForkTest -vv
```

## Programmable packaging

`programmable/build.mjs` compiles the three targets with exact solc `0.8.26+commit.8a97fa7a` (it fails if the
bytecode differs from Foundry's), binds every runtime immutable, records build and test evidence, and writes
`programmable-launch.config.json` for the official CLI (`@programmable/launch` 4.1.6, from its immutable GitHub
release). See `programmable/README.md` for the exact commands. The CLI and the API never sign or broadcast:
the launch wallet reviews and signs the final Router transaction itself.

## License

LUCID sources: MIT. Vendored dependencies keep their own licenses (see each folder under `lib/`).
