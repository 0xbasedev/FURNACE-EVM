# FURNACE Protocol — Complete Specification · v5.4.0

> The single source of truth is `furnace.config.ts` v5.4.0. This document explains it.
> Every number below is a field in that file. A rebrand edits the config;
> this document then describes the new brand automatically.
>
> Config hash: `0x22c9dea60d12ac753e5eb02e64810514f4cbaec5e0ee65d998d19666d82a33b0`
> (recompute with `pnpm config:hash`; record on-chain at deploy)

## 0. The idea

FURNACE is an omnichain loyalty-staking protocol. Users stake liquidity, earn
emissions weighted by how long they have stayed, and 80% of every fee the
protocol touches burns the token or deepens its liquidity. The other 20% is
named and fixed: 10% to ASH stakers in the Hearth, 10% to the treasury. No
fee is ever paid to a team wallet. Nothing is ever locked: every timer starts
when the user clicks, and the only instant, free, timer-free action is
compounding. Time in the pool is the yield — and time is an asset: a position
is a Deed, an NFT that can be sold without a single token leaving the pool.

Five ideas carry the design. Everything else is a parameter.

1. Time is the yield. Heat grows on the square-root curve from 1.0× to 2.5×
   over a year, plus prorated milestone bumps to 3.0×. Early loyalty pays
   hardest; diminishing returns keep a two-year position from lapping a
   one-year one.
2. Fees never pay the team. 80% of every fee is routed to burning EMBER or
   deepening permanent liquidity; the other 20% is named and fixed — 10% to
   ASH stakers in the Hearth as real yield, 10% to the treasury. None of it
   is salary.
3. Ashfall closes the loop. Prior-epoch burns re-emit to Flame+ stakers
   weighted by stake × Heat², at source-specific recycle rates. Sellers and
   leavers fund stayers.
4. Compound is the only door with no lock. Stoking is instant, free, and the
   only action that grows a hot position without resetting age — rewards
   compound back into the lot that earned them, at that lot's age.
5. Genesis creates liquidity, not sellers. Kindling is a clearing-price
   auction: 90% of the LP becomes depositors' auto-staked Deeds, 10% burns
   forever, atomic in the close transaction. Nobody gets loose tokens; the
   pool exists before the next block.

## 1. Tokens

Three things that look like tokens. Two of them are tokens.

### EMBER — the protocol token

| Property | Value |
|---|---|
| Hard cap | 21,000,000 |
| Standard | LayerZero OFT v2 (one canonical supply, all chains) |
| Decimals | 18 (EVM) / 9 (Solana), 6 shared decimals for messaging |
| Home chain | Ethereum |
| OFT rate limit | 250,000 / hour |
| Transfer tax | 0% — forever. Fees live on protocol actions, never on transfers. |

**Emissions** follow a Bitcoin-style halving: 21,600 EMBER/day at open
(0.25/second network-wide), 365-day half-life, 1,000/day floor.

**The 21M cap is a live-supply ceiling, not a cumulative-mint ceiling:**
`mint(epoch) = min(targetEmission, 21M − totalSupply)`. The decay curve hits
the 1,000/day floor around day 1,618 (~10.85M emitted); without burns, the
floor would mint past 21M roughly 29.7 years after launch. So the floor is a
*target*, not a promise: burns reopen mint headroom, and the tail continues
only while the deflation engine creates room. Late-stage emissions are
structurally dependent on burns — the protocol must earn its tail. When
headroom runs short, all recipients scale down pro-rata; the build rejects
any config where `supplyCeiling.hardCap ≠ token.maxSupply`.

**Allocations:** 420,000 EMBER (2%) minted once for the Kindling seed;
500,000 to the treasury (no cliff, linear over 365 days); team allocation 0.

### ASH — the share / governance token

| Property | Value |
|---|---|
| Hard cap | 70,000 — nothing else in the protocol can mint ASH |
| Launch share | 41,000 Ignition rewards + 1,000 Kindling bonus |
| Forge share | 28,000, trickled through staking over 730 days |

The validator recursively sums every leaf of the ASH allocation tree and
requires exactly 70,000 — the 71k overallocation bug (42k + 28k + a separate
1k Kindling pool) can never recur. Ignition's reward total and Kindling's
bonus pool are each cross-checked against their tree leaf.

ASH staked in the Hearth earns a cut of every protocol fee plus governance
weight. It is the productive share token: scarce, and it pays.

### Heat — not a token

Heat is a per-position loyalty score: the stake-weighted age of your
liquidity, converted to a yield multiplier.

```
age     = stored lot age, capped at 365 days (it never counts past the cap)
lotHeat = 1.0 + 1.5 × √(age / 365) + bump(age)
bump    = milestone bumps, prorated linearly between milestones (max +0.5×)
Heat(position) = Σ(lot LP × lotHeat) / Σ(lot LP)
```

The curve alone tops out at **2.5×**. Five age milestones (7, 30, 90, 180,
365 days) supply the last 0.5× at +0.1× each, **prorated linearly between
milestones** — so no withdrawal ever falls off a cliff:

| Lot age | Curve | Milestone bumps | Heat |
|---|---|---|---|
| 0 days | 1.00× | 0 | 1.00× |
| 7 days | 1.21× | +0.10 | 1.31× |
| 30 days | 1.43× | +0.20 | 1.63× |
| 90 days | 1.75× | +0.30 | 2.05× |
| 135 days | 1.91× | +0.35 | 2.26× |
| 180 days | 2.05× | +0.40 | 2.45× |
| 365 days | 2.50× | +0.50 | 3.00× |

The square-root shape is deliberate: early loyalty matters most, and
diminishing returns keep a 2-year position from lapping a 1-year one into
irrelevance.

**The bumps belong to the lot's age, not to the badge.** The Relic NFTs
(section 9) are the soulbound record and carry the perks; the +0.1× bumps are
computed from each lot's Heat age. That one rule settles three questions: a
proportional withdrawal cools the bumps along with the age; a Deed buyer gets
the bumps their inherited age has earned and none of the seller's badges; and
a reset wallet that still holds old Relics gets no bumps on new money until
that money ages.

