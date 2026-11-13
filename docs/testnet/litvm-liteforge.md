# Testnet: LitVM LiteForge (chain 4441)

Status: deployment kit ready and rehearsed on a fork of the live chain. Nothing has been broadcast. Testnet only: not audited, not a canonical deployment, and not a launch. The v5.5 deployment gate is Ethereum-only (`canonical/DEPLOYMENT.md`).

## The chain, checked

Values from LitVM's docs, each checked against the chain where possible (November 2026):

| | Value | Checked how |
|---|---|---|
| Network | LitVM LiteForge, an Arbitrum Orbit (Nitro) rollup | docs |
| Chain id | 4441 | `eth_chainId` returns `0x1159` |
| RPC (HTTP) | `https://rpc.testnet.liteforge.zeeve.net/` | answers; the old Caldera endpoints are retired |
| Explorer (Blockscout) | `https://explorer.testnet.liteforge.zeeve.net`, API at `/api/` | docs |
| Faucet | `https://faucet.testnet.liteforge.zeeve.net/` | docs |
| Gas token | zkLTC (testnet) | docs |
| Cancun opcodes | TSTORE/TLOAD, PUSH0 and MCOPY execute | `eth_call` probes. The pool's reentrancy guard uses transient storage, so this one matters. |
| CreateX | at `0xba5Ed099…ba5Ed`, runtime keccak `0xbd8a7ea8…b53f` | byte-identical to Ethereum mainnet's (11,838 bytes) |

Orbit differences from Ethereum that could matter here:
- **`block.number`** is an approximate L1 block number. No Furnace contract reads it.
- **`block.timestamp`** is the sequencer's clock, kept within 24 hours behind and 1 hour ahead. Furnace's clocks are timestamps, so a testnet Streak or epoch can drift by that much.
- **Execution gas** is effectively 32M per block. The largest deployment transaction is 10.98M (a ForgePool with its annex), and the heaviest measured settlement page is 5.4M.
- **Sequencer ordering.** The pairs' 30-minute TWAP (ADR 0015) runs on the sequencer's timestamps.

## What gets deployed

`contracts/script/DeployTestnet.s.sol` deploys the built core and the EMBER pairs through CreateX's CREATE3, as spec v5.5 §23 does for the canonical deployment. The Mantle, EMBER, ForgeEmissions, Boost, the four pools and the two pairs name each other in their constructors, so the script predicts every address first and fails if CreateX returns a different one.

| Contract | What it is here |
|---|---|
| EmberToken, Mantle, ForgeEmissions, Boost | the built contracts, unchanged |
| **BlastPool** (EMBER/tUSDC) and **SmelterPool** (EMBER/tWETH) | built (`EmberPair`, ADR 0015); receipts `tBLAST-LP` and `tSMELT-LP` |
| ForgePool 0 (EMBER/USDC LP) and its annex | built; stakes BlastPool's receipt |
| ForgePool 1 (EMBER/WETH LP) and its annex | built; stakes SmelterPool's receipt |
| ForgePool 2 (EMBER) and its annex | built; stakes this deployment's EMBER |
| ForgePool 3 (USDC) and its annex | built; stakes **tUSDC** (6 decimals), a stand-in, unless `FURNACE_TESTNET_USDC` names an existing token; it is BlastPool's quote too |
| ForgeLens | built; read API for a frontend |
| tWETH | **stand-in** (18 decimals) for SmelterPool's quote, unless `FURNACE_TESTNET_WETH` names an existing token. On LitVM mainnet that asset is undecided: bridged WETH or wrapped zkLTC |
| TestnetValuation | **stand-in** for the protected valuation source: the operator sets each pool's rate by hand (zero gives no Capstone bonus) |
| TestnetPyreLedger | **stand-in** for the Relics Pyre ledger: the operator records burns by hand |
| **Flow** | built (ADR 0016): rebated swaps, zaps in and out, and `zapAndStake`, the fee-free stake of the LP a zap forms into pools 0 and 1. The pairs and the LP pools name its predicted address |
| TestnetFeeRebate | **stand-in** for the Relics fee-rebate perk: the operator sets a wallet's percent with `setRebate`; Flow snaps it down to 25 or 50 |

The stand-ins live in `contracts/script/testnet/` and never in `contracts/src`. The faucet tokens can be minted by anyone, up to 1,000,000 per call.

