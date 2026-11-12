# ADR 0015: The EMBER pairs, BlastPool and SmelterPool

Status: accepted for this repository. Not audited, not deployed.

## Context

**What the spec requires** (v5.5 §13, §14 and §23; `CONTRACTS.md`; the config's `fees.swap`, `swap`, `fees.burnLane`, `fees.liquidityLane`, `security` and `deployment.evm.contracts`):
- **Two independent pairs.** "BlastPool / SmelterPool: separate full-range CPMM receipts. Explicit collateral identity for each pool." BlastPool is EMBER/USDC and SmelterPool is EMBER/WETH. Forge pools 0 and 1 stake their receipts.
- **The fees** (§14). Buys pay 25 bps and sells 35 bps. LP fees are 20 bps both ways.
  - The protocol's share on a buy is 2.5 burn and 2.5 liquidity.
  - On a sell it is 5 burn, 5 liquidity and 5 Quote yield.
  - The half-bps parts need ppm (`CONTRACTS.md`). The swap fee ceiling is 100 bps (`security.feeCeilings.swapBps`).
- **Rebates and waivers.** At Bedrock's 50% rebate the totals are 22.5 and 27.5 bps, "not half the entire trading fee". The rebate is "funded pro-rata from the burn/liquidity/quote-yield slices". `waiveProtocolShareOnCompound` waives the protocol share for a Compound. "Internal settlement exemptions are authorized action paths, not user-set flags. Off-protocol routers cannot obtain special Compound privileges by pretending to be Forge" (§14). Flow holds "authenticated swaps and optional owner-authorized zaps. Waivers are action capabilities, never user-provided flags" (`CONTRACTS.md`).
- **Quote yield is paid in the quote asset.** "Quote yield is funded from the sell-side protocol share in the pool's actual quote asset" (§12).
- **The Vent books fee liabilities** and converts them later, through a 1800-second TWAP with a 2% band (§13).
- **Permanent liquidity.** It "must be full-range". "Never call an AMM's redemption `burn()` and call that permanent liquidity" (§13).
- **Pausing.** `security.pausable` is `{ swaps: true, withdrawalsNever: true }`.
- **Kindling initializes the pools.** Its job includes "safe aggregate pool initialization" (`CONTRACTS.md`).
- **Deployment.** The registry reserves `BlastPool` (prefix F001) and `SmelterPool` (F002) as CreateX CREATE3 entries (§23).

**The add-on.** Forge pools 0 and 1 take their stake token as an immutable constructor argument, and no constructor reads it. So the core can be deployed now with pools 0 and 1 naming the pairs' predicted addresses. Those two pools stay inert, because any deposit reverts on an address with no code. They activate, with no migration, once the pairs are deployed at exactly those addresses.

## Decision

**1. One contract, `EmberPair`, deployed twice.** Each pair is its own receipt: an ERC-20 whose units are shares of the pair's reserves.
- **Immutables:** `EMBER`, `QUOTE` (USDC for BlastPool, WETH for SmelterPool), `FEE_ROUTER`, `FLOW`, `GUARDIAN` and `INITIALIZER`.
- **The constructor checks** that EMBER has 18 decimals, that the quote has 18 or fewer, and that the two tokens differ. It also requires a nonzero EMBER, quote, fee router and initializer.
- **There is no factory, admin, upgrade, delegatecall, flash swap or callback.**

**2. Swaps are exact-in and pull-based.**
- `buy(quoteIn, minEmberOut, to)` and `sell(emberIn, minQuoteOut, to)` pull the input from the caller with `transferFrom`. They then check that the pair received exactly that amount, so a fee-on-transfer token reverts `NonStandardToken`. A rebasing token cannot be detected this way and is not supported; USDC and WETH are neither.
- There are no callbacks and no optimistic transfers, so no flash swap. The guard is OpenZeppelin's transient-storage reentrancy guard, as in ForgePool.
- Exact-out, deadlines and multi-hop routing belong to Flow.

**3. Every fee is taken in the quote asset.** A buy's fee comes from its input, and a sell's from its output.
- **Why the sell's comes from the output.** The sell's Quote yield must be in the quote asset (§12). The burn and liquidity lanes then hold quote too, and that is what the Vent spends: the burn lane is "unwind and buy back", and the match reserve pairs quote with EMBER. EMBER never accumulates in the pair as a fee.
- **The rule, with `g` as the fee base** (the quote in on a buy, the gross quote out on a sell):
  - `lp = ⌈g · 2000 / 10⁶⌉`;
  - each protocol part is `⌈g · part_ppm · s / 10¹²⌉`, where `s` is in [0, 10⁶];
  - the fee is `lp` plus the protocol parts, and the swap reverts unless the fee is below `g`.
- **Every component rounds up, toward the pair.** So no fee component rounds to zero on a trade large enough to pay it.
- **Where the fees go.** The LP fee stays in the reserves, which raises k. The protocol parts accrue outside the reserves, in three ledgers: burn, liquidity and Quote yield.
- **The rates come from the config.** The generator emits them as ppm constants. It fails the build if the parts do not sum to each side's total, if either total exceeds the 100 bps ceiling, if a treasury share is nonzero (the pair implements none), or if `swap.amm` is not `protocol-cpmm`.

**4. Rebates and waivers are a capability of Flow only.**
- `flowBuy` and `flowSell` take the protocol-share scale `s` and accept only the immutable `FLOW` as caller:
  - 10⁶ charges the full protocol share;
  - 5·10⁵ is Bedrock's 50% rebate;
  - 0 is a Compound's waiver.
- **The LP fee is never reduced.** The rebate comes pro-rata out of each protocol slice, as the config says. With `s` = 5·10⁵ a buy pays 22.5 bps and a sell 27.5 bps, of which 2.5 bps is Quote yield. These are exactly §14's figures.
- Public callers always pay `s` = 10⁶. Flow, which is not built, decides who qualifies: it checks the Relic, or that the caller is the Forge's Compound path. There is no user flag.

**5. Protocol fees are booked in the pair and pulled by the Vent.**
- `collectProtocolFees()` accepts only `FEE_ROUTER` as caller. It sends the three ledgers' total in the quote asset and returns each lane's amount, so the Vent books burn, liquidity and Quote-yield liabilities on receipt.
- The pair calls nothing on the router. Until the router collects, the fees sit in the pair, outside the reserves.

**6. Liquidity.**
- **The first deposit sets the price, and only `INITIALIZER` may make it.** That is Kindling on mainnet. Anyone could otherwise front-run Kindling at a bad price, and Kindling's own minimum amounts would then make its launch revert.
- **The first deposit mints `√(ember · quote · 10^(18 − quote decimals))` receipt units.** The quote is scaled to 18 decimals, so a receipt unit means about the same on both pairs. (Unscaled, 0.0001 LP, the Forge's `MIN_STAKE_LP`, would be about $200 of an EMBER/USDC pair at parity.)
  - 1,000 units go to the config's burn address. They are a floor under the share price, not permanent liquidity.
- **Later deposits.** `addLiquidity(emberDesired, quoteDesired, emberMin, quoteMin, to)` takes the largest amounts at the current ratio. It mints the smaller of the two pro-rata shares, rounding down, so rounding always favours existing holders.
- **`redeem(liquidity, emberMin, quoteMin, to)` pays the receipt's pro-rata reserves in kind.**
  - Rounding is down.
  - It has no fee and reads no oracle.
  - It works while swaps are paused.
  - It is named `redeem`, never `burn` (§13).
- **The reserves are internal, and balances are never read as reserves.** A donation therefore changes nothing: it cannot inflate the share price for a first-depositor attack, and it cannot move the price or the oracle. There is no `sync` or `skim`, so donated tokens stay inert in the pair.

**7. The oracle.**
- **A cumulative price.** The pair keeps a wrapping cumulative of EMBER's price in quote, as a UQ112.112 fraction times seconds, updated before the first reserve change in each block.
- **Observations.** It also keeps a ring of 8 observations, written at most once every 300 seconds (the config's 1800-second TWAP divided by 6). Swaps, liquidity changes and a permissionless `checkpoint()` write them.
- **`consult(window)` returns the average price** since the newest observation at least `window` seconds old, and the span it actually covers. That span can be longer than `window` when trading was sparse; the average is still exact, because the price is constant between updates. It reverts `OracleNotReady` while no observation is old enough.
- **Consumers decide what to accept.** The Vent applies its band and the valuation source its staleness rule.
- **For the valuation source (not built).** A manipulation-resistant value of one receipt in EMBER is `2·√(k / p) / supply`, where `p` is that TWAP:
  - swaps only raise k;
  - adding and redeeming move `√k` and the supply in proportion.
- **No claim of manipulation immunity is made** (§25). Moving a 30-minute average still costs an attacker holding a price against arbitrage on a sequencer-ordered chain.

**8. Pausing swaps, never redemptions.**
- `GUARDIAN` may pause and unpause the four swap functions.
- A pause does not affect adding liquidity, `redeem`, `checkpoint`, or the router's collection.
- The guardian cannot touch reserves, fees or receipts. A zero guardian makes swaps unpausable.

**9. Activation as an add-on.**
- **Each pair deploys through CreateX's CREATE3** under its registry label. Forge pools 0 and 1 name the predicted addresses, which the deploy kit checks. The pairs can be deployed in the same broadcast or later from the same deployer.
  - Before then, a deposit in pool 0 or 1 reverts and the pool stays empty.
  - Settlement already handles an empty pool: its budget is retained, not credited to a later depositor (ADR 0005).
- **The trust window.** A CREATE3 address commits to the deployer and salt, not to code. Until the pairs exist, the deployer alone decides what code takes those addresses, and pools 0 and 1 would accept it as their stake token. The testnet kit therefore deploys the pairs in the same run by default.
  - **For mainnet** there are two ways to close the window, and choosing is a canonical deployment decision for the project owner:
    - deploy the pairs in the same broadcast as the core;
    - or move these two entries to CreateX's CREATE2, whose address also commits to the code and constructor arguments. That is a change to §23.

## What this does not decide

- **SmelterPool's quote asset on LitVM.** The config pairs EMBER with WETH. On LitVM that could be bridged WETH or wrapped zkLTC; this is the project owner's call. The testnet uses a tWETH stand-in.
- **Flow itself:** zaps and unzaps, exact-out, routing, and the Relic check behind a rebate.
- **The Vent's conversion, the valuation source and Kindling's initialization**, which the pair only serves.
- **Paying Quote yield out to eligible stakers** (§12, weighted by stake × Heat²). The pair only books it.

## Size and gas

- **Size.** EmberPair is 11,146 runtime bytes, 13,430 under EIP-170.
- **Gas** (`pnpm gas`, isolated, so every call starts cold):

| Path | Gas |
|---|---:|
| `addLiquidity`, the first deposit | 252,498 |
| `buy`, writing an observation | 173,852 |
| `buy`, a second one in the same block | 88,572 |
| `sell` | 95,081 |
| `addLiquidity` | 111,973 |
| `redeem` | 86,602 |
| `consult` | 17,255 |

## Verification

- **Unit tests:**
  - every fee component on both sides, with rounding, at `s` = 10⁶, 5·10⁵ and 0;
  - the 22.5 and 27.5 bps totals;
  - the access checks;
  - the first deposit's initializer gate, the burn-address minimum and the decimals scaling;
  - adds at and off the current ratio;
  - redeem while paused;
  - nonstandard-token rejection;
  - donations having no effect;
  - the oracle's windows and `OracleNotReady`;
  - collection by the router.
- **Differential vectors.** A BigInt model (`scripts/pair-model.ts`) computes swap outputs, fee parts, liquidity and redemptions independently of the contract. The generator writes them to `contracts/test/fixtures/pair-vectors.json`, and the contract matches them exactly.
- **Invariants** over random swaps, Flow swaps, adds, redeems, donations, pauses, collections and time:
  - k never decreases outside a redeem;
  - the reserves plus booked fees equal the pair's balances, less donations;
  - the receipts are backed, and redeeming every holder's receipts leaves the locked minimum's reserves;
  - the fees booked equal the fees charged;
  - a round trip never returns more than it put in;
  - the cumulative price never decreases in time.
- **Add-on activation.** The deploy kit's test:
  - with the pairs left out, pools 0 and 1 refuse deposits and the first epoch settles with them empty;
  - the pairs then deploy at the predicted addresses, pool 0 takes LP, and the next epoch pays it;
  - a stranger using the same salts lands on another address (`AddressMismatch`), and a second deployment is refused (`PairsAlreadyLive`).
- **Rehearsal.** `pnpm testnet:dry-run` with the pairs and the smoke actions, on a fork of LiteForge, ran 39 transactions; the largest was 10.2M gas (a ForgePool).
- **Mutations:** planted bugs on these paths, each of which must be caught (see the README).

## Consequences

- **Forge pools 0 and 1 have a real stake token on testnet.** The testnet manifest names the pairs, and `pnpm abi` exports `EmberPair`.
- **Every protocol swap fee arrives at the Vent in the quote asset, split by lane.**
- **Flow must exist before rebates or the Compound waiver work.** Until then every swap pays the full fee, which is the conservative direction.
- **Not audited or deployed.**