**Proportional cooling, defined per lot.** Executing a withdrawal of fraction
*f* of the position removes *f* of every lot's LP **and** multiplies every
remaining lot's age by (1 − *f*). Without the age step, a pro-rata draw would
leave every lot's age untouched and the withdrawal would cool nothing. Ages
are capped at 365 days **before** scaling, so a two-year lot that withdraws
50% lands at 182.5 days, exactly like a one-year lot; banked age past the
curve can't absorb a withdrawal. Year two pays through Bedrock's perks
(section 9), never through hidden age. One cooling helper implements this —
`heatAgeAfterWithdrawal` delegates to `cooledAgeAfterWithdrawal` — so no
caller gets a different answer for the same input. A Deed buyer's 80% carry
is computed on capped financial age (80% of a 730-day lot is 292 days, not
584); Streak stays chronological and is never capped. Worked examples from a 365-day lot at
3.00×:

| Withdraw | New age | Heat | Cost |
|---|---|---|---|
| 1% | 361.4 days | 2.99× | −0.01× |
| 10% | 328.5 days | 2.90× | −0.10× |
| 50% | 182.5 days | 2.46× | −0.54× |

Taps (section 9) are the exception: they draw the youngest lots first and
cool nothing.

**The global ceiling is 4.15×** = 3.0 Heat + 0.5 Capstone + 0.15 Pyre + 0.5
conviction track — validated in `check:config` against the computed sum.
The conviction term is a cap on what the Conviction bucket can pay
(section 10), so the ceiling holds even when few positions are sealed.

## 2. Ignition — the Genesis phase

The bootstrap. Default **120 hours** (configurable 48h–14d). **Nothing is
ever locked — not even here:** principal can be withdrawn at any time during
Ignition, and the 3% genesis fee is not refunded
(`withdrawDuringWindow: { enabled: true, refundFee: false }`). The **genesis
fee** applies in Ignition, in Kindling, and in every Fissure: **3% of every
deposit goes straight to the treasury address — no splits, no router, no
exceptions.** It is the treasury's only income before the Vent has fees to
route. After close there is a 24-hour free exit window at 0% fee.

| Pool | Asset | Weight |
|---|---|---|
| ign-usdc | USDC | 100 |
| ign-weth | WETH | 100 |
| ign-wbtc | WBTC | 100 |
| ign-eth-usdc-lp | WETH/USDC LP | 150 (LP deliberately favored) |

Rewards are the 41,000 ASH, streamed per second pro-rata on stake × time —
depositing early earns more. No vesting, no lockups on rewards. An
**early-bird bonus** decays from **+10%** reward weight at the first second
to +0% at close (linear) — urgency for the bootstrap without a first-block
landgrab, on top of pro-rata rather than instead of it.

Ignition depositors receive two permanent things: a Heat head start and the
soulbound **First Flame** founder badge.

**Where Ignition principal goes.** EMBER doesn't exist until Kindling closes,
and only USDC has a Forge pool among the four Ignition assets. So at close:

- USDC principal auto-stakes into **Cold Storage**, unless the depositor
  opted out at deposit.
- WETH, WBTC and WETH/USDC LP become claimable, fee-free.
- Every depositor's **Heat head start** (age dated to Ignition start) applies
  to the first Forge Deed they open or fund within 7 days of Kindling close,
  up to the USD value they kept in Ignition through close. A one-click
  "Pair and stake" zap on the claim screen turns WETH into Smelter LP or USDC
  into Blast Furnace LP, buying the EMBER half on Flow.

First Flame carries a **15-day phantom Heat floor** — even after a full
withdrawal resets everything else, a founder's fresh stake accumulates from
day 15 instead of day 0. Selling the wallet is the only way to sell the floor.

## 3. Kindling — the liquidity auction

Kindling replaces "the team seeds the pool" and "snipers own the open." It
is a **24-hour clearing-price auction**: deposit USDC, everyone pays the same
clearing price.

| Parameter | Value |
|---|---|
| Duration | 24 hours |
| Quote asset | USDC |
| EMBER seed | 420,000 (one-time mint, 2% of max) |
| Raise range | $100,000 – $5,000,000 |
| Per-wallet cap | $25,000 |
| Deposit fee | 3% → treasury (the genesis fee) |
| Price mode | Clearing (single price for all) |
| LP destination | **90% auto-staked Deeds owned by depositors · 10% burned forever** |
| ASH bonus pool | 1,000 ASH to participants (the Kindling leaf of the ASH tree) |
| Fallback | Treasury seeding (if min raise not hit; full refunds incl. fees) |

**The depositor accounting hole, closed.** Burning *all* of the Kindling LP
would leave depositors' USDC buying them nothing but a share of 1,000 ASH —
an unspecified donation. Instead: 90% of the Kindling LP becomes auto-staked
Deeds owned by the depositors (pro-rata to their raise contribution), and
10% is burned forever as the irrevocable liquidity floor. Not Bond LP, not
governance-extractable, not a lock — the LP is theirs, staked, earning, and
exitable under normal rules. This is the same mechanic Fissures use for
satellite launches, so Kindling and Fissures are finally consistent.

**What a Kindling depositor actually gets, stated before they deposit.** For
every $100 in: $3 goes to the treasury (escrowed there until close —
refunded with principal if the raise fails), the $97 is paired with EMBER at
the clearing price, and the depositor's Deeds hold 90% of that LP. The
pressure gauge shows three quantities live: the **quote-side claim**
(~$87.30), the **token-side claim** (their share of the seed, marked at the
opening ratio — also ~$87.30), and the **combined opening-ratio LP mark**
(~$174.60). The mark is not a promised cash exit: the token price is set by
the same reserves, selling moves it, and fees and dilution apply. The 12.7%
quote-side cost is the price of a pool that opens un-ruggable and un-sniped,
and the depositor sees it in dollars.

**Atomic pool initialization:** the deposit that pushes the timestamp past the
deadline creates the pool, pairs the assets, mints the depositors' Deeds and
burns the 10% floor **in the same transaction**. Zero MEV window — no block
exists in which the open can be sandwiched. The opening price mathematically
matches the auction's pressure gauge. The close is **permissionless**: anyone
can call it, and the caller earns a **0.05% bounty** from the Treasury's fee
— bots race to close it the second it is due. No EOA to wait for, nothing to
front-run.

