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
- **Execution gas** is effectively 32M per block. The largest deployment transaction is 10.2M (a ForgePool with its annex), and the heaviest measured settlement page is 5.4M.

## What gets deployed

`contracts/script/DeployTestnet.s.sol` deploys the built core through CreateX's CREATE3, as spec v5.5 §23 does for the canonical deployment. The Mantle, EMBER, ForgeEmissions, Boost and the four pools name each other in their constructors, so the script predicts every address first and fails if CreateX returns a different one.

| Contract | What it is here |
|---|---|
| EmberToken, Mantle, ForgeEmissions, Boost | the built contracts, unchanged |
| ForgePool 0 (EMBER/USDC LP) and its annex | built; stakes **tBLAST-LP**, a stand-in, because BlastPool is not built |
| ForgePool 1 (EMBER/WETH LP) and its annex | built; stakes **tSMELT-LP**, a stand-in, because SmelterPool is not built |
| ForgePool 2 (EMBER) and its annex | built; stakes this deployment's EMBER |
| ForgePool 3 (USDC) and its annex | built; stakes **tUSDC** (6 decimals), a stand-in, unless `FURNACE_TESTNET_USDC` names an existing token |
| ForgeLens | built; read API for a frontend |
| TestnetValuation | **stand-in** for the protected valuation source: the operator sets each pool's rate by hand (zero gives no Capstone bonus) |
| TestnetPyreLedger | **stand-in** for the Relics Pyre ledger: the operator records burns by hand |

The stand-ins live in `contracts/script/testnet/` and never in `contracts/src`. The faucet tokens can be minted by anyone, up to 1,000,000 per call.

**The operator's wallet** holds every slot whose module is not built. It is the deployer unless `FURNACE_TESTNET_OPERATOR` says otherwise. So it:
- is Kindling: it can call `mintKindlingSeed()` once and receive 420,000 test EMBER;
- is the Treasury, which receives vesting;
- is each pool's fee collector;
- is the Deed market, the only caller of `list` and `settle`;
- is ForgeEmissions' match reserve and Sealed-pot consumer.

On mainnet each of those is an immutable contract at a mined address. That is why this kit refuses any chain outside its testnet list (4441, and 31337 for local runs).

**Salts** are bound to the deployer and, by CreateX's 0x01 flag, to the chain, so they can never reproduce an address on another chain. The canonical registry's mined salts are not used. `FURNACE_TESTNET_SALT_VERSION` (default `1`) picks a fresh set; reusing one reverts before it spends gas.

## Deploying

1. **Use a key that will only ever hold testnet funds**, never a mainnet key. With Foundry installed locally:
   ```sh
   cast wallet new                                    # note the address; keep the key offline
   cast wallet import furnace-liteforge --interactive # stores it encrypted in ~/.foundry/keystores
   ```
2. **Fund it from the faucet.** The rehearsal estimated 65.8M gas with the smoke actions, about 0.0013 zkLTC at the 0.02 gwei it saw. Take a few times that for headroom.
3. **Dry run as your address.** Salts bind to the sender, so the addresses printed are the ones the broadcast will use:
   ```sh
   FURNACE_TESTNET_SMOKE=1 pnpm testnet:dry-run --sender <your address>
   ```
4. **Broadcast.** `--slow` waits for each receipt, since later constructors read earlier contracts:
   ```sh
   FURNACE_TESTNET_SMOKE=1 pnpm testnet:deploy --account furnace-liteforge --sender <your address>
   ```
   This writes `deployments/testnet-4441.json`. Commit it with the `broadcast/` record.
5. **Verify on Blockscout.** This has not been run, because it needs a real deployment. If it fails, the deployment stands, and verification can be retried with `--resume`:
   ```sh
   pnpm testnet:deploy --account furnace-liteforge --sender <your address> --resume \
     --verify --verifier blockscout --verifier-url https://explorer.testnet.liteforge.zeeve.net/api/
   ```

**Environment variables** (all optional):
- `FURNACE_TESTNET_OPERATOR`
- `FURNACE_TESTNET_SALT_VERSION`
- `FURNACE_TESTNET_START`: the Mantle's start; default now
- `FURNACE_TESTNET_USDC`
- `FURNACE_TESTNET_SMOKE=1`: one position in each pool, a Capstone deposit and a cooling request

## After deploying

- **Settlement is permissionless and daily.** After each epoch ends: `Mantle.finalizeEpoch()`, then `ForgeEmissions.openEpoch()`, then `ForgeEmissions.advance(epoch, pool)` for each pool until its phase is `Done`. The kit's test runs exactly this, and every pool's position earns.
- **To see Boost raise a bonus**, set a rate as the operator, for example `TestnetValuation.setRate(0, 5e26)` (0.5 EMBER per stake unit), then call `Boost.refresh(0, id)`.
- **Test tokens**: `TestnetToken.mint(to, amount)` on tBLAST-LP, tSMELT-LP and tUSDC.

## Verification of the kit

- **`contracts/test/DeployTestnet.t.sol`**, offline in CI: CreateX's runtime is etched from `contracts/test/fixtures/createx-runtime.hex`, fetched from LiteForge, and its hash is checked. The tests show:
  - the full wiring;
  - the operator slots;
  - salts bound to deployer, chain and version, and a reused version refused before it spends gas;
  - refusal off the testnet list and without the real CreateX;
  - the smoke actions, then a whole first epoch settled with every pool earning.
- **`pnpm testnet:dry-run`**, on a fork of chain 4441 at block ~70.3M: every predicted address matched the one CreateX returned, the wiring checks and the smoke actions passed, 30 transactions.

## Not shown by the testnet

- Anything about mainnet economics. The stake tokens are faucet tokens, and the rates are set by hand.
- The behaviour of unbuilt modules: the AMM pools, the Deed market, Kindling, Ignition, the fee router and the valuation source.
- Audit status. None of this is audited.