**The pairs are an add-on.** Forge pools 0 and 1 stake the pairs' predicted addresses, whether the pairs exist yet or not. By default they deploy in the same run. With `FURNACE_TESTNET_PAIRS=later` they are left out: pools 0 and 1 then refuse deposits (an address with no code) and settle empty epochs, until `pnpm testnet:pairs:deploy` deploys the pairs at those addresses from the same deployer. Nothing migrates. A CREATE3 address does not commit to code, so until the pairs exist the deployer alone decides what takes those addresses; ADR 0015 lists the two ways to close that window on mainnet.

**The operator's wallet** holds every slot whose module is not built. It is the deployer unless `FURNACE_TESTNET_OPERATOR` says otherwise. So it:
- is Kindling: it can call `mintKindlingSeed()` once and receive 420,000 test EMBER;
- is the Treasury, which receives vesting;
- is each pool's fee collector;
- is the Deed market, the only caller of `list` and `settle`;
- is ForgeEmissions' match reserve and Sealed-pot consumer;
- is each pair's **initializer** (Kindling's slot: the first deposit, which sets the price), its **fee router** (the Vent's: it alone collects the booked protocol fees) and its **guardian** (it can pause swaps, never redemptions);
- is Flow's **compounder**, the only caller of the Compound waiver (the Stoke-into-LP consumer is not built).

On mainnet each of those is an immutable contract at a mined address. That is why this kit refuses any chain outside its testnet list (4441, and 31337 for local runs).

**Salts** are bound to the deployer and, by CreateX's 0x01 flag, to the chain, so they can never reproduce an address on another chain. The canonical registry's mined salts are not used. `FURNACE_TESTNET_SALT_VERSION` (default `1`) picks a fresh set; reusing one reverts before it spends gas.

## Deploying

1. **Use a key that will only ever hold testnet funds**, never a mainnet key. With Foundry installed locally:
   ```sh
   cast wallet new                                    # note the address; keep the key offline
   cast wallet import furnace-liteforge --interactive # stores it encrypted in ~/.foundry/keystores
   ```
2. **Fund it from the faucet.** The rehearsal estimated 79.7M gas over 44 transactions with the pairs, Flow and the smoke actions, about 0.0016 zkLTC at the 0.02 gwei it saw. Take a few times that for headroom.
3. **Dry run as your address.** Salts bind to the sender, so the addresses printed are the ones the broadcast will use:
   ```sh
   FURNACE_TESTNET_SMOKE=1 pnpm testnet:dry-run --sender <your address>
   ```
4. **Broadcast.** `--slow` waits for each receipt, since later constructors read earlier contracts:
   ```sh
   FURNACE_TESTNET_SMOKE=1 pnpm testnet:deploy --account furnace-liteforge --sender <your address>
   ```
   This writes `deployments/testnet-4441.json`. Commit it with the `broadcast/` record.

   To deploy the pairs later instead, add `FURNACE_TESTNET_PAIRS=later` here, then run `pnpm testnet:pairs:deploy --account furnace-liteforge --sender <your address>` when you want them. It reads the manifest, refuses any sender but the original deployer, and sets `pairsLive` in the manifest.
5. **Verify on Blockscout.** This has not been run, because it needs a real deployment. If it fails, the deployment stands, and verification can be retried with `--resume`:
   ```sh
   pnpm testnet:deploy --account furnace-liteforge --sender <your address> --resume \
     --verify --verifier blockscout --verifier-url https://explorer.testnet.liteforge.zeeve.net/api/
   ```

**Environment variables** (all optional):
- `FURNACE_TESTNET_OPERATOR`
- `FURNACE_TESTNET_SALT_VERSION`
- `FURNACE_TESTNET_START`: the Mantle's start; default now
- `FURNACE_TESTNET_USDC`, `FURNACE_TESTNET_WETH`: existing testnet tokens instead of the stand-ins (the smoke actions mint them, so they must be mintable)
- `FURNACE_TESTNET_PAIRS=later`: leave the EMBER pairs for `testnet:pairs:deploy`
- `FURNACE_TESTNET_SMOKE=1`: first liquidity in both pairs (50,000 EMBER with 50,000 tUSDC; 20,000 EMBER with 10 tWETH), one position in each pool, a buy and a sell on BlastPool, a 100 tUSDC zap staked fee-free through Flow into the pool-0 position, 1 LP returned to that position's first lot by the operator as compounder, a Capstone deposit and a cooling request

## After deploying

- **Settlement is permissionless and daily.** After each epoch ends: `Mantle.finalizeEpoch()`, then `ForgeEmissions.openEpoch()`, then `ForgeEmissions.advance(epoch, pool)` for each pool until its phase is `Done`. The kit's test runs exactly this, and every pool's position earns.
- **To see Boost raise a bonus**, set a rate as the operator, for example `TestnetValuation.setRate(0, 5e26)` (0.5 EMBER per stake unit), then call `Boost.refresh(0, id)`.
- **Test tokens**: `TestnetToken.mint(to, amount)` on tUSDC and tWETH.
- **Through Flow.** `Flow.swap`, `zapIn`, `zapAndStake` (position 0 opens one; any other id adds to your own) and `zapOut`, each with a deadline and a minimum. To see a rebate, have the operator call `TestnetFeeRebate.setRebate(wallet, 50)`: that wallet's swaps then book half the protocol share.
- **Source-lot additions.** The operator stands in for the compounder on pools 0 and 1: `ForgePool.addToLot(id, slot, amount)` returns LP to an active lot at that lot's own age, with no fee and no new slot (ADR 0017). The real compounder, which would fund this from earned rewards and the match reserve, is not built.
- **Trading and liquidity.** `EmberPair.buy`, `sell`, `addLiquidity` and `redeem`, with `quoteBuy` and `quoteSell` for previews. Fees are booked by lane; the operator, as fee router, pulls them with `collectProtocolFees()`. `consult(1800)` returns the 30-minute TWAP once the pair is 30 minutes old; anyone can `checkpoint()` to keep observations fresh.

## Use the dApp

The deployment writes `deployments/testnet-4441.json`; the dApp reads it, with `abi/`, when it builds.
1. `pnpm app:build`, then serve `apps/forge-app/dist` (or `pnpm app:dev` locally).
2. Connect a wallet. If it is on another chain, the app offers to switch, and adds LiteForge when the wallet does not know it.
3. Get zkLTC from the faucet for gas, then mint tUSDC or tWETH under *Test tokens*.
4. Under *Zap & stake*, pay tUSDC (or EMBER) into a position. The route cards show what Flow stakes fee-free against what a deposit would keep.

Each action asks first for an approval of exactly the amount it spends, unless an earlier one still covers it. The app never sees a key; the wallet signs. Before the kit is broadcast, or if the manifest is missing, the app shows *Not deployed yet* and quotes on simulated reserves.

## Verification of the kit

- **`contracts/test/DeployTestnet.t.sol`**, offline in CI: CreateX's runtime is etched from `contracts/test/fixtures/createx-runtime.hex`, fetched from LiteForge, and its hash is checked. The tests show:
  - the full wiring;
  - the operator slots;
  - salts bound to deployer, chain and version, and a reused version refused before it spends gas;
  - refusal off the testnet list and without the real CreateX;
  - the smoke actions, then a whole first epoch settled with every pool earning.
- **The add-on**, offline: with the pairs left out, pools 0 and 1 refuse deposits and the first epoch settles with them empty; after the pairs deploy at the predicted addresses, pool 0 takes LP and earns. A stranger with the same salts lands on another address, and a second deployment is refused.
- **`pnpm testnet:dry-run`**, on a fork of chain 4441, with the pairs, Flow and the smoke actions (the zap-and-stake and a source-lot addition included): every predicted address matched the one CreateX returned and the wiring checks passed. That was 44 transactions, the largest 10.98M gas (a ForgePool, whose initcode embeds its larger annex since ADR 0017).
- **If the dry run fails with "refused stream"**, the RPC is refusing forge's burst of requests; a single `eth_chainId` still answers. Retry a little later: the Flow rehearsal got through on its fourth attempt.

## Not shown by the testnet

- Anything about mainnet economics. The stake tokens are faucet tokens, and the rates are set by hand.
- The behaviour of unbuilt modules: Relics (which decides a wallet's rebate tier), the compounder, the Deed market, Kindling, Ignition, the fee router and the valuation source.
- Audit status. None of this is audited.