## 4. The Forge — staking

The steady-state venue. Four pools:

| Pool | Stakes | Emission weight | ASH weight |
|---|---|---|---|
| Blast Furnace | EMBER/USDC LP | 1000 | 500 |
| Smelter | EMBER/WETH LP | 400 | 200 |
| Ember Vault | single EMBER | 400 | 300 |
| Cold Storage | single USDC | 200 | 0 |

LP pools carry the weight: the protocol rewards liquidity, not idle tokens.
Cold Storage is for the risk-averse and earns no ASH — mercenary-stable
capital gets base emissions and nothing else.

**Fees:** 1% to deposit, 1% to withdraw (taken on execution, never on arming),
0% to claim, **0% to compound — no timer, no age reset.** LP bought on the
native Flow swap stakes with the deposit fee waived; waived zaps earn no
Ashfall that epoch, so the waiver cannot be cycled for rewards.

**Lots.** Every deposit is its own lot with its own age (max 32 lots per
position) — **per-lot accounting**. New money enters at 1.0× and never
inherits old Heat; dust-aging is mathematically dead.

**Provenance-preserving compounding.** Rewards are tracked per lot, and when
Stoke executes, each lot's accrued rewards compound **back into that lot**.
Rewards generated by lot A inherit lot A's age — never the blended position
age, never 1.0×. A 365-day lot cannot launder a 2-day lot's rewards into
365-day Heat, and compounding never dilutes legitimately earned age. The only
way to grow a hot position is to stoke it, and the age you stoke with is the
age you earned.

**Lot exhaustion.** Stoke modifies its reward-producing source lots — it
consumes no lot slot. Casting does the same (section 7): cast LP goes back
into the lot that earned it, so it never needs a slot either. A genuine new
deposit past 32 lots triggers the UI's "Open New Deed" offer (Deeds are
unlimited). Lots are **never** lossy-merged: averaging timestamps under the
square-root Heat function would change reward entitlement.

**Heat vs Streak** are decoupled. Heat is the stake-weighted age that drives
yield; Streak is the chronological clock (days since liquidity last left)
that unlocks Relic perks. Adding money dilutes Heat but never touches the
Streak. Withdrawing any amount resets the Streak to zero — but Heat only
cools **proportionally**: withdraw 10%, keep 90% of your Heat age.

## 5. Deeds — time as an asset

Every position is a **Deed**, an NFT tradable on the in-dapp **Deed Market**
for ETH or EMBER. A sold Deed keeps every token of liquidity in the pool —
selling a position no longer means breaking LP and dumping. It means handing
aged capital to a buyer.

| On sale | What happens |
|---|---|
| LP, Capstone, conviction escrow + remaining term, unclaimed rewards | Transfer to the buyer |
| Heat age | Buyer inherits **80%** — earned time stays worth more than bought time |
| Streak | Resets to 0 for the buyer |
| Badges (Relics, Pyre, First Flame) | Stay with the seller — reputation is earned by a person, age is a property of capital |
| Keystone | **Dual:** the seller's wallet keeps its soulbound Keystone Relic (the *person* completed the term); the Deed carries a permanent Seal Scar in its metadata (the *capital* completed one) |
| Fee | **1%** of the final price into the Vent (50% burn / 50% liquidity) |

**The sale is a 24-hour ascending auction.** The seller sets a reserve price;
the highest bid at close wins; below reserve, the Deed delists. No instant
sales — and that is the point. Three exits, three prices:

| Exit | Speed | Cost |
|---|---|---|
| Emergency exit | Instant, guaranteed | 8% |
| Deed auction | 24 hours, market-priced | 1% + the market's discount |
| Withdrawal timer | 72 hours (full exit) | 1% |

The auction answers the strongest objection to tradable positions — that an
instant 1% sale undercuts the priced escape hatch. It also kills fixed-price
sniping: no bot can steal a mispriced listing. The market prices the exit
instead of the protocol, but it cannot price it at zero time.

**Anti-sniping:** a valid bid inside the final 5 minutes extends the auction
by 5 minutes, capped at 30 minutes total extension. Last-second sniping
becomes last-minute bidding — the extension only triggers on genuine late
competition.

**The rules that keep it honest:**

- Transfers outside the market are **refused by the token itself** — no OTC,
  no gifts, no dark pools. Every sale pays the Vent.
- A Deed with a pending Withdraw or Claim **cannot be listed**.
- Heat is **conserved-minus-haircut** on trade: it can move, never inflate.
  No sale creates a single point of Heat that wasn't earned by waiting.
- The Deed card prices honestly: intrinsic LP + Capstone value, impermanent
  loss against holding the two assets, and the Heat premium the market is
  paying — so bidders see exactly what the age costs.
- A wallet may hold any number of Deeds; deposits go into the Deed you
  choose. Laddering is native.

## 6. Capstone — the conviction sink

An optional EMBER-only lot inside each position. It earns no emissions and
never sells. It adds up to **+0.5× Heat** when the held EMBER is worth half
your LP value, capped there so conviction can never outweigh a year of
staying. Same 1% fee and same withdrawal timer to leave it. It touches
neither Streak nor Heat age.

**Stoking** (compounding) fills the Capstone first, then mints LP whose quote
side comes from the **match reserve** — fee revenue the Vent holds to pair
with Stokes. A zap that sells half the reward is the fallback, and the UI
says so before confirmation. **Stokes never sell by default.**

**AutoStoke is opt-in per position — never open.** The old design let anyone
compound anyone's position for a 1% bounty; on a cheap-gas chain that pays
bots to skim 1% of every position's yield continuously, front-running owners'
own free stokes. Now, by default only the owner stokes. An owner who wants
hands-off compounding enables keepers for that position with three limits:
**tip** 0.1–1% (default 0.5%, contract-capped at 1%), **minimum interval**
≥24h (default 7d), **minimum size** (default 100 EMBER). A keeper stoke that
violates any limit is rejected. `defaultOn: true` fails the build.

## 7. Casting — emissions that are liquidity

**25% of every epoch's EMBER emission is never paid liquid.** The protocol
pairs it with quote asset from the match reserve at pool price, mints LP, and
stakes it **back into the lot that earned it, at that lot's age**. That's the
same provenance rule as Stoke: a cast is a Stoke the protocol does for you on
a quarter of your rewards. The reward *is* liquidity: dumping it costs swap
fees plus the 1% withdrawal fee plus the timer. A 2-day lot's cast lands at 2
days, so no reward can launder into old Heat — and because casting modifies
its source lots, it consumes no lot slot and needs no rolling lot with its
lossy timestamp averaging.

**Pool-specific rule.** Source-lot return works when the earning lot holds
compatible LP collateral. The two single-token pools can't receive LP —
Ember Vault lots hold EMBER, Cold Storage lots hold USDC — so their cast
share is paid **liquid** instead. The protocol never silently changes a
stable-only depositor's exposure and never force-creates an LP position they
didn't ask for.

**Ownership.** LP minted from a user's emission plus match-reserve quote is
100% **user-owned**, staked in their lot — the reserve quote is a protocol
subsidy converting fee revenue into deep, sticky liquidity. It is never
burned. (The Vent's `burnMatchedLp` applies only to the idle auto-pair path:
after 7 epochs with no Stokes/Casts consuming the reserve, the idle quote
pairs with treasury-seeded EMBER and *that* LP is burned as permanent
protocol-owned liquidity.)

Hard invariant: if the reserve cannot cover the quote side, the user receives
liquid EMBER for the uncovered share. The protocol **never market-sells a
user's emission** to complete a cast.

## 8. Pyre — burn-to-mint badges

Burn EMBER to the dead address; the Relics contract mints a soulbound badge:

| Tier | Cumulative burn | Boost |
|---|---|---|
| Cinder | 250 EMBER | +0.05× Heat |
| Wildfire | 1,250 EMBER | +0.05× Heat |
| Conflagration | 6,250 EMBER | +0.05× Heat |

Permanent, account-wide, **capped at +0.15×** — below half the time ramp, so
burning can never outweigh staying. The EMBER is gone, the badge cannot be
sold: a pure deflationary sink that pays in loyalty instead of emissions.
Registered Pyre burns count toward Ashfall at the 25% Pyre rate. The reduced
rate *reduces* self-recapture — it does not eliminate it: a burner holding
eligible weight fraction p can still recapture ~0.25 × p × burn under
pro-rata distribution. The rate stays 25%; the claim stays honest.

## 9. Relics — the milestone NFTs

Soulbound, auto-minted at continuous-staking milestones. A Relic is the
wallet's record and carries the perks below. The +0.1× Heat bump at each of
the first five milestones is computed from lot age (section 1), so it cools,
transfers and resets with the capital, while the badge stays with the person:

| Relic | Days | Perks |
|---|---|---|
| Spark | 7 | Claim timer → 20h |
| Flame | 30 | Claim timer → 16h, Ashfall eligible |
| Blaze | 90 | **Tap:** withdraw 10% / 90d without resetting Streak |
| Inferno | 180 | Claim timer → 12h, Kindling priority |
| Eternal Flame | 365 | Tap 25% / 90d, 2× governance weight, **25% Flow fee rebate** |
| Bedrock | 730 | Tap 25% / **60d**, 3× governance weight, **50% Flow fee rebate** |

Taps draw the **youngest lots first**, so a Tap burns off your most dilutive
deposits and *raises* blended Heat. On reset, badges remain as history but
perks go dormant. Badges never transfer — and Deeds transfer *age*, never
badges. **Bedrock** answers "what does year two pay?": the Heat ramp caps at
365 days, so the second year pays in perks, not multiplier.

## 10. Conviction tracks — sealed escrows

Opt-in bonus tracks layered **on top of** the click-timer, never replacing
it. True **escrows**, not vesting balances:

| Track | Length | Bonus |
|---|---|---|
| Ember | 30 days | +0.15× |
| Forge | 90 days | +0.25× |
| Kiln | 180 days | +0.35× |
| Eternal | 365 days | +0.50× |

**How the escrow works.** Each epoch's total mint is **fixed before any
position weights are evaluated** — then 10% of it is carved out as the
**Conviction bucket**, and the remaining 90% splits 30/70 (27% of the epoch
by stake, 63% by stake × Heat). Sealed positions compete for the bucket by
stake × Heat × sealWeight; the ordinary share stays claimable as always, and
the **bonus share accrues into escrow**.

**The bucket is capped per position — at the additive value of the seal.**
A sealed position's bucket payout can never exceed
`cap_i = L × s_i × b_i / W`, where L is the pre-return Heat budget (63% of
the epoch), s_i the position's stake, b_i its additive seal bonus
(+0.15× to +0.50×), and W = Σ s_j h_j over ordinary (pre-seal) Heat. This
equals (b_i / h_i) × P_i: the bonus's *marginal* worth in the Heat pool.
The naive `b_i × P_i` would overstate the cap by the Heat itself (3.65× at
h = 3.65 — 112 tokens instead of 30.7 on a 10,000-token epoch). Using the
pre-return L keeps the cap non-circular. Whatever the cap holds back — and
the whole bucket in an epoch when nobody is sealed — flows back into the
Heat pool that same epoch. Without the cap, a single early sealer
would collect the entire 10%, and the 4.15× ceiling would be a number in a
doc. Conviction affects *distribution*, never *issuance*: seal bonuses cannot
inflate the epoch. At term end the escrow pays out **into the Capstone by
default** — the bonus never sells. Completing a term earns the **Keystone,
dual**: a soulbound Keystone Relic for the wallet (proof the *person*
completed the term — never transfers) and a permanent **Seal Scar** in the
Deed's metadata (proof the *capital* completed one — always travels with the
Deed).

**Breaking the seal.** Withdrawing LP before term end forfeits the escrow —
**never the principal**. The forfeited bonus routes **50% to the burn lane,
25% to the match reserve, 25% to the Sealed pot**, which streams to every
position still inside its term. The faithless fund the faithful, and the
principal still exits through the normal timer, unslashed.

## 11. Clocks — every timer in the protocol

Standing rule, honored everywhere: **timers start when the user clicks.
Nothing is ever locked.**

**Withdraw — progressive.** Clicking "Start cooling" arms a visible countdown
sized to the exit:

| Exit size | Cooldown |
|---|---|
| ≤ 10% of position | 6 hours |
| ≤ 25% | 12 hours |
| ≤ 50% | 24 hours |
| ≤ 75% | 48 hours |
| 100% | 72 hours |

At zero, the **green "Withdraw Now" button** — the only green in the app —
goes live for a **24-hour execution window**. While cooling, **Heat and
rewards are frozen**: the position neither ages nor earns. Cancel or miss
the window and the position **resumes from the frozen Heat** — the cooling
interval itself did not age, and no LP ever left, so no Heat is lost. Only
actual *execution* triggers proportional cooling and Streak reset. The 1%
fee is taken on execution. Each arm is per-lot.

**Claim** arms a 24-hour visible countdown (shortened by Relic perks),
snapshots rewards at request time, then opens the green Claim Now. No fee;
clocks untouched.

**Compound** is instant, free, and timerless — the only door with no lock.

**Emergency exit** skips every timer for **8%**: 50% burned, 25% to permanent
liquidity, 25% to the stakers who stayed. The **deserter's tithe**: skipping
the timer also forfeits the position's pending Ashfall into the rollover pool
for the loyal. Both clocks reset.

## 12. Emissions, Ashfall, Quote yield

Each epoch's base emission splits **30/70**: 30% by raw stake (the newcomer
floor), 70% by stake × Heat (the veteran gradient). After the 10%
Conviction carve-out (section 10), the ordinary budget is 27% / 63% / 10%;
unallocated bucket returns to the Heat pool, so with nobody sealed the
**effective** split is 27% flat / 73% Heat — not 30/70. (Equal stakes at 1×
and 3× earn 32.5% / 67.5% of the ordinary budget, 31.75% / 68.25% effective
with an empty bucket.)

**Ashfall** re-emits prior-epoch burns (1-epoch lag) to stakers holding Flame
or better, weighted by **stake × Heat²**. Recycle rates are
**source-specific**: protocol-created burns (Forge fees, swap fees,
emergency exits) count at **50%**; registered Pyre burns at **25%**;
unsolicited dead-address transfers at **0%** — a dominant Heat² holder can no
longer partially rebate their own voluntary burn. The token disappears in
every case; only the protocol's definition of "activity that funds stayers"
changes. If nobody is eligible, Ashfall rolls forward — it never vanishes.
Zero-fee Flow zaps are excluded. Ashfall is a mint, so it shares the epoch's
headroom check with base emission: `totalMintForEpoch()` sizes base emission
plus Ashfall together against `21M − totalSupply`, and both scale down
pro-rata when headroom is short — Ashfall can never push supply past 21M on
its own.

**Quote yield:** **5 bps of every Flow sell** paid in the chain's **quote
asset** (never EMBER) to the same Ashfall-eligible set at the same Heat²
weight. Real yield beside emissions, not instead of them.

**The Sealed pot:** forfeited conviction escrows stream to positions still
inside their term. Breaking your word pays everyone who kept theirs.

## 13. The Vent — the fee router

Every Forge fee (1% in, 1% out) splits **40% burn / 40% liquidity /
10% Hearth / 10% treasury** — must sum to 100, enforced in config validation.

**The fee vault.** Fees never hit the pool as they arrive. Every fee on a
chain lands first in the chain's **fee vault**, part of the Vent. A
permissionless `vent()` call processes the vault once it crosses **$5,000** —
and at least once per 24 hours regardless. Gas stays off user transactions,
buys execute in batches, and no keeper is privileged.

**Burn lane** (`unwindAndBuyback`): fee LP is unwound, the EMBER half burned,
the quote half buys back and burns — through an **1800-second TWAP** with
**four-way buy protection**:

| Guard | Value | Why |
|---|---|---|
| Average-price band | Spot within 2% of the 30-min average | A trader can't push the price and sandwich the burn inside one block |
| Slippage cap | Max 1% vs the average | Minimum-output discipline on every buy |
| Chunk size | No buy above 0.5% of the quote reserve | Whale buys wait for the next `vent()` call |
| Fail closed | Unsafe → the quote asset waits in the vault | Nothing is ever lost, only delayed |

Allowlisted routers only; maximum 72-hour deferral. The build refuses a
slippage cap above 1% or a TWAP window under 30 minutes.

**Liquidity lane** (`matchReserve`): fee LP is unwound, the EMBER half burned,
the quote half held in the match reserve to pair with Stokes and Casting.
Matched LP is burned as permanent liquidity. Idle reserve auto-pairs after 7
epochs.

**Invariant: permanently burned liquidity must be full-range /
non-repositionable.** A burned concentrated-liquidity NFT can drift out of
range into economically useless liquidity that nobody can ever rebalance.
Concentrated venues may exist in Flow, but they are never the destination of
the permanent-liquidity lane without an immutable, non-withdrawable
rebalancer. The protocol AMM is full-range CPMM, so the invariant holds.

**Token fees:** Capstone in/out are paid in EMBER and burned at 100%.
**Deed fees:** 1% of every Deed auction's final price, 50/50 burn/liquidity.

## 14. Flow — the swap page

The native swap lists **EMBER, ASH, every configured single (WETH, USDC,
WBTC…), and the LP tokens themselves** as first-class rows: buying the LP row
zaps and mints, selling it unwinds, and staked LP cannot be touched until it
exits through the timer. **Fees are asymmetric — leavers pay more than
arrivers:**

| Side | Total | LPs | Burn | Liquidity | Quote yield | Treasury |
|---|---|---|---|---|---|---|
| Buy EMBER | 25 bps | 20 | 2.5 | 2.5 | — | 0 |
| Sell EMBER | 35 bps | 20 | 5 | 5 | 5 | 0 |

The 5 bps quote-yield slice exists **only on sells**: sellers explicitly fund
stayer yield. The position card shows **impermanent loss next to Heat**.
Eternal Flame holders receive a **25% rebate** on the protocol's fee share
(50% at Bedrock), funded pro-rata from the burn/liquidity/quote-yield slices.

## 15. The Hearth

ASH staked in the Hearth earns the Vent's 10% fee share — real yield in fee
assets, not emissions — plus governance weight (2× at Eternal Flame, 3× at
Bedrock).

## 16. Treasury

Safe multisig (2-of; signers set at deploy), **48-hour timelock** on all
parameter changes, on-chain reporting. The Safe deploys through its own
deterministic factory (`0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67`), recorded
in config next to the salt nonce — so the treasury address is also decided
before anything is deployed. Policy: **30%** POL seeding, **30%**
match-reserve seeding (Ignition fees pre-fund day-one Stokes), **20%**
incentives, **20%** buybacks. The Ignition 3% is the treasury's only income
before fees exist. The Kindling close bounty (0.05%) comes from this fee.

## 17. Fissures — satellite launches

A satellite chain opens with a **Fissure**: a smaller Kindling seeded with
EMBER the Treasury bridges over the OFT (250,000 default, counted against the
cap), with the timelock approving the allocation. Same 3% fee, same 90/10 LP
split, same atomic close. **Inferno+ holders on any chain get the first 24
hours to themselves**, then it opens to everyone — first access, never a head
start: Heat, Streak and badges are chain-local and never bridge.

## 18. Referrals — disabled by default

A referee may attach a referrer's code; **3% of the referee's emission share
is redirected** to the referrer while the referee holds Spark and the
referrer holds Flame. Nothing is minted — **self-referral gains nothing
net**. Both sides are strata-gated: recruiters must themselves be stayers.
Off until the timelock decides the protocol wants recruiters.

## 19. Governance — two chambers

Launch runs on the timelock; two chambers take over later. The **Hearth
Chamber** is ASH holders (the productive governance token); the **Forge
Chamber** is liquidity × Heat (the stakers). Operational proposals use the
appropriate chamber — Hearth matters to Hearth, staking matters to Forge.
Changes to **Treasury policy, new chains, Flow fee bands, emission curves, or
new contracts require both chambers**. Neither Genesis ASH owners nor late
liquidity whales govern alone — and the two-token architecture finally has a
reason to exist beyond "ASH pays fees." Four things sit **above both
chambers, out of reach of every vote, forever**: minting outside the Mantle,
pausing withdrawals, touching user balances, redirecting the Vent.

## 20. Security

Contracts clamp fees at hard ceilings a rebrand can only lower, never raise:
**5%** deposits, **5%** withdrawals, **5%** genesis, **10%** emergency,
**100 bps** swaps, **5%** Deed sales. Deposits and swaps are pausable;
**withdrawals are never pausable.** Core contracts immutable; periphery
upgradeable behind the timelock. Per-chain guardian addresses. **No audit has
occurred — mainnet without a minimum of two independent audits is not on the
table.**

## 21. Omnichain

EMBER and ASH are LayerZero OFT v2: one canonical supply, native bridging, no
wrapped variants. Heat, Streak, Relics, and loyalty timers are **chain-local**
— bridging never carries Heat, which kills cross-chain multiplier gaming at
the root.

| Chain | Role | Emission share | LayerZero EID |
|---|---|---|---|
| Ethereum | home | 45% | 30101 |
| BNB Chain | satellite | 20% | 30102 |
| Base | satellite | 15% | 30184 |
| Arbitrum One | satellite | 10% | 30110 |
| Solana | satellite | 10% | 30168 |

The cross-chain gauge exists in config, disabled. Fixed emission shares run
until it is proven. Fissures (section 17) are how satellites open.

## 22. Solana

Full Anchor program suite (staking program, fee-router program) with Metaplex
soulbound Relics, sharing every fee, timer, and loyalty parameter from the
same config. Program IDs and mint addresses are **ground keypairs** — the
address *is* the public key, known before deploy, pinned with `declare_id!`.
Vanity grinding for program prefixes is a planned step (solana-keygen).

## 23. Deterministic deployment

Every EVM contract deploys via **CreateX CREATE3**
(`0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` — same on every chain). Salt =
`deployer (20 bytes) ++ 0x00 ++ mined entropy (11 bytes)`: the `0x00` flag
keeps **one identical address on every chain** while the deployer prefix
means only that account can ever deploy it — un-front-runnable. The address
depends only on factory + salt, never on bytecode or constructor args, so
`pnpm mine:salts` runs **before any contract exists**. The miner is
**idempotent**: re-running keeps every finalized entry and mines only what's
missing.

| Contract | Prefix | Address |
|---|---|---|
| EmberToken | F1E5 | `0xf1e5b7820a8c6f6349a576db516142c8d341dcc4` |
| AshToken | A5E5 | `0xa5e55c164036f63e9b6e6337c465eedead49fb5b` |
| FeeRouter | FEE5 | `0xfee5356949802d661959360a5e4004e1d8c685a2` |
| Forge | F095 | `0xf09551c13e2ca9cbeed634452a1f37d89a25532d` |
| Ignition | 1917 | `0x19172ad5c06ccc86a6e2712d06500f1028cf185b` |
| Kindling | 5A1D | `0x5a1d6ee608bf6e94b53789824705427ea40f2746` |
| Hearth | EA27 | `0xea272470c2529afe408d13bf6057b72a1a8763ce` |
| Relics | 2E1C | `0x2e1c923b32c214c4b7b2b8bd30daeb9f0a183dbd` |
| Deeds | DEED | `0xdeed54948eab9875d89a77cc383714d6a5d7dc6d` |

`contractAddress(name)` is the **only** way any module reads an address, and
it throws if a salt isn't mined. The deploy script recomputes every address
from its salt and **aborts on mismatch**. Nothing writes to the config at
deploy time, ever. `check:config` refuses any vanity prefix that isn't pure
hex — and **refuses to build if any contract entry lacks a mined salt or
address**: an unmined registry entry is a build error, not a runtime
surprise.

**`pnpm config:hash`** prints keccak256 of the canonical config JSON.
v5.4 changes the config, so every earlier published hash is stale:
`0x22c9dea60d12ac753e5eb02e64810514f4cbaec5e0ee65d998d19666d82a33b0`
(27,026 canonical characters; 27,076 UTF-8 bytes). Record it on-chain at deploy so every surface —
frontend, indexer, docs, deploy scripts — can prove it reads the same config
the contracts were initialized from.

Solana IDs (ground keypairs, `keys/` — gitignored, back them up):

| Program / Mint | Address |
|---|---|
| Staking program | `HVQT6MycoarDw9ktbZBv282HH8SttSR4ycvTeSTw9kKe` |
| FeeRouter program | `ECgH9KPnFW9GoM9fe6uVYrmaJpQMsacA8EiiSKwo3Egu` |
| EMBER mint | `AtbnZK5DQibjpxkhynqq7617iuseoWaABytXN7Q3RnbD` |
| ASH mint | `7a2HrKABUqNEsPntziBaDMVMboQ6hThWJVFu9Zp3cAnW` |
| Relics collection | `GgpFhkNfS4Y16gX746NNzWJup6yDcpCRHjw5NNVKFdCL` |

Current mined addresses are bound to the placeholder deployer
`0x1111111111111111111111111111111111111111`. Two values finalize them: the
real **DEPLOYER** EOA and the Treasury Safe **saltNonce**.

## 24. The config-first rule

Every brand string, fee, timer, pool, chain, page, piece of copy, and address
lives in `furnace.config.ts`. Frontend, contracts, indexer, and docs all read
it; `pnpm check:config` fails the build on structural violations; contracts
clamp anything the config tries to raise past a ceiling. A full rebrand —
names, tokens, theme, chains, pages — is a one-file edit via
`namePresets`: `names: namePresets.tephra` swaps the entire vocabulary.

The validator is **genuinely hostile by design**, and it is hostile in two
different ways.

**Exact, because the protocol's promises depend on them:** the 3% genesis
fee (Ignition, Kindling, Fissures), 1% deposit and 1% withdrawal fees; 0%
compound; ASH allocations summing to exactly 70,000 with Ignition and
Kindling matching their tree leaves; `supplyCeiling.hardCap = token.maxSupply`
with Ashfall inside the same headroom budget; every split summing to 100;
per-lot accounting on; casting into the earning lot; the conviction bucket
cap on; AutoStoke and referrals default-off; withdrawals never pausable;
nothing locked (Ignition withdrawal open); the Vent 40/40/10/10; and complete
deploy identity (contract registry, real deployer, Safe nonce and signers,
guardians, DVNs, Deeds salt).

**Exact, because the protocol's identity depends on them:** emission start
21,600/day, 365-day half-life, 1,000/day floor; 25% Casting; the 30/70 split;
the 10% conviction bucket; the cooldown ladder; the 24-hour execution window;
the 1800s TWAP floor and 1% slippage ceiling. These numbers *are* FURNACE —
a config that changes them is a new protocol, and the Rebrand Guide says so
explicitly. The validator does not bless forks as FURNACE.

v5.4 closed the coverage gaps a mutation review proved: the validator now
also enforces exact claim 0, emergency 8, cooling 'proportional',
compound-inherits-age, the 1000 floor, the 30/70 split, the 10% bucket, and
the casting/Kindling policy fields — plus EIP-55 checksum validation on
every router, endpoint, and guardian (length catches truncation; the
checksum catches a mistyped character in a valid-length address, the exact
failure mode of the corrupted router v5.3 shipped), and a guardian entry
required per enabled EVM chain. What the validator claims exact, it now
checks exact.

"Single source of truth" is a build property, not a slogan.

## 25. Deliberate rejections

- **Transfer taxes** — break OFT bridging, aggregators, CEX listings;
  honeypot optics. Fees sit on actions, never on transfers.
- **Fixed lock durations** — the timer starts on click, always. Conviction
  escrows sit on top; they never replace.
- **Locking Ignition principal** — a transparent lock is still a lock.
  "Nothing is ever locked" holds in the bootstrap too.
- **33% early-exit slash** — a trap with better vocabulary. 8% prices the
  fast exit and pays the stakers who stayed; escrows forfeit only the bonus.
- **Dropping Deeds** — the "from first principles" simplification reasserts
  the old rejection without engaging the mitigations: 80% haircut, Streak
  reset, soulbound badges, Heat conserved-minus-haircut, and now the 24h
  auction. Exits without sell pressure remain strictly better for stayers
  than exits with sell pressure.
- **Bond-LP tranches** — governance-redeemable liquidity is
  governance-extractable liquidity. Burned LP is un-ruggable.
- **Revenue-only emissions** — kept as the quote-yield slice, not the
  schedule. Starving loyal stakers in quiet months inverts the thesis.
- **Cross-chain loyalty sync** — chain-local accounting kills the gaming.
- **Killing ASH / the Hearth** — the two-token model is established and the
  Hearth gives ASH real fee yield.
- **Killing single-asset pools** — Cold Storage is a deliberate low-risk
  on-ramp that earns no ASH; its weight already says what we think of it.
- **Killing the Flow fee waiver** — documented, Ashfall-guarded, keeps
  liquidity formation inside the dapp.
- **Streak-based relic bumps** — harsher than proportional; contradicts "a
  10% exit is never priced like a 100% exit."
- **Step-function milestone bumps** — the 365-day cliff priced a 1% exit at
  −0.11×. Prorated bumps keep every exit smooth.
- **Rolling Cast lot** — timestamp averaging under sqrt Heat is the lossy
  merge the 32-lot rule bans. Casting into the earning lot kills it.
- **Uncapped conviction bucket** — one early sealer collecting the whole 10%
  breaks the 4.15× ceiling. The per-position cap binds it.
- **Ashfall outside the headroom check** — a second mint outside the ceiling
  math reintroduces the breach v5.2 closed.
- **Range-validated economics** — exactness is the config-as-protocol
  guarantee. A rebrand that changes emissions or the Vent split is a new
  protocol; the validator doesn't bless it as FURNACE.
- **Flat 0.30% swap fee** — the 25/35 asymmetry is built, validated, and
  "sellers fund stayers" is cleaner attribution.
- **No hard cap** — the 21M cap costs nothing and "not infinite" is
  load-bearing optics.
- **Invalid vanity** (`0xFIRE…`, `1AVA`, non-hex prefixes, non-base58
  Solana IDs) — the config refuses them at build time.

## 26. What's new in v5.4 (delta from v5.3.0)

Ten items from the verified review. Every v5.3 mechanic stands; these close
the contradictions the review proved against the live config.

1. **One cooling helper.** `heatAgeAfterWithdrawal` now delegates to
   `cooledAgeAfterWithdrawal`. The retired variant returned 365 days for a
   730-day lot at 50%; the single implementation returns 182.5.
2. **Deed age capped before carry.** 80% of a 730-day lot is 292 days, not
   584. Streak stays chronological — capping financial age never shortens it.
3. **Resume-frozen everywhere.** `cancelReturnsAsFreshLot: false`, aligning
   with `onCancelOrLapse: 'resumeFrozen'`. The stale "fresh lot" lapse toast
   and "casting dilutes age" copy now describe the source-lot policy.
4. **Conviction cap, additive-correct.** `cap_i = L × s_i × b_i / W` — the
   seal's marginal worth `(b/h)×P`, not `b×P` (which overstates the cap by a
   factor of the position's own Heat *h* — 3.65× in the worked example, 1× at
   h=1, 4.15× at the ceiling). New `convictionCap()` helper. Effective split
   clarified: 27/73 with an empty bucket. New `epochSplit()` helper.
5. **Single-token casting.** Ember Vault and Cold Storage lots get liquid,
   not LP — no silent exposure change.
6. **LP ownership settled.** Cast/stoke matched LP is user-owned; only the
   idle auto-pair (7 epochs → reserve quote + treasury-seeded EMBER) burns.
7. **Kindling fee escrow.** The 3% sits escrowed at the treasury until close;
   failed raises refund it with principal.
8. **`totalMintForEpoch` rejects negative/non-finite inputs.**
9. **Validator hardened.** Exact: claim 0, emergency 8, cooling
   'proportional', compound-inherits-age, floor 1000, split 30/70, bucket 10.
   Plus 20-byte checks on routers/endpoints/guardians and a guardian entry
   required per enabled EVM chain (which caught 3 previously invisible
   missing entries).
10. **Router corrected.** Ethereum's externalDex router had 38 hex digits;
    replaced with the verified UniswapV2Router02
    `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`.

## 26b. What was new in v5.3 (delta from v5.2.0)

Seven fixes and two completions. Every v5.2 mechanic stands; these make its
numbers agree with each other and with the config.

1. **Prorated milestone bumps.** The five +0.1× bumps now fill in linearly
   between milestones instead of stepping. The 365-day cliff (a 1% exit
   costing −0.11×) is gone: 3.00× → 2.99× on a 1% exit, → 2.90× on 10%.
2. **Proportional cooling, defined per lot.** Withdrawing *f* removes *f* of
   every lot's LP and scales every lot's age by (1 − *f*), capped at 365 days
   first. New `cooledAgeAfterWithdrawal()` helper; the worked examples are
   tested.
3. **Casting follows provenance.** Cast LP goes back into the lot that
   earned it, at that lot's age. The rolling Cast lot — and its lossy
   timestamp averaging — is gone.
4. **Conviction bucket capped per position (v5.4: formula corrected).** A
   sealed position's bucket payout ≤ the additive value of its seal bonus
   (`L × s_i × b_i / W`); the excess and any unsealed epoch flow back into
   the Heat pool. The 4.15× ceiling now binds.
5. **Ignition principal unlocked.** Withdrawable during Ignition (fee not
   refunded) — "nothing is ever locked" holds in the bootstrap. At close:
   USDC auto-stakes into Cold Storage (opt-out), other assets claimable
   fee-free, Heat head start rides on the first Deed opened within 7 days.
6. **One genesis fee.** The 3% now applies to Ignition, Kindling *and*
   Fissures — Kindling was missing it. Straight to treasury, no splits.
7. **Ashfall inside the headroom check.** `totalMintForEpoch()` sizes base
   emission + Ashfall against `21M − totalSupply` as one budget, pro-rata.
8. **Kindling depositor disclosure (v5.4: three quantities).** The gauge shows
   the quote-side claim (~$87.30), the token-side claim (~$87.30 at the
   opening ratio), and the combined LP mark (~$174.60) — not a promised exit.
9. **`namePresets`.** `names: namePresets.tephra` swaps the entire vocabulary
   in one line — the Rebrand Guide's "one file, thirty minutes" is now real.

## 27. Before mainnet

1. Set the **DEPLOYER** EOA and Treasury Safe **saltNonce** → `pnpm
   mine:salts` finalizes all 9 addresses in seconds.
2. Set Treasury Safe **signers** (3-of-5 recommended) and per-chain
   **guardians**; configure ≥2 verified LayerZero **DVNs** per chain.
3. Professional audit — fee router + OFT integration + Deed Market + fee
   vault are the highest-risk surfaces. Minimum two independent audits.
4. Solana program audit, separately.
5. **Legal review of ASH and the Hearth.** A token that pays holders a share
   of protocol fees can be treated as a security in several jurisdictions.
   Get an opinion before ASH is sold, listed or farmed by the public.
6. Recompute and record the v5.4 config hash on-chain.
7. Testnet run: 24-hour mock Ignition and Kindling; every partial
   withdrawal, cancellation, Stoke, multi-lot edge case, conviction expiry.
8. Invariant tests: fee sums, Ashfall roll-forward, matured-request
   unblockability, cap enforcement, prorated-bump continuity.
9. **Global supply ledger.** `totalMintForEpoch` needs an authenticated,
   conservative `totalSupply`: OFT transport debits one chain and credits
   another without creating issuance headroom; in-flight claims and reserved
   liabilities must be accounted. No config flag replaces this ledger.
10. **Conviction allocator.** The config defines the bucket, the cap formula
    (`convictionCap`), and the return rule (`epochSplit`) — the per-epoch
    payout loop over sealed positions is contract work, bounded, without
    unbounded iteration over depositors.
11. Grind Solana vanity program prefixes (optional, cosmetic).

---
*FURNACE v5.4.0 · describes `furnace.config.ts` v5.4.0 · 2026-10-04 ·
hash `0x22c9dea60d12ac753e5eb02e64810514f4cbaec5e0ee65d998d19666d82a33b0`*
