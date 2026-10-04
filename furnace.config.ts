// ══════════════════════════════════════════════════════════════════════════════
// FURNACE PROTOCOL — Master Configuration File · v5.3.1
// ══════════════════════════════════════════════════════════════════════════════
// The single source of truth for the whole protocol. Read by:
//   contracts/   Foundry deploy scripts (EVM) and Anchor deploy scripts (Solana)
//   indexer/     Ponder / subgraph / Helius webhooks
//   apps/web/    Frontend — brand, names, pages, copy, theme
//
// Rules:
//   1. Every human-facing string, number, address, icon and route lives here.
//      `pnpm check:config` fails the build if brand specifics leak elsewhere.
//   2. Contracts clamp fees at the hard ceilings in `security.feeCeilings`.
//      A config can lower a fee, never raise it past the ceiling.
//   3. Percent fields are plain percent (1 = 1%). Basis points are suffixed
//      `Bps` (100 = 1%).
//   4. Token amounts are decimal strings in human units ("10000000").
//   5. Durations are seconds unless the field name says Days or Hours.
//   6. Reference brand is FURNACE / EMBER / ASH. Change `brand`, `names`,
//      `token` and `pages` and the whole product is yours.
//   7. ADDRESSES ARE DECIDED BEFORE ANYTHING IS DEPLOYED. `evmContracts`
//      holds one mined CREATE3 salt + address per contract, identical on every
//      EVM chain; `solanaIds` holds one ground keypair + address per program /
//      mint. `pnpm mine:salts` fills them once; everything else reads them;
//      `pnpm deploy <chain>` refuses to run if a recomputed address differs.
//      Nothing is ever pasted in after a deploy.
//
// v2 changelog (from v1.0.0):
//   - Heat/Streak decoupling: Heat = stake-weighted age (yield), Streak =
//     chronological days (Relic perks). Deposits dilute by weighted average —
//     dust-aging is dead. Withdrawals cool Heat proportionally.
//   - Capstone: an EMBER-only lot inside a position, up to +0.5× Heat, earns
//     no emissions, never sells. Stokes land here first, then as matched LP.
//   - Match reserve: the Vent unwinds fee LP, burns the EMBER half, holds the
//     quote half to pair with Stokes. Stokes never sell; zap is the fallback.
//   - Ashfall: 50% of each epoch's burns re-emitted to 30d+ stakers, weighted
//     by stake × Heat² (whale skew), with rollover if nobody is eligible.
//   - Tap: Blaze/Eternal tiers may withdraw 10%/25% per 90d without resetting
//     the Streak; youngest lots are drawn first (raises blended Heat).
//   - Atomic Kindling close: the final deposit past the deadline creates the
//     pool, pairs assets and burns the LP in the same transaction (MEV-safe).
//   - Founder phantom age: First Flame badge holders keep a +15d Heat floor,
//     even after a full reset. A founder's wallet stays superior forever.
//   - AutoStoke: anyone may compound for anyone else for a 1% caller bounty.
//   - Emergency exit: 8% fee (50% burn / 25% liquidity / 25% to stakers).
//   - 30/70 emission split: 30% flat by stake (newcomer floor), 70% by
//     stake × Heat.
//   - Flow fee waiver: LP bought on the native swap stakes with no deposit
//     fee — but zero-fee zaps earn no Ashfall that epoch (sybil guard).
//   - Cooldowns: 72h withdraw (+24h execution window) / 24h claim / 0 compound.
//   - Heat shape defaults to sqrt (diminishing returns to time).
//
// v2.1 changelog (from v2.0.0) — the Lodge Capital review:
//   Adopted, verified against the actual whitepaper and hardened:
//   - Casting (LP-denominated emissions): each epoch, `casting.lpSharePct` of a
//     user's EMBER emission is paired with quote asset from the match reserve
//     and minted as LP that auto-stakes into their position as a fresh lot.
//     Lodge lets earners "break them for profit" instantly; FURNACE doesn't —
//     the reward IS liquidity, and dumping it costs swap fees + 1% + 72h.
//     Hard invariant: if the reserve can't cover the quote side, the user gets
//     liquid EMBER. The protocol NEVER market-sells a user's emission.
//   - Pyre (burn-to-mint badges): burn EMBER to the dead address → soulbound
//     Pyre badge, +0.05× Heat per tier, account-wide, permanent, capped at
//     +0.15× (below half the time ramp — burning must never outweigh staying).
//     The whitepaper only dreamed this ("in the future... things like burning
//     5 DUES"); here it ships. Pyre burns count as manualBurns for Ashfall.
//   - Deserter's tithe: emergency exit now forfeits the position's pending
//     Ashfall into the rollover pool for the loyal. Lodge verified the
//     principle (13% of early-exit DUES to remaining Beehive stakers); FURNACE
//     has no fixed locks, so the tithe is Ashfall forfeiture, not a slash.
//   Rejected with reasons:
//   - 3%/3% buy/sell transfer taxes: break OFT bridging, aggregators and CEX
//     listings; honeypot optics. FURNACE taxes actions (stake/unstake/swap),
//     never transfers. The paper's own LODGE tax line contradicts itself.
//   - Fixed lock durations (3d–3y): funds would be locked, violating the
//     standing rule that timers start on click. Continuous stake + proportional
//     cooling + Heat/Streak already buys retention without traps.
//   - BUSD-denominated yield: BUSD minting ended Feb 2024 (Paxos). Promising
//     yield in a deprecated third-party stable is a liability.
//   - 3,333 supply / DUES-FAAM-LODGE baroque: their brand scarcity, not a
//     transferable mechanic. EMBER 21M halving + 70k ASH stands.
//   Corrections to the sketch that cited the paper: the Wildman was never
//     soulbound and never boosted APR (aspirational text); "Vouchsafe" is a
//     glossary word, not a reemission mechanic; earned Masonry LP is breakable,
//     not locked; "Backbiting" in the paper means slander, not slashing.
//
// v3 changelog (from v2.1.0) — the PYRE + Emberforge review:
//   Adopted:
//   - Progressive withdrawal cooldown: the 72h timer is now the TOP tier, not
//     the only tier. Withdrawing ≤10% cools 6h, ≤25% 12h, ≤50% 24h, ≤75% 48h,
//     100% 72h. Small exits stop feeling punished; whale exits still face the
//     full weekend. Each arm is per-lot with the 1% fee on execution, so
//     splitting an exit into slices costs the same fee and stays observable.
//   - Quote yield: 5 of the 30 Flow swap bps are now paid in the chain's QUOTE
//     asset (not EMBER) to ashfall-eligible stakers, weighted by stake × Heat².
//     Real yield beside emissions. LP share drops 20→15 to fund it; stakers'
//     total is unchanged, but a quarter of it is now hard asset.
//   - Burn-lane execution guards: the Vent's unwindAndBuyback now runs through
//     a TWAP with max price impact, allowlisted routers only, and defer-if-
//     unsafe. The burn itself can no longer be sandwiched.
//   - Conviction tracks: opt-in bonus tracks layered ON TOP of the click-timer,
//     never replacing it. 30d → +0.15×, 90d → +0.25×, 365d → +0.40×, accruing
//     daily into a vesting balance that pays out only at term end. Leaving
//     early forfeits the unvested bonus — principal is never locked, never
//     slashed, and still exits through the normal timer. (The Tephra v3 sketch
//     left the break mechanic unspecified, which would have made the max track
//     free money for everyone; vesting-at-end is the repair.)
//   - Eternal fee rebate: Eternal Flame (365d) holders get 25% of the
//     protocol's Flow swap-fee share rebated, funded pro-rata from the
//     burn/liquidity/quote-yield slices.
//   - The position card shows impermanent loss next to Heat. Pretending IL is
//     not the staker's problem is how docs get people wrecked.
//   Rejected with reasons:
//   - `0xFIRE596…` / `0xF1RE596…` addresses (both pasted docs): I, R, P, Y are
//     not hex digits. "Format is cosmetic" is wrong — these can never exist.
//     Solana `PYREFire…` contains uppercase I: invalid base58.
//   - Commitment lanes as a REPLACEMENT for the click-timer: the spec says the
//     timer starts when they click. Tracks sit on top; they don't replace.
//   - Bond-LP tranche (governable rolling-term POL): governance-redeemable
//     liquidity is governance-extractable liquidity. Burned LP is un-ruggable.
//   - Revenue-only emissions: kept as the quote-yield slice, not the schedule.
//     Quiet months still pay the emission floor — starving loyal stakers when
//     volume is zero is the opposite of the thesis.
//
// v4 changelog (from v3.0.0) — the Tephra v4 synthesis review:
//   Adopted:
//   - Deeds: every position is now an NFT, tradable on the in-dapp Deed
//     Market for ETH or EMBER at a 1% Vent fee (50/50 burn/liquidity). The
//     buyer receives the LP, Capstone, any conviction escrow + remaining term,
//     unclaimed rewards, and 80% of the Heat age; the Streak resets to 0 and
//     badges stay with the seller. The LP never leaves the pool, transfers
//     outside the market are refused by the token, and a Deed with a pending
//     Withdraw/Claim cannot be listed. This OVERRULES the v2 rejection of
//     tradable positions: a sold Deed keeps liquidity in the pool and pays a
//     patient seller, while the 20% haircut keeps earned time worth more than
//     bought time. Heat is conserved-minus-haircut on trade — it can move,
//     never inflate. New `Deeds` contract, mined to 0xDEED….
//   - Asymmetric swap fees: leavers pay more than arrivers. Buys cost 25bps
//     (20 LP / 2.5 burn / 2.5 liquidity); sells cost 35bps (20 LP / 5 burn /
//     5 liquidity / 5 quote yield). The real-yield slice is now explicitly
//     funded by sellers, not carved from a flat fee.
//   - Seal escrow mechanics: conviction tracks are now true escrows. The bonus
//     is minted per epoch INTO ESCROW as part of the epoch budget (ordinary
//     share stays claimable); at term end the escrow pays into the Capstone,
//     never sold. Early exit forfeits the escrow — 50% burn lane, 25% match
//     reserve, 25% Sealed pot streamed to positions still inside their term.
//     Principal is never touched. Four tracks now: 30d +0.15, 90d +0.25,
//     180d +0.35, 365d +0.50. Completing a term mints a soulbound Keystone.
//   - Bedrock relic (730d): no Heat bump (the ramp caps at a year) — the
//     second year pays in perks: Tap 25% every 60d, 3× governance weight,
//     50% swap-fee rebate.
//   - Kindling close bounty: 0.05% of the raise to whoever calls the
//     permissionless atomic close. Bots race to close it the second it is due.
//   - Referrals (disabled by default): 3% of a referee's emission share is
//     redirected to the referrer — zero-sum, never minted — while the referee
//     holds Spark and the referrer holds Flame. Self-referral gains nothing.
//   - Fissures: satellite-chain launches as smaller Kindlings (250k EMBER
//     default, bridged from Treasury), with a 24h priority window for
//     Inferno+ holders. Loyalists get first access on new chains, never a
//     head start.
//   - Governance section: explicit scope. One position, one vote, stake ×
//     Heat; minting outside the Mantle, pausing withdrawals, touching user
//     balances and redirecting the Vent are out of reach of every vote forever.
//   - Global multiplier cap: 4.15× = 3.0 Heat + 0.5 Capstone + 0.15 Pyre +
//     0.5 track, validated in check:config against the computed sum.
//   - Vanity charset validation: EVM prefixes must be pure hex, Solana pure
//     base58 — a grinder searching for an impossible prefix now fails the
//     build instead of running forever.
//   Rejected with reasons:
//   - Killing ASH / the Hearth: the two-token model is established and the
//     Hearth gives ASH real fee yield. One-token purity is their line's call,
//     not a reason to churn ours.
//   - Killing single-asset pools (Cold Storage): a deliberate low-risk
//     on-ramp that earns no ASH. Paying idle capital a little is the price of
//     the widest funnel; the weight already says what we think of it.
//   - Killing the Flow deposit-fee waiver: documented, Ashfall-guarded, and
//     it keeps liquidity formation inside the dapp. A disclosed incentive is
//     not a hidden fee schedule.
//   - Deed-backed borrowing, emergency-exit insurance pot: strong v5
//     candidates, noted — not v4 scope.
//
// v5 changelog (from v4.0.0) — the Tephra v5 review:
//   Adopted:
//   - Opt-in AutoStoke (replaces open keeper stoking): the v4 design let
//     ANYONE compound ANY position for a 1% bounty — on a cheap-gas chain that
//     pays bots to skim 1% of every position's yield continuously, front-
//     running owners' own free stokes. Now keepers must be explicitly enabled
//     PER POSITION, with owner-set limits: tip 0.1–1% (default 0.5%),
//     minimum interval ≥24h (default 7d), minimum size (default 100 EMBER).
//     `defaultOn: true` fails the build. By default only the owner stokes.
//   - Fee vault + permissionless vent(): fees no longer hit the pool as they
//     arrive. Every fee lands in the chain's fee vault (part of the Vent) and
//     a permissionless `vent()` call processes it past a size threshold — at
//     least once per epoch either way. Gas off user transactions, batched
//     execution, no keeper centralization.
//   - Four-way buy protection on the burn lane: spot must sit within 2% of
//     the 30-min average, slippage capped at 1%, no single buy above 0.5% of
//     the pool's quote reserve, fail-closed (unsafe → the ETH waits in the
//     vault). The build refuses a slippage cap above 1% or a TWAP under 30m.
//   - Deed Market is now a 24-hour ascending auction (reserve price, highest
//     bid wins, 1% Vent fee on the final price) instead of an instant sale.
//     This answers the "instant exit" objection to Deeds: the only INSTANT
//     exit is the 8% emergency route; the Deed auction is the fast exit (24h,
//     1%); the timer is the slow exit (72h, 1%). Three priced tiers, and no
//     bot can snipe a mispriced fixed listing.
//   - Missing vanity salt fails the build: every EVM contract entry must have
//     a mined salt AND address. `contractAddress()` throwing at runtime was
//     not enough — an unmined registry entry is now a build error.
//   - Treasury Safe factory pinned: the Safe deploys through its own factory
//     (0x4e1DCf…820ec67), recorded in config next to the salt nonce.
//   - `pnpm config:hash`: prints keccak256 of the canonical config JSON.
//     Record it on-chain at deploy. v5.3.0 was 0x1554…94ed5 (26,829 chars / 26,875 UTF-8 bytes;
//     the spec said 'bytes' but meant chars). v5.3.1 hash is in the changelog above.
//     Canonical method: recursive key sort, array order preserved, compact JSON.stringify, Keccak-256.
//   Rejected with reasons:
//   - Dropping Deeds (v5 "from first principles" simplification): the v5 doc
//     reasserts the old rejection without engaging the mitigations — 80%
//     haircut, Streak reset, soulbound badges, Heat conserved-minus-haircut.
//     Exits without sell pressure remain strictly better for stayers than
//     exits with sell pressure. Kept, plus the 24h auction guardrail.
//   - Streak-based relic bumps (any withdrawal → all bumps dormant): harsher
//     than proportional and contradicts "a 10% exit is never priced like a
//     100% exit." FURNACE keeps age-based bumps — a 10% withdrawal keeps 90%
//     of the age and most bumps, loses the perks via the Streak reset.
//   - Flat 0.30% swap fee (v5 reverts the asymmetry): the 25/35 split is
//     already built and validated, and "sellers fund stayers" is cleaner
//     attribution than a flat fee. Direction is unambiguous on the
//     protocol's own pool. Kept.
//   - No hard cap (v5): the 21M cap costs nothing — the halving curve
//     converges near ~11.4M anyway — and "not infinite" is load-bearing
//     optics for a farm. Kept.
//   - 50k/day 60-day half-life emissions (v5): the slower 21.6k/day 365-day
//     curve suits a loyalty protocol. No reason to churn. Kept.
//   - Simple 2-track locks (v5): the Seal escrow (bonus for COMPLETING the
//     term, forfeit routing, Keystone) is a strictly stronger commitment
//     device than a plain multiplier. Kept.
//   - Dropping Pyre (v5 simplification): the burn-to-mint sink is proven,
//     capped, and already built. Kept.
//   - 72h execution window (v5): 24h is plenty to avoid "be online at
//     exactly T+72h"; longer windows just strand capital longer. Kept.
//   - Kiln 35/25/25/15 split (Emberforge): FURNACE's 40/40/10/10 already
//     serves the Hearth and treasury; Ashfall (not a reward reserve) is the
//     more elegant revenue-share. Kept.
//   - Burn-and-Bond LP tranches (Emberforge): re-rejected —
//     governance-redeemable liquidity is governance-extractable liquidity.
//   - Commitment lanes with lock minimums (Emberforge): re-rejected — locks
//     replace the click-timer; conviction escrows sit on top.
//   - Ember Credits for Genesis: Ignition's per-second pro-rata is already
//     time-weighted and asset-weighted (LP 150 vs 100). Kept simple.
//
// v5.2 changelog (from v5.1.0) — ten accounting contradictions resolved.
// The v5.1 mechanics stand; v5.2 makes the books balance:
//   1. Supply ceiling is LIVE, not cumulative: mint = min(targetEmission,
//      21M − totalSupply). Burns reopen mint headroom. The 1,000/day floor is
//      a TARGET that can continue forever only while burns create room —
//      late-stage emissions become structurally dependent on the deflation
//      engine. (The old wording — hard cap + indefinite floor + "never
//      chokes" — was mathematically impossible: decay hits the floor ~day
//      1,618 with ~10.85M emitted; the floor would mint past 21M ~29.7y out.)
//   2. ASH overallocation fixed: 42k Ignition + 28k Forge + 1k Kindling was
//      71k against a 70k cap. Now Launch = 41k Ignition + 1k Kindling, Forge
//      = 28k, total exactly 70k. The validator sums every ASH suballocation
//      recursively and requires exactly 70_000. Nothing else can mint ASH.
//   3. Kindling accounting hole closed: depositors' USDC no longer buys them
//      nothing. 90% of Kindling LP becomes auto-staked Deeds owned by
//      depositors; 10% is burned forever as the irrevocable liquidity floor.
//      Not Bond LP, not governance-extractable — the Tephra Eruption mechanic.
//   4. Provenance-preserving compounding: rewards generated by lot A inherit
//      lot A's age; Stoke's LP portion compounds back INTO its source lots.
//      A 365-day lot can no longer launder a 2-day lot's rewards into 365-day
//      Heat — and compounding still never dilutes legitimately earned age.
//   5. 32-lot exhaustion rule: Stoke modifies its source lots (no slot
//      consumed); Casting stakes back into the lot that earned it (no slot
//      consumed, no rolling lot, no merge). A genuine new deposit past 32
//      lots → the UI offers "Open New Deed". Lots are NEVER lossy-merged
//      (averaging timestamps under sqrt Heat changes entitlement).
//   6. Lapsed withdrawal no longer incinerates Heat: cooling FREEZES Heat and
//      rewards; cancel/lapse resumes the frozen Heat (the cooling interval
//      itself did not age). Only actual execution triggers proportional
//      cooling and Streak reset. Opportunity cost without the gotcha.
//   7. Keystone dual ownership: the WALLET earns a soulbound Keystone Relic
//      (proof the PERSON completed the term — never transfers); the DEED
//      gets a Seal Scar in permanent metadata (proof the CAPITAL completed
//      one — always travels). Richer collectibles, useful provenance.
//   8. Two-chamber governance: the Hearth Chamber (ASH holders) and the Forge
//      Chamber (liquidity × Heat). Operational proposals use the appropriate
//      chamber; Treasury policy, new chains, Flow fee bands, emission curves
//      and new contracts require BOTH. The immutable prohibitions sit above
//      both chambers. Neither Genesis ASH nor late liquidity whales govern alone.
//   9. Seal bonuses cannot enlarge the epoch mint: totalBaseMint(epoch) is
//      fixed BEFORE position weights are evaluated. 10% of each epoch is the
//      Conviction bucket; sealed positions compete for it by stake × Heat ×
//      sealWeight. Complete the term → Capstone; break it → 50/25/25.
//      Conviction affects distribution, never issuance.
//  10. Burned LP must be full-range: a burned concentrated-liquidity NFT can
//      drift out of range into economically useless liquidity nobody can
//      rebalance. Permanent-burn liquidity is full-range/non-repositionable.
//  11. Deed auction anti-sniping: a valid bid in the final 5 minutes extends
//      the auction 5 minutes, capped at 30 minutes total extension.
//  12. Ashfall source-specific recycle rates: 50% for protocol-created burns,
//      25% for registered Pyre burns, 0% for unsolicited dead-address
//      transfers. A dominant Heat² holder can no longer partially rebate
//      their own voluntary burn. The token disappears in every case; only the
//      protocol's definition of "activity that funds stayers" changes.
//
// v5.3.1 changelog (from v5.3.0) — the verified-review response. No monetary
// parameter changed; every FURNACE number is identical. Config hash:
//   0x9ecedb63d5d10951caaf506032a1cf6d14b9e2196f236e2d2a45c200870463f7 (27108 chars / 27158 UTF-8 bytes)
//   Fixed (review §4.1–4.2): heatAgeAfterWithdrawal delegates to the cap-first
//     helper; deedHeatAge caps at rampDays before the 80% carry (730d → 292,
//     was 584); cancelReturnsAsFreshLot false + lapse toast + casting copy now
//     match resumeFrozen and source-lot casting.
//   Fixed (review §4.3–4.4): single-token pools receive the cast share as
//     liquid EMBER (LP cannot join an EMBER or USDC balance); cast-LP vs
//     match-reserve LP ownership stated explicitly.
//   Fixed (review §6): Conviction cap is ADDITIVE (cap = L·s·b/W, never
//     b × earnings). New epochAllocation() reference oracle; the empty-bucket
//     effective split is 27/73 and is now documented as such.
//   Fixed (review §7): validator catches all 28 reviewer mutations. New:
//     non-finite number sweep, malformed-address sweep, EIP-55 checksums,
//     32-byte Solana pubkeys, CREATE3 re-derivation from salt (reproduces all
//     9 registry addresses), per-enabled-chain guardians and treasuries.
//   Fixed (review §7): Ethereum router was 19 bytes. Now Uniswap's published
//     Router02 (0x7a250d…488D), checksum-verified.
//   Fixed (review §8): mint helpers reject negative / non-finite inputs.
//   NEW finding: treasury.addresses were decorative placeholders (EVM failed
//     EIP-55; Solana was hand-typed base58 nobody holds the key to). Genesis
//     fees would have been unrecoverable. Now explicitly unset + validated.
//   Corrected: hash length is 26,829 chars / 26,875 UTF-8 bytes (v5.3.0).
//   Open (policy decisions, not silently chosen): see REVIEW-RESPONSE.md.
// ══════════════════════════════════════════════════════════════════════════════
// v5.3 changelog (from v5.2.0) — seven fixes, two completions. Every v5.2
// mechanic stands; v5.3 makes the numbers agree with each other:
//   1. Prorated milestone bumps: the five +0.1× bumps fill in linearly
//      between milestones instead of stepping. Kills the 365-day cliff (a 1%
//      exit cost −0.11× under step bumps). New milestoneBump() helper.
//   2. Proportional cooling, defined per lot: withdrawing f removes f of
//      every lot's LP AND scales every lot's age by (1−f), capped at 365
//      days first. New cooledAgeAfterWithdrawal() helper; examples tested.
//   3. Casting follows provenance: cast LP stakes back into the lot that
//      earned it, at that lot's age. The rolling Cast lot — and its lossy
//      timestamp averaging — is gone.
//   4. Conviction bucket capped per position: payout ≤ sealBonus × the
//      position's Heat-pool earnings; excess and unsealed epochs flow back
//      into the Heat pool. The 4.15× ceiling now binds.
//   5. Ignition unlocked: principal withdrawable during Ignition (fee not
//      refunded) — "nothing is ever locked" holds in the bootstrap. At close:
//      USDC auto-stakes into Cold Storage (opt-out), other assets claimable
//      fee-free, Heat head start rides on the first Deed opened within 7 days.
//   6. One genesis fee: the 3% now applies to Ignition, Kindling AND
//      Fissures — Kindling was missing it. Straight to treasury, no splits.
//   7. Ashfall inside the headroom check: totalMintForEpoch() sizes base
//      emission + Ashfall against 21M − totalSupply as one pro-rata budget.
//   8. namePresets: names: namePresets.tephra swaps the entire vocabulary in
//      one line — the Rebrand Guide's "one file, thirty minutes" is real.
//   9. Kindling depositor disclosure: ~$87.30 per $100 deposited,
//      shown live on the pressure gauge. This is the QUOTE-SIDE claim only
//      (your USDC remaining in the LP). The two-sided LP mark at open is ~$174.60
//      before fees, minimum-liquidity dilution and price changes. (review §5)
//   Rejected: range-validated economics. v5.2's exactness IS the
//   config-as-protocol guarantee; the Rebrand Guide classifies emission and
//   Vent-split changes as a new protocol, and the validator doesn't bless
//   forks as FURNACE.
// ══════════════════════════════════════════════════════════════════════════════
// v5.1 changelog (from v5.0.0) — the Tephra v6 review:
//   Adopted:
//   - Ignition early-bird: reward weight decays from +10% at the first second
//     to +0% at close (linear), on top of per-second pro-rata. Urgency for the
//     bootstrap without a first-block landgrab. New `ignitionWeight()` helper.
//   - Exact fee validation: the brief demands EXACTLY 3% / 1% / 1% — the
//     build now rejects anything else, not just over-ceiling values.
//   - Salt structure hardening in validateConfig: every salt must be bytes32,
//     guarded to the deployer (first 20 bytes), byte 21 = 0x00, and the
//     address must start with its prefix. Defense in depth next to the
//     miner's recomputation check.
//   - Per-lot deposit dilution (was weightedAverage): each lot keeps its own
//     age, matching the 32-lot infrastructure and youngest-first Taps. New
//     money never inherits old Heat either way; per-lot is simply more
//     precise.
//   Rejected with reasons (v6's config contains regressions — read carefully):
//   - `withdrawCooling: 'reset'` — v6 sets ANY withdrawal to zero ALL Heat.
//     That is the exact trap FURNACE v2 eliminated: a 10% exit priced like a
//     100% exit means once you're withdrawing anything you withdraw everything.
//     Proportional cooling stays.
//   - `compoundInheritsAge: false` — v6 makes every compound DILUTE your Heat
//     with a 1.0× lot. On a protocol whose thesis is "compounding is the only
//     way to grow a hot position," punishing the desired behavior is backwards.
//     The rewards were earned by the aged position; the fresh lot inherits its age.
//   - Commitment lanes with locked exits (Tempered/Forged/Eternal,
//     earlyExitAllowed: false) — a transparent lock is still a lock. The Seal
//     escrow already pays for commitment (+0.15 to +0.50) WITHOUT locking
//     principal. Re-rejected.
//   - Kiln reward reserve + no Hearth share (45/35/0/20) — Ashfall IS the
//     revenue-share and it's more elegant than a reserve; removing the
//     Hearth's 10% kills ASH's fee yield. 40/40/10/10 stays.
//   - Bond LP tranches (30% bonded 365d, governance-unlock) — re-rejected a
//     third time: governance-redeemable liquidity is governance-extractable
//     liquidity. Burned LP is un-ruggable.
//   - Slower cooldown tiers (12/24/48/72/96h) — FURNACE's 6/12/24/48/72h
//     already IS progressive; v6's numbers are just more punitive. Kept.
//   - Flat 30bps swap, no hard cap, 50k/day 60-day emissions, 2-track locks,
//     open AutoStoke, linear heat — v6 reverts v2–v5 wins on all of these.
//     FURNACE keeps its own values. (Note: v6's own config fails v6's own
//     validation — kiln/gauge salts are null.)
// ══════════════════════════════════════════════════════════════════════════════

// ─── Types ──────────────────────────────────────────────────────────────────
import { keccak_256 } from '@noble/hashes/sha3';

export type Pct = number;
export type Bps = number;
export type Seconds = number;
export type Days = number;
export type Hours = number;
export type Amount = string; // human units, decimal string
export type EvmAddress = `0x${string}`;
export type SolanaAddress = string; // base58
export type Address = EvmAddress | SolanaAddress;
export type ChainKey = string;
export type RelicKey = string;

export interface TokenRef {
  symbol: string;
  address: Address;
  decimals: number;
  icon?: string;
  coingeckoId?: string;
  /** How Kindling converts this asset into the quote asset at close. */
  conversion?: 'none' | 'swapAtClose';
  maxSlippageBps?: Bps;
}

export interface BrandConfig {
  protocolName: string;
  shortName: string;
  tagline: string;
  description: string;
  domain: string;
  supportEmail?: string;
  assets: {
    logo: string;
    logoMark: string;
    favicon: string;
    ogImage: string;
    tokenIcon: string;
    lpIcon: string;
    relicArtDir: string;
  };
  theme: {
    mode: 'dark' | 'light' | 'system';
    colors: Record<string, string>;
    fonts: { display: string; body: string; mono: string };
    radius: string;
  };
  social: Partial<Record<'x' | 'discord' | 'telegram' | 'github' | 'docs' | 'blog', string>>;
  legal: Partial<Record<'termsUrl' | 'privacyUrl' | 'riskDisclosureUrl', string>>;
}

export interface NamesConfig {
  genesis: string;
  staking: string;
  swap: string;
  treasury: string;
  burn: string;
  badges: string;
  reemission: string;
  emissions: string;
  multiplier: string;
  streak: string;
  lot: string;
  capstone: string;
  matchReserve: string;
  casting: string;
  pyre: string;
  tracks: string;
  deed: string;
  cooldowns: { withdraw: string; claim: string; compound: string; emergency: string };
  relics: Record<RelicKey, string>;
  founderBadge: string;
}

export interface PageConfig {
  key: string;
  path: string;
  title: string;
  navLabel: string;
  order: number;
  enabled: boolean;
  gate: 'always' | 'duringGenesis' | 'afterGenesis';
}

export interface CopyConfig {
  buttons: Record<string, string>;
  warnings: Record<string, string>;
  toasts: Record<string, string>;
  timeline: Record<string, string>;
  empty: Record<string, string>;
}

export interface ChainConfig {
  key: ChainKey;
  name: string;
  vm: 'evm' | 'svm';
  enabled: boolean;
  role: 'home' | 'satellite';
  chainId?: number;
  cluster?: 'mainnet-beta' | 'devnet';
  nativeSymbol: string;
  rpcUrls: readonly string[];
  explorerUrl: string;
  lz: {
    eid: number; // verify against docs.layerzero.network before deploy
    endpoint: Address;
    dvns: readonly Address[];
    requiredDvnCount: number;
  };
  quoteAsset: TokenRef;
  listedTokens: readonly TokenRef[];
  externalDex: {
    kind: 'uniswap-v2' | 'uniswap-v3' | 'aerodrome' | 'pancake-v2' | 'raydium' | 'jupiter' | 'none';
    router: Address;
  };
  /**
   * Contract addresses come from the deployment registry, never from here.
   * An entry here means "this chain is genuinely different" — the deploy
   * script treats it as a reason to stop and ask.
   */
  addressOverrides?: Partial<Record<ContractName, Address>>;
  /** Used when emissions.gauge.enabled is false. Enabled chains must sum to 100. */
  fixedEmissionSharePct: Pct;
  runsGenesis: boolean;
  genesisAcceptedAssets: readonly TokenRef[];
}

export interface EvmContractEntry {
  prefix: string;
  /** bytes32: deployer(20B) ++ 0x00 ++ mined nonce(11B). null = not mined. */
  salt: `0x${string}` | null;
  /** Pre-computed CREATE3 address, identical on every EVM chain. null = not mined. */
  address: EvmAddress | null;
  description: string;
}

export interface SolanaIdEntry {
  keypair: string; // gitignored path under keys/
  address: SolanaAddress | null; // the keypair's public key. null = not ground.
  description: string;
}

export interface DeploymentConfig {
  evm: {
    strategy: 'create3';
    factory: EvmAddress; // CreateX — same address on every supported EVM chain
    deployer: EvmAddress; // salts are guarded to this account; same address every chain
    saltGuard: 'msgSender';
    argumentFreeConstructors: true; // constructors take no args; initialize() in deploy tx
    initializeInDeployTx: true;
    contracts: Record<ContractName, EvmContractEntry>;
    /**
     * The Treasury Safe is NOT a CreateX contract — it deploys through the
     * Safe's own deterministic factory. Its salt nonce lives here so the
     * Safe's address is also decided before mining, like everything else.
     */
    treasurySafe: {
      /** Safe's own deterministic proxy factory (same on every EVM chain). */
      factory: EvmAddress;
      saltNonce: string | null;
    };
  };
  svm: {
    cluster: 'mainnet-beta' | 'devnet';
    upgradeAuthority: SolanaAddress; // Squads vault PDA holding upgrade authority
    contracts: Record<string, SolanaIdEntry>;
  };
}

export interface TokenConfig {
  name: string;
  symbol: string;
  decimals: { evm: number; svm: number };
  standard: 'lz-oft-v2' | 'single-chain-erc20';
  oft: {
    sharedDecimals: number;
    homeChain: ChainKey;
    enforcedGas: { send: number; compose: number };
    rateLimit: { amountPerWindow: Amount; windowSeconds: Seconds };
  };
  allocations: {
    kindlingPool: Amount;
    treasury: { amount: Amount; cliffDays: Days; vestingDays: Days };
    team: {
      amount: Amount;
      cliffDays: Days;
      vestingDays: Days;
      recipients: readonly { address: Address; sharePct: Pct }[];
    };
  };
  maxSupply: Amount | null;
}

export interface ShareTokenConfig {
  name: string;
  symbol: string;
  decimals: { evm: number; svm: number };
  standard: 'lz-oft-v2' | 'single-chain-erc20';
  maxSupply: Amount; // 70,000 — nothing else in the protocol can mint ASH
  /**
   * The full ASH allocation tree. The validator sums EVERY leaf recursively
   * and requires exactly 70_000. Launch = Ignition rewards + Kindling bonus.
   */
  allocations: {
    launch: { ignition: Amount; kindling: Amount }; // 41k + 1k
    forge: Amount; // 28k — trickled through Forge
  };
  forgeTrickleDays: Days;
}

export interface RelicConfig {
  key: RelicKey;
  days: Days;
  heatBump: number; // additive multiplier, e.g. 0.1 = +0.1×
  perks: {
    claimCooldownSeconds?: Seconds;
    ashfallEligible?: boolean;
    tap?: { maxPct: Pct; everyDays: Days }; // streak-preserving partial withdrawal
    kindlingPriority?: boolean;
    governanceWeight?: number;
    /** % of the protocol's Flow swap-fee share rebated to the trader. Funded pro-rata from the burn/liquidity/quote-yield slices. */
    feeRebatePct?: Pct;
  };
  art: string;
}

/**
 * Casting — LP-denominated emissions (the Masonry, done right).
 * A share of each epoch's EMBER emission is never paid liquid: the protocol
 * pairs it with quote asset from the match reserve, mints LP, and stakes it
 * directly into the earner's Forge position. The reward IS liquidity.
 */
export interface CastingConfig {
  enabled: boolean;
  /** Share of each epoch's EMBER emission cast as LP instead of paid liquid. */
  lpSharePct: Pct;
  /** Where the quote side of the cast LP comes from. */
  quoteSource: 'matchReserve';
  /**
   * Reserve dry → the user receives liquid EMBER for the uncovered share.
   * The protocol NEVER market-sells a user's emission to complete a cast.
   */
  fallback: 'liquidEmber';
  /**
   * Cast LP stakes directly into the earner's Forge position, BACK INTO THE
   * LOT THAT EARNED IT, at that lot's age — the same provenance rule as
   * Stoke. A cast is a Stoke the protocol does for you on a quarter of your
   * rewards: a 2-day lot's cast lands at 2 days, so no reward can launder
   * into old Heat. Casting modifies its reward-producing source lots and
   * consumes no lot slot, so the lossy timestamp-averaging of a rolling
   * Cast lot is gone with it.
   */
  autoStake: true;
  castLot: 'sourceLot';
  /**
   * Cast LP enters the earning lot at that lot's age — never fresh, never
   * blended. New capital, new clock applies only to genuine deposits.
   */
  entersAs: 'sourceLotAge';
  /**
   * Review fix §4.3: LP cannot be added to a single-token (EMBER, USDC) balance.
   * For stakeKind==='lp' pools: cast LP goes to the source lot (above).
   * For stakeKind==='single' pools: the cast share is paid as liquid EMBER instead.
   */
  singleTokenFallback: 'liquidEmber';
}

export interface PyreTierConfig {
  key: string;
  name: string;
  /** Cumulative EMBER burned (to the burn address) to reach this tier. */
  burnEmber: Amount;
  /** Permanent additive Heat boost, account-wide. */
  heatBoost: number;
  art: string;
}

/**
 * Pyre — burn-to-mint soulbound Heat badges.
 * Burn EMBER permanently and the Relics contract mints a soulbound badge worth
 * a fixed, capped Heat boost. A pure deflationary sink: the EMBER is gone, the
 * badge can't be sold, and the boost rewards conviction without emitting.
 * Pyre burns count as `manualBurns` in the Ashfall sources.
 */
export interface PyreConfig {
  enabled: boolean;
  tiers: readonly PyreTierConfig[];
  /** Cap on total Pyre boost. Must stay well under the time ramp. */
  maxBoost: number;
  soulbound: true;
}

export interface ConvictionTrackConfig {
  /** Track length in days. */
  days: Days;
  /** Additive bonus multiplier, e.g. 0.15 = +0.15×. */
  bonus: number;
  name: string;
}

/**
 * Deeds — positions as tradable NFTs. A Deed carries the LP (which never
 * leaves the pool on a sale), the Capstone, any conviction escrow + remaining
 * term, and unclaimed rewards. The buyer inherits `heatCarryPct` of the Heat
 * AGE; the Streak resets to 0 and badges stay with the seller, because
 * reputation is earned by a person and age is a property of capital.
 * The Keystone is dual: the seller's wallet keeps its soulbound Keystone
 * Relic (the PERSON completed the term), while the Deed carries a permanent
 * Seal Scar in its metadata (the CAPITAL completed one). Heat is
 * conserved-minus-haircut on trade: it can move, never inflate.
 */
export interface DeedConfig {
  enabled: boolean;
  /** % of the position's Heat age the buyer inherits. 80 = earned time > bought time. */
  heatCarryPct: Pct;
  /** Taken on every Deed Market sale, into the Vent. */
  marketFeePct: Pct;
  feeRouting: { burnPct: Pct; liquidityPct: Pct };
  /** Transfers only via the Deed Market contract — no OTC, no gifts. */
  marketOnlyTransfers: boolean;
  /** A Deed with a pending Withdraw or Claim cannot be listed. */
  blockListingWithPending: boolean;
  /**
   * 'auction': a listing runs a 24h ascending auction at a seller-set reserve —
   * highest bid at close wins. No instant sales: the only INSTANT exit is the
   * 8% emergency route, the auction is the fast exit, the timer is the slow
   * exit. Auctions also kill fixed-price sniping by bots.
   */
  saleMode: 'auction';
  auctionHours: Hours;
  /**
   * Anti-sniping: a valid bid inside the final `windowMinutes` extends the
   * auction by `extensionMinutes`, up to `maxTotalExtensionMinutes` total.
   * Last-second sniping becomes last-minute bidding.
   */
  antiSnipe: {
    windowMinutes: number; // 5
    extensionMinutes: number; // 5
    maxTotalExtensionMinutes: number; // 30
  };
}

/**
 * Referrals — 3% of a referee's emission share is REDIRECTED to the
 * referrer, never minted, so self-referral gains nothing net. Gated both
 * sides by relic: the recruiter must themselves be a stayer.
 */
export interface ReferralConfig {
  enabled: boolean;
  sharePct: Pct;
  refereeMinRelic: RelicKey; // e.g. 'spark'
  referrerMinRelic: RelicKey; // e.g. 'flame'
}

/**
 * Fissures — satellite-chain launches as smaller Kindlings. Loyalists get
 * first ACCESS on a new chain (priority window), never a head start:
 * Heat, Streak and badges are chain-local and never bridge.
 */
export interface FissureConfig {
  enabled: boolean;
  /** EMBER bridged from the Treasury to seed a satellite launch. */
  defaultAllocation: Amount;
  /** Loyalist-only window before a Fissure opens to everyone. */
  priorityWindowHours: Hours;
  priorityMinRelic: RelicKey; // e.g. 'inferno'
  feePct: Pct; // same as genesis
  lpSplit: { stakersPct: Pct; burnPct: Pct };
}

/**
 * Governance — explicit scope. The timelock runs launch; a vote takes over
 * later. Four things are out of reach of every vote, forever.
 */
export interface GovernanceConfig {
  model: 'timelock-then-two-chambers';
  /**
   * Two chambers, two electorates. The Hearth Chamber is ASH holders
   * (the productive governance token); the Forge Chamber is liquidity ×
   * Heat (the stakers). Operational proposals use the appropriate chamber.
   * This gives the two-token architecture its reason to exist: neither
   * Genesis ASH owners nor late liquidity whales govern alone.
   */
  chambers: {
    hearth: { electorate: 'ASH holders'; scope: 'Hearth, ASH, fee routing' };
    forge: { electorate: 'liquidity × Heat'; scope: 'Forge, staking, cooldowns' };
  };
  /**
   * Changes that require BOTH chambers: Treasury policy, new chains, Flow
   * fee bands, emission curves, new contracts.
   */
  dualChamberRequired: readonly (
    | 'treasuryPolicy'
    | 'newChains'
    | 'flowFeeBands'
    | 'emissionCurves'
    | 'newContracts'
  )[];
  relicVoteMultiplier: Record<RelicKey, number>; // eternal: 2, bedrock: 3
  /**
   * Above BOTH chambers — no vote, no chamber, no multisig can authorize
   * these. Ever.
   */
  neverAllowed: readonly (
    | 'mintOutsideMantle'
    | 'pauseWithdrawals'
    | 'touchUserBalances'
    | 'redirectVent'
  )[];
}

/**
 * Conviction tracks — opt-in bonus tracks layered ON TOP of the click-timer,
 * never replacing it. The bonus accrues daily into a vesting balance that pays
 * out only at term end. Leaving early forfeits the unvested bonus; principal
 * is never locked and never slashed, and still exits through the normal timer.
 */
export interface ConvictionTracksConfig {
  enabled: boolean;
  tracks: readonly ConvictionTrackConfig[];
  vestAtTermEnd: true;
  /**
   * The bucket is capped PER POSITION: a sealed position's bucket payout
   * can never exceed what its seal bonus would earn as extra Heat in the
   * 70% pool that epoch (bonus × its heat-pool earnings). Without the cap,
   * a single early sealer would collect the entire 10% and the 4.15×
   * ceiling would be a number in a doc. Whatever the cap holds back — and
   * the whole bucket in an epoch when nobody is sealed — flows back into
   * the Heat pool that same epoch. Conviction changes distribution, never
   * issuance.
   */
  bucketCap: {
    enabled: true;
    /** Cap each sealed position at sealBonus × its heat-pool earnings. */
    capToSealBonusOfHeatShare: true;
    /** Where the unallocated bucket goes: back into the 70% Heat pool. */
    unallocatedFlowsTo: 'heatPool';
  };
  /**
   * True escrow: the bonus is minted per epoch INTO ESCROW as part of the
   * epoch budget — the ordinary share stays claimable, the bonus share is
   * locked until term end. At term end the escrow pays into the Capstone by
   * default, so the bonus never sells.
   */
  escrow: { enabled: true; payout: 'capstone' };
  /**
   * Early exit forfeits the ESCROW (never principal): 50% burn lane, 25%
   * match reserve, 25% Sealed pot streamed to positions still inside term.
   */
  forfeitRouting: { burnPct: Pct; matchReservePct: Pct; sealedPotPct: Pct };
  /**
   * Keystone, dual ownership. The wallet earns a soulbound Keystone Relic —
   * proof the PERSON completed the term, never transfers. The Deed gets a
   * Seal Scar in permanent metadata — proof the CAPITAL completed one,
   * always travels with the Deed on sale.
   */
  keystone: {
    walletRelic: { enabled: boolean; key: string; soulbound: true };
    deedScar: { enabled: boolean };
  };
}

export interface ForgeConfig {
  fees: {
    depositPct: Pct;
    withdrawPct: Pct;
    claimPct: Pct;
    compoundPct: Pct;
    /** LP bought on the native swap stakes with no deposit fee. */
    waiveDepositFeeFromFlow: boolean;
  };
  heat: {
    startMultiplier: number;
    rampBonus: number; // added over rampDays, plus relic bumps
    rampDays: Days;
    shape: 'linear' | 'sqrt' | 'quadratic';
    depositDilution: 'weightedAverage' | 'perLot';
    compoundInheritsAge: boolean;
    /**
     * PROVENANCE-PRESERVING compounding. Rewards are tracked per lot; when
     * Stoke executes, each lot's accrued rewards compound back INTO THAT LOT.
     * Rewards generated by lot A inherit lot A's age — never the blended
     * position age, never 1.0×. A 365-day lot cannot launder a 2-day lot's
     * rewards into 365-day Heat, and compounding never dilutes legitimately
     * earned age. Strictly stronger than "fresh" or "blended" inheritance.
     */
    compoundProvenance: 'sourceLot';
    maxLotsPerPosition: number;
    /**
     * Lot exhaustion: Stoke modifies its reward-producing source lots (no
     * slot consumed). Casting stakes back into the lot that earned it (no
     * slot consumed, no rolling lot, no merge). A genuine new deposit past
     * maxLotsPerPosition → the UI offers "Open New Deed" (Deeds are
     * unlimited). Lots are NEVER lossy-merged: averaging timestamps under
     * the sqrt Heat function would change reward entitlement.
     */
    lotExhaustion: 'newDeed';
    /** 'proportional': withdrawing fraction f keeps (1-f) of Heat age. */
    withdrawCooling: 'proportional' | 'reset';
    /** 'youngestFirst': Taps burn the newest, most dilutive lots first. */
    tapDrawdownMode: 'proRata' | 'youngestFirst';
  };
  compound: {
    /** Where a Stoke lands. 'capstoneThenLp' fills the Capstone first. */
    defaultTarget: 'capstoneThenLp' | 'lp' | 'capstone';
    userCanChoose: boolean;
    lpMatch: {
      enabled: boolean;
      source: 'matchReserve';
      /** When the reserve is dry: zap the remainder or hold it in the Capstone. */
      fallback: 'zap' | 'capstone';
    };
  };
  capstone: {
    enabled: boolean;
    maxBonus: number; // +0.5× at and above ratioForMax
    ratioForMax: number; // Capstone value ÷ LP value earning maxBonus
    earnsEmissions: false;
    depositFeePct: Pct;
    withdrawFeePct: Pct;
    cooldown: 'sameAsWithdraw';
    affectsStreak: false;
    affectsHeatAge: false;
  };
  /**
   * Keeper stoking is OPT-IN per position — never open. An open 1% bounty
   * pays bots to skim every position's yield continuously on cheap-gas
   * chains, front-running owners' own free stokes. By default only the owner
   * stokes; an owner may enable keepers with their own limits below.
   */
  autoStoke: {
    enabled: boolean;
    /** Must be false: keepers are enabled per position, never by default. */
    defaultOn: boolean;
    /** What a keeper earns, bounded by the owner within these limits. */
    tip: { minPct: Pct; defaultPct: Pct; maxPct: Pct };
    /** Shortest gap between keeper stokes on one position. */
    minInterval: { minHours: Hours; defaultHours: Hours };
    /** Smallest amount a keeper may compound. */
    minSize: Amount;
  };
  casting: CastingConfig;
  pyre: PyreConfig;
  convictionTracks: ConvictionTracksConfig;
  /** Deeds: positions as tradable NFTs on the in-dapp Deed Market. */
  deeds: DeedConfig;
  /** Referrals: zero-sum, strata-gated, off by default. */
  referrals: ReferralConfig;
  /** Hard ceiling on the total multiplier any position can ever reach. */
  caps: { maxTotalMultiplier: number };
  relics: readonly RelicConfig[];
  badges: {
    standard: { evm: 'erc721-locked'; svm: 'metaplex-core-frozen' };
    metadata: 'onchain-svg' | 'ipfs';
    baseUri?: string;
    revokeOnReset: boolean; // false = badge stays, perks go dormant
  };
  withdrawResetsStreak: boolean;
  cancelReturnsAsFreshLot: boolean;
  emergencyExit: {
    enabled: boolean;
    feePct: Pct;
    routing: { burnPct: Pct; liquidityPct: Pct; stakersPct: Pct };
    /**
     * The deserter's tithe: skipping the 72h timer forfeits the position's
     * pending Ashfall, which rolls into the pool for everyone who stayed.
     */
    forfeitsAshfall: boolean;
  };
  minStakeLp: Amount;
  pools: readonly {
    id: string;
    name: string;
    stakeToken: string;
    stakeKind: 'lp' | 'single';
    allocPoints: number;
    ashAllocPoints: number;
    withdrawCooldownHours: Hours;
  }[];
}

export interface CooldownConfig {
  withdraw: {
    /** Max tier. The per-size tiers below are the source of truth. */
    seconds: Seconds;
    /**
     * Progressive cooldown: small exits cool fast, whale exits face the full
     * timer. Tiers are matched by withdrawal size as % of the position.
     * Ascending; the last tier must cover 100%.
     */
    tiers: readonly { maxWithdrawPct: Pct; seconds: Seconds }[];
    executionWindowSeconds: Seconds;
    earnsWhileCooling: boolean;
    /**
     * 'resumeFrozen': while cooling, Heat and rewards are FROZEN — the
     * position neither ages nor earns. Cancel or lapse and the position
     * resumes from the frozen Heat; the cooling interval itself did not age.
     * Only actual EXECUTION triggers proportional cooling and Streak reset.
     * Opportunity cost without the gotcha: missing the 24h window after a
     * 2-year hold no longer incinerates 2 years of Heat when no LP ever left.
     */
    onCancelOrLapse: 'freshLot' | 'resumeFrozen';
  };
  claim: {
    seconds: Seconds;
    snapshotAtRequest: boolean;
  };
  compound: { seconds: 0 };
}

export interface EmissionsConfig {
  controllerChain: ChainKey;
  epochSeconds: Seconds;
  /** Each epoch's base emission: flat by stake (newcomer floor) + by stake × Heat. */
  split: { flatPct: Pct; heatPct: Pct };
  base: {
    startPerDay: Amount;
    shape: 'halfLife' | 'linear' | 'steps';
    halfLifeDays: Days;
    floorPerDay: Amount; // a TARGET, not a guarantee — see supplyCeiling
  };
  /**
   * The 21M cap is a LIVE-supply ceiling, not a cumulative-mint ceiling:
   *   mint(epoch) = min(targetEmission(epoch), 21M − totalSupply).
   * Burns reopen mint headroom. The 1,000/day floor therefore continues
   * forever ONLY while burns create room — late-stage emissions are
   * structurally dependent on the protocol's deflation engine. Without this,
   * "hard cap + indefinite floor + never chokes" is mathematically impossible.
   */
  supplyCeiling: {
    hardCap: Amount; // must equal token.maxSupply: 21M
    mode: 'liveSupply';
  };
  /**
   * Conviction bucket: a fixed share of each epoch's mint reserved for sealed
   * positions, competing by stake × Heat × sealWeight. totalBaseMint(epoch)
   * is fixed BEFORE any position weights are evaluated — conviction affects
   * DISTRIBUTION, never total issuance. Seal bonuses can never inflate the
   * epoch.
   */
  convictionBucketPct: Pct;
  ashfall: {
    enabled: boolean;
    /**
     * Source-specific recycle rates — what fraction of each burn TYPE counts
     * toward next epoch's Ashfall. Protocol burns fund stayers at full rate;
     * Pyre burns (voluntary, registered) at half; unsolicited dead-address
     * transfers at zero — a dominant Heat² holder cannot partially rebate
     * their own voluntary burn. The token disappears in every case.
     */
    recycleRates: {
      protocolBurns: Pct; // forgeFees, swapFees, emergencyExit → 50
      pyreBurns: Pct; // registered Pyre burns → 25
      unsolicited: Pct; // dead-address transfers nobody asked for → 0
    };
    lagEpochs: number;
    minRelic: RelicKey;
    /** 'heatSquared': weight = stake × Heat² — exponential loyalty skew. */
    distributionWeight: 'linear' | 'heatSquared';
    /** An epoch with no eligible staker carries its Ashfall forward. */
    rolloverUndistributed: boolean;
    sources: readonly ('forgeFees' | 'swapFees' | 'emergencyExit' | 'manualBurns')[];
  };
  gauge: {
    enabled: boolean;
    weight: 'heatWeightedStake' | 'stake';
    reportIntervalSeconds: Seconds;
    maxCreditPerEpochPct: Pct;
  };
}

export interface FeeRoutingConfig {
  /** The Vent: every Forge fee split. */
  vent: { burnPct: Pct; liquidityPct: Pct; hearthPct: Pct; treasuryPct: Pct };
  genesisDeposit: { treasuryPct: Pct }; // must be 100 by design
  /**
   * The burn must not be MEV'd. Buybacks run through a TWAP with a hard price
   * impact cap on allowlisted routers; if conditions are unsafe the burn
   * defers instead of executing into a sandwich.
   */
  burnLane: {
    method: 'unwindAndBuyback';
    twapSeconds: Seconds;
    maxPriceImpactBps: Bps;
    allowlistedRoutersOnly: boolean;
    deferIfUnsafe: boolean;
    maxDeferralHours: Hours;
    /**
     * Four-way buy protection (on top of the TWAP): the spot price must sit
     * within `avgPriceBandBps` of the TWAP average, each buy sets its minimum
     * output at no more than `slippageCapBps` slippage from that average, no
     * single buy may exceed `maxChunkPctOfReserve` of the pool's quote
     * reserve, and a failed check fails closed — the quote asset waits in the
     * fee vault for the next vent() call.
     */
    avgPriceBandBps: Bps;
    slippageCapBps: Bps;
    maxChunkPctOfReserve: Pct;
  };
  /**
   * The fee vault: fees never hit the pool as they arrive. Every fee on a
   * chain lands in the chain's vault (part of the Vent); a permissionless
   * `vent()` call processes the vault once it crosses `minBatchUsd`, and at
   * least every `maxWaitHours` regardless. Gas stays off user transactions,
   * buys execute in batches, and no keeper is privileged.
   */
  feeVault: {
    enabled: boolean;
    minBatchUsd: number;
    maxWaitHours: Hours;
  };
  /**
   * 'matchReserve': fee LP is unwound, the EMBER half burned, the quote half
   * held to pair with Stokes; matched LP is burned as permanent liquidity.
   * 'burnLpTokens': v1 — fee LP burned whole (more POL per dollar, less burn).
   */
  liquidityLane: {
    method: 'matchReserve' | 'burnLpTokens' | 'lockerContract';
    locker?: Address;
    matchReserve?: { idleEpochsBeforeAutoPair: number; burnMatchedLp: true };
    /**
     * INVARIANT: permanently burned liquidity must be full-range /
     * non-repositionable. A burned concentrated-liquidity NFT can drift out
     * of range into economically useless liquidity that nobody can ever
     * rebalance. Concentrated venues may exist in Flow, but they are never
     * the destination of the permanent-liquidity lane without an immutable,
     * non-withdrawable rebalancer.
     */
    permanentMustBeFullRange: true;
  };
  /** Fees paid in the protocol token itself (Capstone in/out). */
  tokenFees: { burnPct: Pct };
  /**
   * Asymmetric swap fee: leavers pay more than arrivers. Each side must sum
   * to its totalBps. The sell-side surcharge funds the burn, the reserve,
   * and the quote-yield real yield — sellers pay stayers, explicitly.
   */
  swap: {
    /** Buying EMBER: cheaper, to welcome capital in. */
    buy: {
      totalBps: Bps;
      lpBps: Bps;
      burnBps: Bps;
      liquidityBps: Bps;
      treasuryBps: Bps;
    };
    /** Selling EMBER: the surcharge is the price of leaving. */
    sell: {
      totalBps: Bps;
      lpBps: Bps;
      burnBps: Bps;
      liquidityBps: Bps;
      /** Real yield: paid in the chain's quote asset to loyal stakers, not EMBER. */
      quoteYieldBps: Bps;
      treasuryBps: Bps;
    };
    waiveProtocolShareOnCompound: boolean;
  };
  /**
   * Quote yield — the real-yield slice. A share of every Flow swap fee is paid
   * in the chain's quote asset (ETH/WETH/BNB/SOL…) to stakers holding an
   * ashfall-eligible relic, weighted by stake × Heat² like Ashfall. It sits
   * beside emissions; it does not replace them.
   */
  quoteYield: {
    enabled: boolean;
    eligibility: 'ashfallEligible';
    asset: 'quoteAsset';
  };
  burnAddress: { evm: EvmAddress; svm: SolanaAddress };
}

export interface SwapConfig {
  amm: 'protocol-cpmm';
  listLpAsAsset: boolean;
  tokenListOrder: readonly string[]; // 'LP' = the protocol pair on each chain
  zap: { defaultSlippageBps: Bps; maxSlippageBps: Bps; stakeAfterZap: 'offer' | 'always' | 'never' };
  showPriceImpact: boolean;
  showLpPrice: boolean;
  showTwentyFourHourChange: boolean;
}

export interface TreasuryConfig {
  addresses: Record<ChainKey, Address>;
  controller: { type: 'safe-multisig' | 'squads'; threshold: number; signers: readonly Address[] };
  timelockSeconds: Seconds;
  policy: {
    polSeedingPct: Pct;
    matchReserveSeedPct: Pct;
    incentivesPct: Pct;
    buybackPct: Pct;
    reportOnChain: boolean;
  };
}

export interface SecurityConfig {
  feeCeilings: { depositPct: Pct; withdrawPct: Pct; genesisPct: Pct; emergencyPct: Pct; swapBps: Bps; deedSalePct: Pct };
  paramTimelockSeconds: Seconds;
  pausable: { deposits: boolean; swaps: boolean; withdrawalsNever: true };
  upgradeable: { core: boolean; periphery: boolean };
  guardian: Record<ChainKey, Address>;
  audits: readonly { firm: string; reportUrl: string; date: string }[];
  bugBountyUrl?: string;
}

export interface UiConfig {
  timeline: {
    show: boolean;
    showRelicMarkers: boolean;
    showNextBumpCountdown: boolean;
    showHeatVsStreakNote: boolean;
    pendingWithdrawAsRedSegment: boolean;
    horizonDays: Days;
  };
  /** The position card shows impermanent loss next to Heat — IL is the staker's problem and the UI says so. */
  positionCard: { showImpermanentLoss: boolean };
  countdown: { style: 'flip' | 'ring' | 'digits'; showInNav: boolean; browserNotification: boolean };
  readyButtonColor: string; // the only green in the app
  locale: string;
  numberFormat: { compact: boolean; aprDecimals: number };
  charts: { emissionCurve: boolean; heatCurve: boolean; supplyChart: boolean };
}

export interface IgnitionConfig {
  name: string;
  address: EvmAddress;
  durationHours: Hours;
  minDurationHours: Hours;
  maxDurationHours: Hours;
  startTimestamp: number | null;
  depositFeePct: Pct; // 3% — straight to treasury, no splits
  feeDestination: 'treasury';
  /**
   * Nothing is ever locked — not even in Ignition. Principal can be
   * withdrawn at any time during the window; the 3% genesis fee is not
   * refunded. (v5.2 locked it; the lock contradicted the protocol's
   * load-bearing invariant.)
   */
  withdrawDuringWindow: { enabled: true; refundFee: false };
  exitWindowHours: Hours;
  exitFeePct: Pct;
  pools: readonly { id: string; stakeToken: string; weight: number; name: string }[];
  rewards: { token: 'ASH'; total: Amount; mode: 'per-second-pro-rata'; vesting: 'none' };
  founderBadge: { enabled: boolean; key: string; phantomAgeBonusDays: Days };
  heatHeadStart: 'ignitionStart' | 'poolOpen';
  /**
   * Where Ignition principal goes at close. EMBER doesn't exist until
   * Kindling closes and only USDC has a Forge pool, so "auto-staked as LP"
   * couldn't happen as written. Instead: USDC auto-stakes into Cold Storage
   * (unless the depositor opted out at deposit); WETH, WBTC and WETH/USDC
   * LP become claimable fee-free. The Heat head start (age dated to
   * Ignition start) applies to the first Forge Deed the depositor opens or
   * funds within `headStartWindowDays` of Kindling close, up to the USD
   * value they kept in Ignition through close.
   */
  principalAtClose: {
    usdc: 'autoStakeColdStorage';
    usdcOptOutAtDeposit: boolean;
    otherAssets: 'claimableFeeFree';
    headStartWindowDays: Days;
    headStartCappedToUsdKept: boolean;
  };
  /**
   * Early-bird: Ignition rewards weight decays from +maxBonusPct at the first
   * second to +0% at close. Rewards early commitment without minting anything
   * dumpable — on top of the per-second pro-rata, not instead of it.
   */
  earlyBird: { enabled: boolean; maxBonusPct: Pct; shape: 'linear' | 'exponential' };
}

export interface KindlingConfig {
  enabled: boolean;
  name: string;
  address: EvmAddress;
  mode: 'auction' | 'treasury-seed' | 'none';
  durationHours: Hours;
  quoteToken: string;
  seedEmberBpsOfMax: Bps;
  minRaiseUsd: number;
  maxRaiseUsd: number;
  maxPerWalletUsd: number;
  /** 3% of every deposit goes straight to the treasury — the genesis fee, same as Ignition. */
  depositFeePct: Pct;
  feeDestination: 'treasury';
  priceMode: 'clearing';
  polPair: string;
  /**
   * Kindling LP split — the depositor accounting hole, closed. 90% of the
   * Kindling LP becomes auto-staked Deeds OWNED BY THE DEPOSITORS (pro-rata
   * to their raise contribution); 10% is burned forever as the irrevocable
   * liquidity floor. Not Bond LP, not governance-extractable, not a lock —
   * the LP is theirs, staked, earning, and exitable under normal rules.
   */
  lpSplit: { depositorDeedsPct: Pct; burnPct: Pct };
  ashBonusPool: Amount;
  fallback: 'treasury-seed';
  /** The deposit that passes the deadline atomically creates the pool, pairs
   *  assets and burns the LP in the same transaction — zero MEV window. */
  atomicPoolInit: boolean;
  /**
   * Bounty (bps of the raise, from the Treasury's fee) to whoever calls the
   * permissionless atomic close. Bots race to close it the second it is due —
   * no EOA to wait for, nothing to front-run.
   */
  closeBountyBps: Bps;
}

export interface FurnaceConfig {
  version: string;
  brand: BrandConfig;
  names: NamesConfig;
  pages: readonly PageConfig[];
  copy: CopyConfig;
  chains: readonly ChainConfig[];
  deployment: DeploymentConfig;
  token: TokenConfig;
  shareToken: ShareTokenConfig;
  ignition: IgnitionConfig;
  kindling: KindlingConfig;
  forge: ForgeConfig;
  cooldowns: CooldownConfig;
  emissions: EmissionsConfig;
  fees: FeeRoutingConfig;
  swap: SwapConfig;
  treasury: TreasuryConfig;
  security: SecurityConfig;
  ui: UiConfig;
  /** Satellite-chain launches: smaller Kindlings with a loyalist priority window. */
  fissures: FissureConfig;
  /** Governance scope: what a vote can touch, and what it can never touch. */
  governance: GovernanceConfig;
}

// ─── Deterministic deployment registry ──────────────────────────────────────
export const CREATEX_FACTORY: EvmAddress = '0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed';
// ⚠ SET BEFORE MINING. One EOA, same address on every chain. All salts are
// guarded to it: only this account can ever deploy these addresses.
export const DEPLOYER: EvmAddress = '0x1111111111111111111111111111111111111111'; // ← REPLACE ME

// <generated:evm-contracts> — written by `pnpm mine:salts`. DO NOT EDIT BY HAND.
const evmContracts = {
  EmberToken: {
    salt: '0x111111111111111111111111111111111111111100000000000000000001415e',
    address: '0xf1e5b7820a8c6f6349a576db516142c8d341dcc4',
    prefix: 'F1E5',
    description: 'EMBER — LayerZero OFT protocol token',
  },
  AshToken: {
    salt: '0x11111111111111111111111111111111111111110000000000000000000014c3',
    address: '0xa5e55c164036f63e9b6e6337c465eedead49fb5b',
    prefix: 'A5E5',
    description: 'ASH — LayerZero OFT share/governance token',
  },
  FeeRouter: {
    salt: '0x111111111111111111111111111111111111111100000000000000000000faf3',
    address: '0xfee5356949802d661959360a5e4004e1d8c685a2',
    prefix: 'FEE5',
    description: 'FeeRouter — auto-routes fees to burn + liquidity',
  },
  Forge: {
    salt: '0x11111111111111111111111111111111111111110000000000000000000135c5',
    address: '0xf09551c13e2ca9cbeed634452a1f37d89a25532d',
    prefix: 'F095',
    description: 'Forge — post-launch staking (all pools)',
  },
  Ignition: {
    salt: '0x11111111111111111111111111111111111111110000000000000000000035e7',
    address: '0x19172ad5c06ccc86a6e2712d06500f1028cf185b',
    prefix: '1917',
    description: 'Ignition — Genesis bootstrap staking',
  },
  Kindling: {
    salt: '0x1111111111111111111111111111111111111111000000000000000000005c57',
    address: '0x5a1d6ee608bf6e94b53789824705427ea40f2746',
    prefix: '5A1D',
    description: 'Kindling — liquidity bootstrap auction',
  },
  Hearth: {
    salt: '0x111111111111111111111111111111111111111100000000000000000004d0a0',
    address: '0xea272470c2529afe408d13bf6057b72a1a8763ce',
    prefix: 'EA27',
    description: 'Hearth — ASH staking, fee share + governance',
  },
  Relics: {
    salt: '0x111111111111111111111111111111111111111100000000000000000001d233',
    address: '0x2e1c923b32c214c4b7b2b8bd30daeb9f0a183dbd',
    prefix: '2E1C',
    description: 'Relics — soulbound duration-milestone NFTs',
  },
  Deeds: {
    salt: '0x1111111111111111111111111111111111111111000000000000000000015534',
    address: '0xdeed54948eab9875d89a77cc383714d6a5d7dc6d',
    prefix: 'DEED',
    description: 'Deeds — position NFTs + the Deed Market',
  },
} as const;
// </generated:evm-contracts>

// <generated:solana-ids> — written by `pnpm gen:solana-ids`. DO NOT EDIT BY HAND.
const solanaIds = {
  stakingProgram: {
    keypair: 'keys/staking-program.json',
    address: 'HVQT6MycoarDw9ktbZBv282HH8SttSR4ycvTeSTw9kKe',
    description: 'Furnace staking program (Forge + Ignition)',
  },
  feeRouterProgram: {
    keypair: 'keys/fee-router-program.json',
    address: 'ECgH9KPnFW9GoM9fe6uVYrmaJpQMsacA8EiiSKwo3Egu',
    description: 'FeeRouter program (burn + POL builder)',
  },
  emberMint: {
    keypair: 'keys/ember-mint.json',
    address: 'AtbnZK5DQibjpxkhynqq7617iuseoWaABytXN7Q3RnbD',
    description: 'EMBER SPL mint (9 decimals)',
  },
  ashMint: {
    keypair: 'keys/ash-mint.json',
    address: '7a2HrKABUqNEsPntziBaDMVMboQ6hThWJVFu9Zp3cAnW',
    description: 'ASH SPL mint (9 decimals)',
  },
  relicsCollection: {
    keypair: 'keys/relics-collection.json',
    address: 'GgpFhkNfS4Y16gX746NNzWJup6yDcpCRHjw5NNVKFdCL',
    description: 'Relics Metaplex collection mint (soulbound)',
  },
} as const;
// </generated:solana-ids>

export type ContractName = keyof typeof evmContracts;

/** The ONLY way any module gets an EVM contract address. Throws if unmined. */
export function contractAddress(name: ContractName): EvmAddress {
  const entry = evmContracts[name] as { address: EvmAddress | null };
  if (!entry || !entry.address || /^0x0+$/.test(entry.address)) {
    throw new Error(`[furnace.config] no mined address for "${name}" — run \`pnpm mine:salts\``);
  }
  return entry.address;
}

/** Static chain → VM map (must match chains[]; cross-checked in validateConfig). */
const CHAIN_VM: Record<string, 'evm' | 'svm'> = {
  ethereum: 'evm', bsc: 'evm', base: 'evm', arbitrum: 'evm', solana: 'svm',
};

// ─── Shared references ──────────────────────────────────────────────────────
const LZ_ENDPOINT_V2_EVM: EvmAddress = '0x1a44076050125825900e736c501f859c50fE728c'; // verify per chain
const DEAD: EvmAddress = '0x000000000000000000000000000000000000dEaD';

// Well-known assets. Verify every address on the chain's explorer before deploy.
const ETH_WETH: TokenRef = { symbol: 'WETH', address: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', decimals: 18, conversion: 'none' };
const ETH_USDC: TokenRef = { symbol: 'USDC', address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', decimals: 6, conversion: 'swapAtClose', maxSlippageBps: 50 };
const ETH_WBTC: TokenRef = { symbol: 'WBTC', address: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599', decimals: 8 };
const BSC_WBNB: TokenRef = { symbol: 'WBNB', address: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c', decimals: 18, conversion: 'none' };
const BSC_USDT: TokenRef = { symbol: 'USDT', address: '0x55d398326f99059fF775485246999027B3197955', decimals: 18, conversion: 'swapAtClose', maxSlippageBps: 50 };
const BASE_WETH: TokenRef = { symbol: 'WETH', address: '0x4200000000000000000000000000000000000006', decimals: 18, conversion: 'none' };
const BASE_USDC: TokenRef = { symbol: 'USDC', address: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', decimals: 6, conversion: 'swapAtClose', maxSlippageBps: 50 };
const ARB_WETH: TokenRef = { symbol: 'WETH', address: '0x82aF49447D8a07e3bd95BD0d56f35241523fBab1', decimals: 18, conversion: 'none' };
const ARB_USDC: TokenRef = { symbol: 'USDC', address: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831', decimals: 6, conversion: 'swapAtClose', maxSlippageBps: 50 };
const SOL_WSOL: TokenRef = { symbol: 'wSOL', address: 'So11111111111111111111111111111111111111112', decimals: 9, conversion: 'none' };
const SOL_USDC: TokenRef = { symbol: 'USDC', address: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', decimals: 6, conversion: 'swapAtClose', maxSlippageBps: 50 };

// ─── Name presets ─────────────────────────────────────────────────────────
// One line rebrands the entire vocabulary: names: namePresets.tephra.
// FURNACE_NAMES is the default; TEPHRA_NAMES is the reference brand.

const FURNACE_NAMES: NamesConfig = {
  genesis: 'Ignition',
  staking: 'The Forge',
  swap: 'Flow',
  treasury: 'The Vault',
  burn: 'The Vent',
  badges: 'Relics',
  reemission: 'Ashfall',
  emissions: 'The Emberwell',
  multiplier: 'Heat',
  streak: 'Streak',
  lot: 'Lot',
  capstone: 'Capstone',
  matchReserve: 'Match Reserve',
  casting: 'Casting',
  pyre: 'Pyre',
  tracks: 'Conviction tracks',
  deed: 'Deed',
  cooldowns: { withdraw: 'Cooling', claim: 'Venting', compound: 'Stoke', emergency: 'Emergency exit' },
  relics: { spark: 'Spark', flame: 'Flame', blaze: 'Blaze', inferno: 'Inferno', eternal: 'Eternal Flame', bedrock: 'Bedrock' },
  founderBadge: 'First Flame',
};

const TEPHRA_NAMES: NamesConfig = {
  genesis: 'Eruption',
  staking: 'The Caldera',
  swap: 'Flow',
  treasury: 'Magma Chamber',
  burn: 'The Vent',
  badges: 'Strata',
  reemission: 'Ashfall',
  emissions: 'The Mantle',
  multiplier: 'Heat',
  streak: 'Streak',
  lot: 'Lot',
  capstone: 'Capstone',
  matchReserve: 'Match reserve',
  casting: 'Casting',
  pyre: 'Cinders',
  tracks: 'Seals',
  deed: 'Deed',
  cooldowns: { withdraw: 'Cooling', claim: 'Venting', compound: 'Stoke', emergency: 'Emergency exit' },
  relics: { spark: 'Pumice', flame: 'Basalt', blaze: 'Obsidian', inferno: 'Granite', eternal: 'Diamond', bedrock: 'Bedrock' },
  founderBadge: 'First Flow',
};

export const namePresets = { furnace: FURNACE_NAMES, tephra: TEPHRA_NAMES } as const;

// ─── The config ─────────────────────────────────────────────────────────────
export const furnaceConfig = {
  version: '5.3.1',

  brand: {
    protocolName: 'FURNACE',
    shortName: 'Furnace',
    tagline: 'Stake longer. Burn brighter.',
    description:
      'An omnichain loyalty-staking protocol where every fee burns or deepens liquidity, every reward is weighted by how long you have stayed, and compounding is the only instant, free move.',
    domain: 'furnace.fi',
    supportEmail: 'hello@furnace.fi',
    assets: {
      logo: '/brand/furnace-wordmark.svg',
      logoMark: '/brand/furnace-mark.svg',
      favicon: '/brand/favicon.svg',
      ogImage: '/brand/og.png',
      tokenIcon: '/brand/ember.svg',
      lpIcon: '/brand/ember-eth-lp.svg',
      relicArtDir: '/brand/relics/',
    },
    theme: {
      mode: 'dark',
      colors: {
        bg: '#0d0a08', surface: '#171310', surfaceRaised: '#221b16', border: '#33281f',
        text: '#f5ede6', textMuted: '#a89a8c',
        accent: '#ff6a00', accentGlow: '#ffb347',
        warning: '#f59e0b', danger: '#e5484d',
        ready: '#22c55e', // the only green: Withdraw Now / Claim Now
        heat: '#ff7a00', cooling: '#6b7a8f',
      },
      fonts: { display: 'Space Grotesk', body: 'Inter', mono: 'JetBrains Mono' },
      radius: '14px',
    },
    social: {
      x: 'https://x.com/furnacefi',
      discord: 'https://discord.gg/furnacefi',
      telegram: 'https://t.me/furnacefi',
      github: 'https://github.com/furnacefi',
      docs: 'https://docs.furnace.fi',
    },
    legal: {
      termsUrl: 'https://furnace.fi/terms',
      riskDisclosureUrl: 'https://furnace.fi/risk',
    },
  },

  // One-line rebrand: names: namePresets.tephra
  names: namePresets.furnace,

  pages: [
    { key: 'dashboard', path: '/', title: 'Dashboard', navLabel: 'Home', order: 0, enabled: true, gate: 'always' },
    { key: 'ignition', path: '/ignition', title: 'Ignition', navLabel: 'Ignition', order: 1, enabled: true, gate: 'duringGenesis' },
    { key: 'kindling', path: '/kindling', title: 'Kindling', navLabel: 'Kindling', order: 2, enabled: true, gate: 'duringGenesis' },
    { key: 'forge', path: '/forge', title: 'The Forge', navLabel: 'Forge', order: 3, enabled: true, gate: 'afterGenesis' },
    { key: 'relics', path: '/relics', title: 'Relics', navLabel: 'Relics', order: 4, enabled: true, gate: 'afterGenesis' },
    { key: 'hearth', path: '/hearth', title: 'The Hearth', navLabel: 'Hearth', order: 5, enabled: true, gate: 'afterGenesis' },
    { key: 'flow', path: '/flow', title: 'Flow', navLabel: 'Flow', order: 6, enabled: true, gate: 'afterGenesis' },
    { key: 'deeds', path: '/deeds', title: 'Deed Market', navLabel: 'Deeds', order: 7, enabled: true, gate: 'afterGenesis' },
    { key: 'docs', path: '/docs', title: 'Docs', navLabel: 'Docs', order: 8, enabled: true, gate: 'always' },
  ],

  copy: {
    buttons: {
      connect: 'Connect wallet',
      genesisDeposit: 'Join the Ignition',
      genesisWithdraw: 'Pull out (fee not refunded)',
      deposit: 'Stake',
      withdraw: 'Start cooling',
      withdrawNow: 'Withdraw Now',
      claim: 'Start venting',
      claimNow: 'Claim Now',
      compound: 'Compound',
      stokeToCapstone: 'Stoke into Capstone',
      stokeToLp: 'Stoke into LP',
      cancel: 'Cancel',
      emergency: 'Emergency exit',
      tap: 'Use a Tap',
      feedPyre: 'Feed the Pyre',
      chooseTrack: 'Choose a track',
      zapStake: 'Stake it',
      swap: 'Swap',
      buyLp: 'Buy LP',
      sellLp: 'Sell LP',
      listDeed: 'List this Deed',
      buyDeed: 'Buy this Deed',
      delistDeed: 'Delist',
      placeBid: 'Place bid',
    },
    warnings: {
      withdrawResets: 'Withdrawing resets your {streak} to day 0 and cools your {multiplier} proportionally. Cooling takes {withdrawHours} h and the liquidity earns nothing while it cools.',
      claimVsCompound: '{compoundVerb} is instant and keeps your {multiplier}. Claiming starts a {claimHours} h timer.',
      emergency: 'This skips the timer and costs {emergencyFee}%: {emergencyBurn}% burned, {emergencyLiquidity}% to permanent liquidity, {emergencyStakers}% to everyone who stayed.',
      depositDilutes: 'New liquidity enters at 1.0×. Your blended {multiplier} will drop to {newMultiplier}×.',
      genesisFee: '{genesisFee}% of this deposit goes to the {treasury} now and is not refundable.',
      tapNotice: 'A Tap keeps your {streak}. The {withdrawFee}% fee and the cooling timer still apply.',
      withdrawCools: 'Withdrawing {pct}% keeps {keptPct}% of your {multiplier} age and resets your {streak}.',
      capstone: '{capstone} earns no emissions. It adds up to +{maxBonus}× {multiplier} when it is worth {ratioForMax}% of your LP, and it never sells.',
      stokeFallback: 'The {matchReserve} is dry, so this Stoke will zap: half of it sells for the quote asset on the pool. Stoke into {capstone} instead to sell nothing.',
      pyreBurn: 'Burning {amount} {symbol} is permanent and irreversible. The {pyre} badge is soulbound — it can never be sold — and its +{boost}× {multiplier} lasts forever.',
      castingNote: '{pct}% of every emission is {casting}: paired with the {matchReserve} and staked back into the lot that earned it, at that lot\'s age. It never dilutes your {multiplier} — a 365-day lot\'s cast lands at 365 days. It can never be dumped — only withdrawn like the rest of your stake.',
      trackForfeit: 'Leaving before day {days} forfeits the unvested +{bonus}× {tracks} bonus. Your principal is never locked and never slashed — it still exits through the normal {withdraw} timer.',
      deedSale: 'Selling this {deed} moves the LP, {capstone}, escrow and rewards to the buyer — the pool never loses liquidity. The buyer inherits {heatCarry}% of your {multiplier} age; your {streak} resets and your badges stay with you. A completed {seal} term leaves a permanent Seal Scar on the {deed}; your Keystone Relic stays in your wallet forever. {marketFee}% goes to the {feeRouter}.',
      deedBuy: 'This {deed} carries {heatAge} days of {multiplier} age ({heatCarry}% of what the seller earned). The {streak} starts at 0 for you; badges are earned, never bought.',
      sealForfeit: 'Withdrawing before the {tracks} term ends forfeits the escrowed bonus: {burn}% burned, {reserve}% to the {matchReserve}, {pot}% to positions still inside their term. Principal is untouched.',
      deedAuction: 'This {deed} sells by {auctionHours}-hour auction at a reserve of {reserve} {currency}. Highest bid at close wins; {marketFee}% of the final price goes to the {feeRouter}. No instant sale — the only instant exit is the emergency route.',
    },
    toasts: {
      cooling: 'Cooling started. {withdrawHours} h to go.',
      readyToWithdraw: 'Cooled. Withdraw Now is live for {windowHours} h.',
      venting: 'Venting started. {claimHours} h to go.',
      readyToVent: 'Vented. Claim Now is live.',
      stoked: 'Stoked. {amount} {symbol} added at {multiplier}×.',
      lapsed: 'Your withdraw window lapsed. Nothing left the pool — your position resumes at the {multiplier} it froze at.',
      pyreMinted: '{pyre} {tier} forged. +{boost}× {multiplier}, forever.',
      emissionCast: '{pct}% of your emission was cast as LP and staked.',
      trackVested: '{tracks} complete: +{bonus}× bonus vested.',
      quoteYieldPaid: 'Real yield: {amount} {symbol} from swap fees.',
      deedListed: '{deed} listed for {price} {currency}.',
      deedSold: '{deed} sold. {fee} went to the {feeRouter}; the pool kept its liquidity.',
      deedBought: '{deed} bought with {heatAge} days of {multiplier} age.',
      keystoneMinted: 'Keystone forged — your {tracks} term is complete.',
      sealForfeited: 'Escrow forfeited: {burn} burned, {reserve} to the reserve, {pot} to the Sealed.',
      bidPlaced: 'Bid placed: {amount} {currency}. Auction ends in {time}.',
      deedAuctionWon: 'Auction won — the {deed} is yours with {heatAge} days of {multiplier} age.',
      deedAuctionExpired: 'Auction ended below reserve. Your {deed} was delisted.',
    },
    timeline: {
      title: 'Your {streak}',
      heatVsStreak: 'Your {date} top-up set your {multiplier} back {days} days.',
      nextBump: 'Next relic: {relic} in {days} days (+{bump}×).',
      pending: 'Cooling {amount} LP — withdraw in {time}.',
    },
    empty: {
      noPosition: 'Nothing in the {staking} yet. Stake LP or buy some on {swap}.',
      noRelics: 'Your first relic forms at {firstRelicDays} days.',
    },
  },

  chains: [
    {
      key: 'ethereum', name: 'Ethereum', vm: 'evm', enabled: true, role: 'home',
      chainId: 1, nativeSymbol: 'ETH',
      rpcUrls: ['https://eth.llamarpc.com'], explorerUrl: 'https://etherscan.io',
      lz: { eid: 30101, endpoint: LZ_ENDPOINT_V2_EVM, dvns: [], requiredDvnCount: 2 },
      quoteAsset: ETH_WETH,
      listedTokens: [ETH_USDC, ETH_WBTC],
      // review §7: the source had a 19-byte (truncated) router. Replaced with UniswapV2Router02
      // as published at docs.uniswap.org/contracts/v2/reference/smart-contracts/v2-deployments
      // (EIP-55 checksum verified by validateConfig). Re-confirm runtime code hash at deploy.
      externalDex: { kind: 'uniswap-v2', router: '0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D' },
      fixedEmissionSharePct: 45,
      runsGenesis: true,
      genesisAcceptedAssets: [ETH_WETH, ETH_USDC, ETH_WBTC],
    },
    {
      key: 'bsc', name: 'BNB Chain', vm: 'evm', enabled: true, role: 'satellite',
      chainId: 56, nativeSymbol: 'BNB',
      rpcUrls: ['https://bsc-dataseed.binance.org'], explorerUrl: 'https://bscscan.com',
      lz: { eid: 30102, endpoint: LZ_ENDPOINT_V2_EVM, dvns: [], requiredDvnCount: 2 },
      quoteAsset: BSC_WBNB,
      listedTokens: [BSC_USDT],
      externalDex: { kind: 'pancake-v2', router: '0x10ED43C718714eb63d5aA57B78B54704E256024E' },
      fixedEmissionSharePct: 20,
      runsGenesis: false,
      genesisAcceptedAssets: [BSC_WBNB, BSC_USDT],
    },
    {
      key: 'base', name: 'Base', vm: 'evm', enabled: true, role: 'satellite',
      chainId: 8453, nativeSymbol: 'ETH',
      rpcUrls: ['https://mainnet.base.org'], explorerUrl: 'https://basescan.org',
      lz: { eid: 30184, endpoint: LZ_ENDPOINT_V2_EVM, dvns: [], requiredDvnCount: 2 },
      quoteAsset: BASE_WETH,
      listedTokens: [BASE_USDC],
      externalDex: { kind: 'aerodrome', router: '0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43' },
      fixedEmissionSharePct: 15,
      runsGenesis: false,
      genesisAcceptedAssets: [BASE_WETH, BASE_USDC],
    },
    {
      key: 'arbitrum', name: 'Arbitrum One', vm: 'evm', enabled: true, role: 'satellite',
      chainId: 42161, nativeSymbol: 'ETH',
      rpcUrls: ['https://arb1.arbitrum.io/rpc'], explorerUrl: 'https://arbiscan.io',
      lz: { eid: 30110, endpoint: LZ_ENDPOINT_V2_EVM, dvns: [], requiredDvnCount: 2 },
      quoteAsset: ARB_WETH,
      listedTokens: [ARB_USDC],
      externalDex: { kind: 'uniswap-v3', router: '0xE592427A0AEce92De3Edee1F18E0157C05861564' },
      fixedEmissionSharePct: 10,
      runsGenesis: false,
      genesisAcceptedAssets: [ARB_WETH, ARB_USDC],
    },
    {
      key: 'solana', name: 'Solana', vm: 'svm', enabled: true, role: 'satellite',
      cluster: 'mainnet-beta', nativeSymbol: 'SOL',
      rpcUrls: ['https://api.mainnet-beta.solana.com'], explorerUrl: 'https://solscan.io',
      lz: { eid: 30168, endpoint: '76y77prsiCMvXMjuoZ5VRrhG5qYBrUMYTE5WgHqgjEn6', dvns: [], requiredDvnCount: 2 },
      quoteAsset: SOL_WSOL,
      listedTokens: [SOL_USDC],
      externalDex: { kind: 'jupiter', router: 'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4' },
      fixedEmissionSharePct: 10,
      runsGenesis: false,
      genesisAcceptedAssets: [SOL_WSOL, SOL_USDC],
    },
  ],

  deployment: {
    evm: {
      strategy: 'create3',
      factory: CREATEX_FACTORY,
      deployer: DEPLOYER,
      saltGuard: 'msgSender',
      argumentFreeConstructors: true,
      initializeInDeployTx: true,
      contracts: evmContracts,
      treasurySafe: {
        factory: '0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67', // Safe's deterministic proxy factory
        saltNonce: null, // ← SET BEFORE MINING
      },
    },
    svm: {
      cluster: 'mainnet-beta',
      upgradeAuthority: '', // Squads vault PDA; set before mainnet
      contracts: solanaIds,
    },
  },

  token: {
    name: 'Ember',
    symbol: 'EMBER',
    decimals: { evm: 18, svm: 9 },
    standard: 'lz-oft-v2',
    oft: {
      sharedDecimals: 6,
      homeChain: 'ethereum',
      enforcedGas: { send: 80_000, compose: 200_000 },
      rateLimit: { amountPerWindow: '250000', windowSeconds: 3600 },
    },
    allocations: {
      kindlingPool: '420000', // 2% of max, minted once for the Kindling auction
      treasury: { amount: '500000', cliffDays: 0, vestingDays: 365 },
      team: { amount: '0', cliffDays: 180, vestingDays: 730, recipients: [] },
    },
    maxSupply: '21000000',
  },

  shareToken: {
    name: 'Ash',
    symbol: 'ASH',
    decimals: { evm: 18, svm: 9 },
    standard: 'lz-oft-v2',
    maxSupply: '70000',
    allocations: {
      launch: { ignition: '41000', kindling: '1000' }, // 42k Launch total
      forge: '28000', // trickled through Forge
    },
    forgeTrickleDays: 730,
  },

  ignition: {
    name: 'IGNITION',
    address: contractAddress('Ignition'),
    durationHours: 120,
    minDurationHours: 48,
    maxDurationHours: 336,
    startTimestamp: null,
    depositFeePct: 3, // straight to treasury — no splits, no router
    feeDestination: 'treasury',
    // Nothing locked, even here: withdraw anytime during Ignition, fee not refunded.
    withdrawDuringWindow: { enabled: true, refundFee: false },
    exitWindowHours: 24,
    exitFeePct: 0,
    pools: [
      { id: 'ign-usdc', stakeToken: 'USDC', weight: 100, name: 'USDC Pool' },
      { id: 'ign-weth', stakeToken: 'WETH', weight: 100, name: 'WETH Pool' },
      { id: 'ign-wbtc', stakeToken: 'WBTC', weight: 100, name: 'WBTC Pool' },
      { id: 'ign-eth-usdc-lp', stakeToken: 'WETH/USDC', weight: 150, name: 'WETH/USDC LP Pool' },
    ],
    rewards: { token: 'ASH', total: '41000', mode: 'per-second-pro-rata', vesting: 'none' },
    founderBadge: { enabled: true, key: 'first-flame', phantomAgeBonusDays: 15 },
    heatHeadStart: 'ignitionStart',
    // At close: USDC auto-stakes into Cold Storage (opt-out at deposit);
    // WETH/WBTC/LP claimable fee-free; the Heat head start rides on the
    // first Deed opened/funded within 7 days of Kindling close, capped to
    // the USD value kept through close.
    principalAtClose: {
      usdc: 'autoStakeColdStorage',
      usdcOptOutAtDeposit: true,
      otherAssets: 'claimableFeeFree',
      headStartWindowDays: 7,
      headStartCappedToUsdKept: true,
    },
    // Early-bird: +10% reward weight at the first second, decaying linearly to
    // +0% at close. Urgency for the bootstrap without a first-block landgrab.
    earlyBird: { enabled: true, maxBonusPct: 10, shape: 'linear' },
  },

  kindling: {
    enabled: true,
    name: 'KINDLING',
    address: contractAddress('Kindling'),
    mode: 'auction',
    durationHours: 24,
    quoteToken: 'USDC',
    seedEmberBpsOfMax: 200, // 2% of EMBER max minted once
    minRaiseUsd: 100_000,
    maxRaiseUsd: 5_000_000,
    maxPerWalletUsd: 25_000,
    depositFeePct: 3, // genesis fee — straight to treasury, no splits
    feeDestination: 'treasury',
    priceMode: 'clearing',
    polPair: 'EMBER/USDC',
    // 90% of Kindling LP → auto-staked Deeds owned by depositors (pro-rata);
    // 10% → burned forever. The atomic close does all of it in one tx.
    lpSplit: { depositorDeedsPct: 90, burnPct: 10 },
    ashBonusPool: '1000',
    fallback: 'treasury-seed',
    atomicPoolInit: true, // final deposit past the deadline creates the pool,
    // pairs assets, mints depositor Deeds, burns 10% of the LP in the SAME
    // transaction — zero MEV window
    closeBountyBps: 5, // 0.05% of the raise to whoever calls the permissionless atomic close
  },

  forge: {
    fees: {
      depositPct: 1,
      withdrawPct: 1,
      claimPct: 0,
      compoundPct: 0,
      waiveDepositFeeFromFlow: true, // LP bought on the native swap stakes free;
      // zero-fee zaps earn no Ashfall that epoch (sybil guard)
    },
    heat: {
      startMultiplier: 1.0,
      rampBonus: 1.5, // 1.0× → 2.5× over rampDays, plus relic bumps → 3.0×
      rampDays: 365,
      shape: 'sqrt', // diminishing returns: early loyalty matters most
      depositDilution: 'perLot', // each lot keeps its own age; new money never inherits old Heat
      compoundInheritsAge: true,
      // Provenance-preserving: each lot's rewards compound back into that lot.
      compoundProvenance: 'sourceLot',
      maxLotsPerPosition: 32,
      // Exhaustion: Stoke touches source lots (no slot); Casting has its own
      // rolling lot; past 32 the UI offers "Open New Deed". Never merge lots.
      lotExhaustion: 'newDeed',
      withdrawCooling: 'proportional', // withdrawing f keeps (1-f) of Heat age
      tapDrawdownMode: 'youngestFirst', // Taps burn newest lots first → Heat rises
    },
    compound: {
      defaultTarget: 'capstoneThenLp',
      userCanChoose: true,
      lpMatch: {
        enabled: true,
        source: 'matchReserve',
        fallback: 'zap', // reserve dry → zap (sells half); Capstone target sells nothing
      },
    },
    capstone: {
      enabled: true,
      maxBonus: 0.5, // +0.5× Heat at ratioForMax
      ratioForMax: 0.5, // Capstone value ÷ LP value
      earnsEmissions: false,
      depositFeePct: 1,
      withdrawFeePct: 1,
      cooldown: 'sameAsWithdraw',
      affectsStreak: false,
      affectsHeatAge: false,
    },
    autoStoke: {
      enabled: true,
      // Keepers are OPT-IN per position. Open stoking pays bots to skim 1% of
      // every position's yield on cheap-gas chains, front-running the owner's
      // own free stoke. By default only the owner stokes.
      defaultOn: false,
      tip: { minPct: 0.1, defaultPct: 0.5, maxPct: 1 }, // of the compounded yield, to the keeper
      minInterval: { minHours: 24, defaultHours: 168 }, // never more often than daily
      minSize: '100', // EMBER — dust stokes aren't worth a keeper's gas
    },
    casting: {
      enabled: true,
      lpSharePct: 25, // a quarter of every emission becomes permanent-ish liquidity
      quoteSource: 'matchReserve',
      fallback: 'liquidEmber', // reserve dry → liquid EMBER; never market-sell
      autoStake: true,
      castLot: 'sourceLot',
      entersAs: 'sourceLotAge',
      // review fix §4.3: single-token pool positions receive liquid EMBER for the cast share
      singleTokenFallback: 'liquidEmber' as const,
    },
    pyre: {
      enabled: true,
      tiers: [
        { key: 'cinder', name: 'Cinder', burnEmber: '250', heatBoost: 0.05, art: 'pyre-cinder.svg' },
        { key: 'wildfire', name: 'Wildfire', burnEmber: '1250', heatBoost: 0.05, art: 'pyre-wildfire.svg' },
        { key: 'conflagration', name: 'Conflagration', burnEmber: '6250', heatBoost: 0.05, art: 'pyre-conflagration.svg' },
      ],
      maxBoost: 0.15, // = sum of tier boosts; well under half the time ramp
      soulbound: true,
    },
    convictionTracks: {
      enabled: true,
      tracks: [
        { days: 30, bonus: 0.15, name: 'Ember' },
        { days: 90, bonus: 0.25, name: 'Forge' },
        { days: 180, bonus: 0.35, name: 'Kiln' },
        { days: 365, bonus: 0.5, name: 'Eternal' },
      ],
      vestAtTermEnd: true, // bonus accrues daily, pays out only at term end; early exit forfeits the unvested part
      // Per-position bucket cap: no sealed position collects more than
      // sealBonus × its heat-pool earnings in an epoch; the rest flows back
      // into the Heat pool. The 4.15× ceiling binds.
      bucketCap: {
        enabled: true,
        capToSealBonusOfHeatShare: true,
        unallocatedFlowsTo: 'heatPool',
      },
      // True escrow, FIXED budget: the bonus accrues daily INTO ESCROW from the
      // 10% Conviction bucket (ordinary share stays claimable). totalBaseMint
      // is fixed before weights are evaluated — the bonus is carved from the
      // epoch, never added to it. Term end pays the escrow into the Capstone —
      // the bonus never sells.
      escrow: { enabled: true, payout: 'capstone' },
      // Forfeited escrow routing: 50% burn lane, 25% match reserve, 25% Sealed
      // pot streamed to positions still inside their term. Principal is never
      // touched — only the bonus is at stake.
      forfeitRouting: { burnPct: 50, matchReservePct: 25, sealedPotPct: 25 },
      // Keystone, dual ownership: the WALLET earns a soulbound Keystone Relic
      // (proof the PERSON completed the term — never transfers); the DEED
      // gets a Seal Scar in its permanent metadata (proof the CAPITAL
      // completed one — always travels with the Deed). Both exist; the old
      // "stays with seller" vs "travels with Deed" contradiction is resolved
      // by not forcing one concept to do both jobs.
      keystone: {
        walletRelic: { enabled: true, key: 'keystone', soulbound: true },
        deedScar: { enabled: true },
      },
    },
    // Deeds: every position is an NFT, tradable on the in-dapp Deed Market.
    // The buyer gets LP + Capstone + escrow/term + unclaimed rewards and 80%
    // of the Heat age; Streak resets, badges stay with the seller. The LP
    // never leaves the pool — selling a Deed is an exit with no sell pressure.
    deeds: {
      enabled: true,
      heatCarryPct: 80, // earned time is always worth more than bought time
      marketFeePct: 1, // into the Vent on every sale
      feeRouting: { burnPct: 50, liquidityPct: 50 },
      marketOnlyTransfers: true, // no OTC, no gifts — the token refuses them
      blockListingWithPending: true, // no listing with a pending Withdraw/Claim
      // 24h ascending auction at a seller-set reserve — no instant sales. The
      // only INSTANT exit is the 8% emergency route; this is the fast exit.
      // Anti-sniping: bids in the final 5 minutes extend 5 minutes, max 30 total.
      saleMode: 'auction',
      auctionHours: 24,
      antiSnipe: { windowMinutes: 5, extensionMinutes: 5, maxTotalExtensionMinutes: 30 },
    },
    // Referrals: 3% of the referee's emission share is redirected (not minted)
    // to the referrer while the referee holds Spark and the referrer holds
    // Flame. Zero-sum — self-referral gains nothing. Off until the timelock
    // decides the protocol wants recruiters.
    referrals: {
      enabled: false,
      sharePct: 3,
      refereeMinRelic: 'spark',
      referrerMinRelic: 'flame',
    },
    // 4.15 = 3.0 Heat (365d) + 0.5 Capstone + 0.15 Pyre + 0.5 track.
    // Validated against the computed sum — conviction can never outweigh
    // staying by more than the config allows.
    caps: { maxTotalMultiplier: 4.15 },
    relics: [
      { key: 'spark', days: 7, heatBump: 0.1, perks: { claimCooldownSeconds: 72_000 }, art: 'spark.svg' },
      { key: 'flame', days: 30, heatBump: 0.1, perks: { claimCooldownSeconds: 57_600, ashfallEligible: true }, art: 'flame.svg' },
      { key: 'blaze', days: 90, heatBump: 0.1, perks: { tap: { maxPct: 10, everyDays: 90 } }, art: 'blaze.svg' },
      { key: 'inferno', days: 180, heatBump: 0.1, perks: { claimCooldownSeconds: 43_200, kindlingPriority: true }, art: 'inferno.svg' },
      { key: 'eternal', days: 365, heatBump: 0.1, perks: { tap: { maxPct: 25, everyDays: 90 }, governanceWeight: 2, feeRebatePct: 25 }, art: 'eternal.svg' },
      // Bedrock: no Heat bump — the ramp caps at a year. The second year pays
      // in perks: faster Taps, 3× governance, half the protocol's swap fee back.
      { key: 'bedrock', days: 730, heatBump: 0, perks: { tap: { maxPct: 25, everyDays: 60 }, governanceWeight: 3, feeRebatePct: 50 }, art: 'bedrock.svg' },
    ],
    badges: {
      standard: { evm: 'erc721-locked', svm: 'metaplex-core-frozen' },
      metadata: 'onchain-svg',
      revokeOnReset: false, // badge stays; perks go dormant
    },
    withdrawResetsStreak: true,
    cancelReturnsAsFreshLot: false, // review fix §4.2: aligns with cooldowns.withdraw.onCancelOrLapse: 'resumeFrozen'
    emergencyExit: {
      enabled: true,
      feePct: 8,
      routing: { burnPct: 50, liquidityPct: 25, stakersPct: 25 },
      forfeitsAshfall: true, // deserters feed the loyal: pending Ashfall rolls over
    },
    minStakeLp: '0.0001',
    pools: [
      { id: 'ember-usdc-lp', name: 'Blast Furnace', stakeToken: 'EMBER/USDC', stakeKind: 'lp', allocPoints: 1000, ashAllocPoints: 500, withdrawCooldownHours: 72 },
      { id: 'ember-weth-lp', name: 'Smelter', stakeToken: 'EMBER/WETH', stakeKind: 'lp', allocPoints: 400, ashAllocPoints: 200, withdrawCooldownHours: 72 },
      { id: 'ember-single', name: 'Ember Vault', stakeToken: 'EMBER', stakeKind: 'single', allocPoints: 400, ashAllocPoints: 300, withdrawCooldownHours: 72 },
      { id: 'usdc-single', name: 'Cold Storage', stakeToken: 'USDC', stakeKind: 'single', allocPoints: 200, ashAllocPoints: 0, withdrawCooldownHours: 72 },
    ],
  },

  cooldowns: {
    withdraw: {
      seconds: 259_200, // top tier — the whole position. Smaller exits cool faster.
      tiers: [
        { maxWithdrawPct: 10, seconds: 21_600 }, // 6h
        { maxWithdrawPct: 25, seconds: 43_200 }, // 12h
        { maxWithdrawPct: 50, seconds: 86_400 }, // 24h
        { maxWithdrawPct: 75, seconds: 172_800 }, // 48h
        { maxWithdrawPct: 100, seconds: 259_200 }, // 72h — covers a weekend dump
      ],
      executionWindowSeconds: 86_400, // 24h to click the green button, then it lapses
      earnsWhileCooling: false,
      // Lapse/cancel → resume frozen Heat. The cooling interval didn't age;
      // only execution cools proportionally and resets Streak.
      onCancelOrLapse: 'resumeFrozen',
    },
    claim: { seconds: 86_400, snapshotAtRequest: true }, // 24h; relic perks shorten it
    compound: { seconds: 0 }, // instant, free, no timer — the only door with no lock
  },

  emissions: {
    controllerChain: 'ethereum',
    epochSeconds: 86_400,
    split: { flatPct: 30, heatPct: 70 }, // 30% flat by stake = newcomer floor
    base: {
      startPerDay: '21600', // 0.25/s network-wide
      shape: 'halfLife',
      halfLifeDays: 365,
      floorPerDay: '1000', // TARGET — the live-supply ceiling decides what actually mints
    },
    // LIVE-supply ceiling: mint = min(targetEmission, 21M − totalSupply).
    // Burns reopen headroom, so the 1,000/day tail continues only while the
    // deflation engine creates room. Late-stage emissions are structurally
    // dependent on burns — the protocol must earn its tail.
    supplyCeiling: { hardCap: '21000000', mode: 'liveSupply' },
    // 10% of each epoch's FIXED mint is the Conviction bucket. Distribution,
    // never issuance — totalBaseMint is fixed before weights are evaluated.
    //
    // review fix §6 — unambiguous additive-bonus allocator:
    //   E = epoch budget; K = 10%*E; L = 70%*90%*E; F = 30%*90%*E
    //   S = Σ(s); W = Σ(s*h); V = Σ(s*h*b)
    //   candidate_i = K * s_i*h_i*b_i / V
    //   cap_i       = L * s_i*b_i / W    (additive: bonus earns b/h fraction extra)
    //   escrow_i    = min(candidate_i, cap_i)
    //   returned    = K - Σ(escrow_i)  → back into the Heat pool that epoch
    //   ordinary_i  = F*s_i/S + (L+returned)*s_i*h_i/W
    // When no positions are sealed, returned=K; effective split is 27%/73%,
    // not the nominal 30/70. The split field describes the pre-bucket base.
    convictionBucketPct: 10,
    ashfall: {
      enabled: true,
      // Source-specific recycle rates: protocol burns fund stayers at 50%,
      // registered Pyre burns at 25%, unsolicited dead-address transfers at
      // 0% — raw dead-address transfers earn no Ashfall recycle.
      // At Pyre 25%, a holder with eligible fraction p can still recapture 0.25*p*burn.
      // The rate reduces self-recapture; it does not eliminate it. (review §8)
      recycleRates: { protocolBurns: 50, pyreBurns: 25, unsolicited: 0 },
      lagEpochs: 1,
      minRelic: 'flame', // 30 days
      distributionWeight: 'heatSquared', // stake × Heat² — whales at 30d can't siphon it
      rolloverUndistributed: true,
      sources: ['forgeFees', 'swapFees', 'emergencyExit', 'manualBurns'],
    },
    gauge: {
      enabled: false, // phase 1 uses fixedEmissionSharePct; gauge is the upgrade
      weight: 'heatWeightedStake',
      reportIntervalSeconds: 86_400,
      maxCreditPerEpochPct: 60,
    },
  },

  fees: {
    // The Vent: every Forge fee split. Must sum to 100.
    vent: { burnPct: 40, liquidityPct: 40, hearthPct: 10, treasuryPct: 10 },
    genesisDeposit: { treasuryPct: 100 }, // 3% Ignition fee — straight to treasury
    burnLane: {
      method: 'unwindAndBuyback', // LP unwound; EMBER half burned, quote half buys EMBER and burns it
      twapSeconds: 1_800,
      maxPriceImpactBps: 300, // 3% — worse than this and the burn defers
      allowlistedRoutersOnly: true,
      deferIfUnsafe: true,
      maxDeferralHours: 72,
      // Four-way buy protection: spot within 2% of the 30-min average, max 1%
      // slippage vs that average, no buy above 0.5% of the quote reserve, and
      // fail-closed — unsafe means the quote asset waits in the fee vault.
      avgPriceBandBps: 200,
      slippageCapBps: 100,
      maxChunkPctOfReserve: 0.5,
    },
    // The fee vault: fees never hit the pool as they arrive. A permissionless
    // vent() processes the vault past $5k, and at least once a day regardless.
    feeVault: {
      enabled: true,
      minBatchUsd: 5_000,
      maxWaitHours: 24,
    },
    liquidityLane: {
      method: 'matchReserve', // fee LP unwound; EMBER half burned, quote half held to pair with Stokes
      // review fix §4.4: explicit ownership.
      // Cast LP (user's 25% share) → source lot (user-owned, withdrawable).
      // Match reserve LP (protocol's paired quote) → permanently burned (burnMatchedLp).
      matchReserve: { idleEpochsBeforeAutoPair: 7, burnMatchedLp: true },
      // Permanently burned liquidity is full-range only — a burned
      // concentrated position could drift out of range with no one able to
      // rebalance it. The protocol AMM is full-range CPMM, so this holds.
      permanentMustBeFullRange: true,
    },
    tokenFees: { burnPct: 100 }, // Capstone in/out are paid in EMBER — fully burned
    swap: {
      // Asymmetric: leavers pay more than arrivers. Buys 25bps, sells 35bps —
      // the sell-side surcharge funds the burn, the reserve and quote yield.
      buy: {
        totalBps: 25, // 0.25% to buy EMBER
        lpBps: 20, // stays in the pool for LPs
        burnBps: 2.5,
        liquidityBps: 2.5,
        treasuryBps: 0,
      },
      sell: {
        totalBps: 35, // 0.35% to sell EMBER
        lpBps: 20, // stays in the pool for LPs
        burnBps: 5,
        liquidityBps: 5,
        quoteYieldBps: 5, // real yield: quote asset to loyal stakers (see fees.quoteYield)
        treasuryBps: 0,
      },
      waiveProtocolShareOnCompound: true,
    },
    quoteYield: {
      enabled: true,
      eligibility: 'ashfallEligible', // same loyal set as Ashfall: relic perk flag
      asset: 'quoteAsset', // paid in ETH/WETH/BNB/SOL…, never in EMBER
    },
    burnAddress: { evm: DEAD, svm: '1nc1nerator11111111111111111111111111111111' },
  },

  swap: {
    amm: 'protocol-cpmm',
    listLpAsAsset: true,
    tokenListOrder: ['EMBER', 'LP', 'ASH', 'WETH', 'USDC', 'WBTC'], // 'LP' = protocol pair per chain
    zap: { defaultSlippageBps: 50, maxSlippageBps: 300, stakeAfterZap: 'offer' },
    showPriceImpact: true,
    showLpPrice: true,
    showTwentyFourHourChange: true,
  },

  treasury: {
    // UNSET by design. The previous values were decorative placeholders that looked
    // real: the EVM one failed EIP-55; the Solana one decodes to 32 bytes but was
    // hand-typed, so no one holds its key. Every genesis fee would have been lost.
    // Set EVM entries to the Safe deployed from deployment.evm.treasurySafe (the
    // deploy script must assert equality) and Solana to the Squads vault PDA.
    addresses: {
      ethereum: '0x0000000000000000000000000000000000000000',
      bsc: '0x0000000000000000000000000000000000000000',
      base: '0x0000000000000000000000000000000000000000',
      arbitrum: '0x0000000000000000000000000000000000000000',
      solana: '',
    },
    controller: { type: 'safe-multisig', threshold: 2, signers: [] },
    timelockSeconds: 172_800,
    policy: {
      polSeedingPct: 30,
      matchReserveSeedPct: 30, // seeds the Stoke-matching reserve from Ignition fees
      incentivesPct: 20,
      buybackPct: 20,
      reportOnChain: true,
    },
  },

  security: {
    feeCeilings: { depositPct: 5, withdrawPct: 5, genesisPct: 5, emergencyPct: 10, swapBps: 100, deedSalePct: 5 },
    paramTimelockSeconds: 172_800,
    pausable: { deposits: true, swaps: true, withdrawalsNever: true },
    upgradeable: { core: false, periphery: true },
    guardian: {
      // One entry per enabled chain. An EVM guardian may be the same Safe on every EVM chain.
      ethereum: '0x0000000000000000000000000000000000000000',
      bsc: '0x0000000000000000000000000000000000000000',
      base: '0x0000000000000000000000000000000000000000',
      arbitrum: '0x0000000000000000000000000000000000000000',
      solana: '',
    },
    audits: [],
    bugBountyUrl: 'https://immunefi.com/bounty/furnace',
  },

  ui: {
    timeline: {
      show: true,
      showRelicMarkers: true,
      showNextBumpCountdown: true,
      showHeatVsStreakNote: true,
      pendingWithdrawAsRedSegment: true,
      horizonDays: 365,
    },
    countdown: { style: 'ring', showInNav: true, browserNotification: true },
    readyButtonColor: '#22c55e', // the only green in the app
    positionCard: { showImpermanentLoss: true },
    locale: 'en-US',
    numberFormat: { compact: true, aprDecimals: 1 },
    charts: { emissionCurve: true, heatCurve: true, supplyChart: true },
  },

  // Fissures: satellite-chain launches as smaller Kindlings. Loyalists get
  // first ACCESS (priority window), never a head start — Heat, Streak and
  // badges are chain-local and never bridge.
  fissures: {
    enabled: true,
    defaultAllocation: '250000', // EMBER bridged from the Treasury per satellite launch
    priorityWindowHours: 24, // Inferno+ holders get the first 24h to themselves
    priorityMinRelic: 'inferno',
    feePct: 3, // same as genesis
    lpSplit: { stakersPct: 90, burnPct: 10 }, // 10% burned into the pool as floor
  },

  // Governance: the timelock runs launch; a vote takes over later. Four things
  // are out of reach of every vote, forever — not even governance can turn
  // the fee router into an extraction machine.
  governance: {
    model: 'timelock-then-two-chambers',
    chambers: {
      // ASH holders govern Hearth/ASH/fee-routing matters.
      hearth: { electorate: 'ASH holders', scope: 'Hearth, ASH, fee routing' },
      // Stakers govern Forge/staking/cooldown matters.
      forge: { electorate: 'liquidity × Heat', scope: 'Forge, staking, cooldowns' },
    },
    // Both chambers must agree: Treasury policy, new chains, Flow fee bands,
    // emission curves, new contracts. Neither side governs alone.
    dualChamberRequired: [
      'treasuryPolicy',
      'newChains',
      'flowFeeBands',
      'emissionCurves',
      'newContracts',
    ],
    relicVoteMultiplier: { eternal: 2, bedrock: 3 },
    // Above both chambers. No vote can authorize these. Ever.
    neverAllowed: ['mintOutsideMantle', 'pauseWithdrawals', 'touchUserBalances', 'redirectVent'],
  },
} satisfies FurnaceConfig;

export type Config = typeof furnaceConfig;
export default furnaceConfig;

// ─── Derived helpers (pure; safe to import anywhere) ────────────────────────

// ─── Address integrity helpers (review §3, §7) ──────────────────────────────
// Keccak via @noble/hashes (zero-dependency, independently audited). Never
// hand-roll hashing in a deploy config.

const _hexToBytes = (hex: string): Uint8Array => {
  const h = hex.startsWith('0x') ? hex.slice(2) : hex;
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return out;
};
const _bytesToHex = (b: Uint8Array): string => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
const _concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};

/** EIP-55 checksum form of a 20-byte hex address. */
export function toChecksumAddress(addr: string): EvmAddress {
  const lower = addr.slice(2).toLowerCase();
  const hash = _bytesToHex(keccak_256(new TextEncoder().encode(lower)));
  let out = '0x';
  for (let i = 0; i < 40; i++) out += parseInt(hash[i], 16) >= 8 ? lower[i].toUpperCase() : lower[i];
  return out as EvmAddress;
}

/**
 * True if `addr` is a well-formed 20-byte EVM address whose case is either
 * uniform (no checksum information) or a VALID EIP-55 checksum. A mixed-case
 * address with a bad checksum is almost always a typo or a corrupted paste —
 * this is the check that would have caught the truncated Uniswap router.
 */
export function isValidEvmAddress(addr: string): boolean {
  if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) return false;
  const body = addr.slice(2);
  if (body === body.toLowerCase() || body === body.toUpperCase()) return true;
  return toChecksumAddress(addr) === addr;
}

const _B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
/** Decode base58 (Bitcoin alphabet). Returns null on any invalid character. */
export function base58Decode(s: string): Uint8Array | null {
  if (!s) return null;
  let n = 0n;
  for (const ch of s) {
    const v = _B58.indexOf(ch);
    if (v < 0) return null;
    n = n * 58n + BigInt(v);
  }
  const bytes: number[] = [];
  while (n > 0n) { bytes.unshift(Number(n & 0xffn)); n >>= 8n; }
  for (const ch of s) { if (ch === '1') bytes.unshift(0); else break; }
  return new Uint8Array(bytes);
}

/**
 * A Solana public key / program ID must decode to EXACTLY 32 bytes. A string
 * made of base58 characters alone proves nothing (review §7).
 */
export function isValidSolanaPubkey(s: string): boolean {
  const b = base58Decode(s);
  return b !== null && b.length === 32;
}

/** keccak256(0x67363d3d37363d34f03d5260086018f3) — CreateX's CREATE3 proxy init code. */
const CREATEX_PROXY_INITCODE_HASH = '21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f';

/**
 * Derive the CreateX CREATE3 address for a sender-guarded salt with no
 * cross-chain redeploy protection (byte 21 = 0x00), exactly as CreateX does:
 *   guarded = keccak256(pad32(sender) ++ salt)
 *   proxy   = last20(keccak256(0xff ++ factory ++ guarded ++ proxyInitCodeHash))
 *   addr    = last20(keccak256(0xd6 ++ 0x94 ++ proxy ++ 0x01))
 * The address depends only on factory + sender + salt — never on bytecode.
 */
export function create3Address(salt: string, sender: EvmAddress, factory: EvmAddress = CREATEX_FACTORY): EvmAddress {
  const pad32 = _concat(new Uint8Array(12), _hexToBytes(sender));
  const guarded = keccak_256(_concat(pad32, _hexToBytes(salt)));
  const proxyHash = keccak_256(_concat(
    new Uint8Array([0xff]), _hexToBytes(factory), guarded, _hexToBytes(CREATEX_PROXY_INITCODE_HASH),
  ));
  const proxy = proxyHash.slice(12);
  const addrHash = keccak_256(_concat(new Uint8Array([0xd6, 0x94]), proxy, new Uint8Array([0x01])));
  return ('0x' + _bytesToHex(addrHash.slice(12))) as EvmAddress;
}

/** One position in an epoch cohort. `sealBonus` is 0 for unsealed positions. */
export interface CohortPosition { stake: number; heat: number; sealBonus: number }

/**
 * REFERENCE ORACLE for one complete epoch, including the Conviction bucket
 * (review §6, additive-bonus interpretation). For tests and UI previews —
 * contracts must use integer math with explicit, unallocated residuals and
 * bounded (non-looping) accrual.
 *
 *   E = epoch budget; K = bucket% × E; rest = E − K
 *   F = flat% × rest; L = heat% × rest
 *   S = Σs; W = Σ(s·h); V = Σ(s·h·b)
 *   candidate_i = K · s·h·b / V
 *   cap_i       = L · s·b / W        ← additive: +b multiplier units, never b × earnings
 *   escrow_i    = min(candidate_i, cap_i)
 *   returned    = K − Σescrow       → back into the Heat pool, same epoch
 *   ordinary_i  = F·s/S + (L + returned)·s·h/W
 *
 * Conservation: Σordinary + Σescrow = E exactly (up to float error).
 * With nobody sealed, the effective split is (flat × (1−bucket)) / rest:
 * 27% raw / 73% Heat at the FURNACE parameters — not 30/70.
 */
export function epochAllocation(
  epochBudget: number,
  positions: readonly CohortPosition[],
  e: EmissionsConfig = furnaceConfig.emissions,
): { ordinary: number[]; escrow: number[]; returned: number } {
  if (!(epochBudget >= 0) || !Number.isFinite(epochBudget)) throw new RangeError('epochBudget must be finite and ≥ 0');
  for (const p of positions) {
    if (!(p.stake >= 0) || !(p.heat >= 0) || !(p.sealBonus >= 0) || ![p.stake, p.heat, p.sealBonus].every(Number.isFinite)) {
      throw new RangeError('cohort stake, heat and sealBonus must be finite and ≥ 0');
    }
  }
  const K = (e.convictionBucketPct / 100) * epochBudget;
  const rest = epochBudget - K;
  const F = (e.split.flatPct / 100) * rest;
  const L = (e.split.heatPct / 100) * rest;
  const S = positions.reduce((a, p) => a + p.stake, 0);
  const W = positions.reduce((a, p) => a + p.stake * p.heat, 0);
  const V = positions.reduce((a, p) => a + p.stake * p.heat * p.sealBonus, 0);
  const escrow = positions.map((p) => {
    if (V <= 0 || W <= 0 || p.sealBonus <= 0) return 0;
    const candidate = (K * p.stake * p.heat * p.sealBonus) / V;
    const cap = (L * p.stake * p.sealBonus) / W;
    return Math.min(candidate, cap);
  });
  const returned = K - escrow.reduce((a, x) => a + x, 0);
  const ordinary = positions.map((p) =>
    (S > 0 ? (F * p.stake) / S : 0) + (W > 0 ? ((L + returned) * p.stake * p.heat) / W : 0));
  return { ordinary, escrow, returned };
}

/** Heat multiplier for a position of `ageDays`, including relic bumps. */
export function heatMultiplier(ageDays: number, c: ForgeConfig = furnaceConfig.forge): number {
  const { startMultiplier, rampBonus, rampDays, shape } = c.heat;
  const x = Math.min(Math.max(ageDays, 0), rampDays) / rampDays;
  const ramp = shape === 'sqrt' ? Math.sqrt(x) : shape === 'quadratic' ? x * x : x;
  return startMultiplier + rampBonus * ramp + milestoneBump(ageDays, c);
}

/**
 * Milestone bumps belong to the LOT'S AGE, not to badges — computed from the
 * lot's Heat age against the milestone schedule, prorated linearly between
 * milestones so no withdrawal ever falls off a cliff. A 365-day lot sits at
 * 3.0× (2.5× curve + 0.5× bumps); a 135-day lot carries +0.35×. Cooling,
 * Deed transfer, and wallet reset all follow from this one rule: the bumps
 * cool with the age, transfer with the inherited age, and never attach to
 * new money until that money ages.
 */
export function milestoneBump(ageDays: number, c: ForgeConfig = furnaceConfig.forge): number {
  const milestones = c.relics
    .filter((r) => r.heatBump > 0)
    .map((r) => ({ days: r.days, bump: r.heatBump }))
    .sort((a, b) => a.days - b.days);
  let total = 0;
  let prevDays = 0;
  for (const m of milestones) {
    if (ageDays >= m.days) {
      total += m.bump;
      prevDays = m.days;
    } else {
      total += m.bump * ((Math.max(ageDays, 0) - prevDays) / (m.days - prevDays));
      break;
    }
  }
  return total;
}

/**
 * Proportional cooling, defined per lot. Executing a withdrawal of fraction
 * `f` (0–1) of a position removes f of every lot's LP AND scales every
 * remaining lot's age by (1 − f). Ages are capped at the Heat ramp BEFORE
 * scaling, so banked age past the curve can't absorb a withdrawal: a
 * two-year lot that withdraws 50% lands at 182.5 days, exactly like a
 * one-year lot. Taps are the exception — they draw the youngest lots first
 * and cool nothing.
 */
export function cooledAgeAfterWithdrawal(ageDays: number, withdrawFraction: number, c: ForgeConfig = furnaceConfig.forge): number {
  const capped = Math.min(Math.max(ageDays, 0), c.heat.rampDays);
  const f = Math.min(Math.max(withdrawFraction, 0), 1);
  return capped * (1 - f);
}

/** Extra Heat from a Capstone worth `capstoneValue` beside LP worth `lpValue`. */
export function capstoneBonus(capstoneValue: number, lpValue: number, c: ForgeConfig = furnaceConfig.forge): number {
  if (!c.capstone.enabled || lpValue <= 0) return 0;
  const ratio = Math.min(capstoneValue / lpValue, c.capstone.ratioForMax);
  return c.capstone.maxBonus * (ratio / c.capstone.ratioForMax);
}

/**
 * Permanent account-wide Heat boost from `burnedEmber` EMBER fed to the Pyre.
 * Soulbound tiers; capped at maxBoost. Add to heatMultiplier() — it is not
 * age-derived, so it lives outside the age curve by design.
 */
export function pyreBoost(burnedEmber: number, c: ForgeConfig = furnaceConfig.forge): number {
  if (!c.pyre.enabled) return 0;
  const earned = c.pyre.tiers
    .filter((t) => burnedEmber >= Number(t.burnEmber))
    .reduce((acc, t) => acc + t.heatBoost, 0);
  return Math.min(earned, c.pyre.maxBoost);
}

/**
 * Split of one emission payout into liquid EMBER and LP-cast portions.
 * `reserveQuoteValue` is the match reserve's holdings measured in EMBER value
 * at pool price. The cast share is capped by what pairs cleanly — the
 * uncovered remainder stays liquid. The protocol never market-sells here.
 */
export function castEmissionSplit(
  emission: number,
  reserveQuoteValue: number,
  c: ForgeConfig = furnaceConfig.forge,
): { liquid: number; cast: number } {
  if (!c.casting.enabled || c.casting.lpSharePct <= 0) return { liquid: emission, cast: 0 };
  const want = emission * (c.casting.lpSharePct / 100);
  const cast = Math.max(0, Math.min(want, Math.max(0, reserveQuoteValue)));
  return { liquid: emission - cast, cast };
}

/**
 * Heat age after withdrawing `fraction` (0..1) of the LP.
 * Review fix §4.1: delegates to cooledAgeAfterWithdrawal — cap-first policy.
 * The old reset branch is removed; validator now requires 'proportional'.
 */
export function heatAgeAfterWithdrawal(ageDays: number, fraction: number, c: ForgeConfig = furnaceConfig.forge): number {
  return cooledAgeAfterWithdrawal(ageDays, fraction, c);
}

/** Blended Heat age after topping up: stake-weighted average (dust-aging is dead). */
export function heatAgeAfterDeposit(oldAge: number, oldStake: number, newStake: number): number {
  const total = oldStake + newStake;
  if (total <= 0) return 0;
  return (oldAge * oldStake) / total; // new money enters at age 0
}

/**
 * A position's share of the ORDINARY (pre-Conviction-bucket) 30/70 split.
 * `totalStake` / `totalWeighted` are the pool-wide sums of stake and stake × multiplier.
 * This is not the complete epoch — the 10% bucket and its return to the Heat pool
 * are modelled by epochAllocation(). (review §6)
 */
export function rewardShare(
  stake: number,
  multiplier: number,
  totalStake: number,
  totalWeighted: number,
  e: EmissionsConfig = furnaceConfig.emissions,
): number {
  const flat = totalStake > 0 ? (e.split.flatPct / 100) * (stake / totalStake) : 0;
  const heat = totalWeighted > 0 ? (e.split.heatPct / 100) * ((stake * multiplier) / totalWeighted) : 0;
  return flat + heat;
}

/** Base emission per day at `day` after pool open. */
export function baseEmissionPerDay(day: number, e: EmissionsConfig = furnaceConfig.emissions): number {
  const start = Number(e.base.startPerDay);
  const floor = Number(e.base.floorPerDay);
  if (e.base.shape === 'halfLife') return Math.max(floor, start * Math.pow(2, -day / e.base.halfLifeDays));
  if (e.base.shape === 'linear') return Math.max(floor, start * (1 - day / (e.base.halfLifeDays * 2)));
  return Math.max(floor, start / Math.pow(2, Math.floor(day / e.base.halfLifeDays)));
}

/**
 * The live-supply ceiling, executable. What actually mints in an epoch is
 * the TARGET emission capped by remaining headroom under 21M:
 *   mint = min(targetEmission, max(0, 21M − totalSupply)).
 * Burns reduce totalSupply and reopen headroom — the 1,000/day tail is a
 * target the protocol must earn through deflation, not a promise the cap
 * must break for. When headroom < target, all recipients scale down pro-rata.
 */
export function mintForEpoch(targetEmission: number, totalSupply: number, e: EmissionsConfig = furnaceConfig.emissions): number {
  if (![targetEmission, totalSupply].every((x) => Number.isFinite(x) && x >= 0)) {
    throw new RangeError('mintForEpoch: inputs must be finite and ≥ 0');
  }
  const headroom = Math.max(0, Number(e.supplyCeiling.hardCap) - totalSupply);
  return Math.min(targetEmission, headroom);
}

/**
 * Ashfall is a mint, so it shares the epoch's headroom check with base
 * emission. ONE budget: base target + Ashfall target scale down PRO-RATA
 * when headroom is short. Ashfall can never push supply past 21M on its own.
 */
export function totalMintForEpoch(
  baseTarget: number,
  ashfallTarget: number,
  totalSupply: number,
  e: EmissionsConfig = furnaceConfig.emissions,
): { base: number; ashfall: number } {
  // review §8: negative targets let one bucket borrow from the other (−100 base, 200 ashfall).
  // Production math must also take totalSupply from an authenticated GLOBAL ledger that
  // counts in-flight OFT transfers — bridging never reopens issuance headroom.
  if (![baseTarget, ashfallTarget, totalSupply].every((x) => Number.isFinite(x) && x >= 0)) {
    throw new RangeError('totalMintForEpoch: inputs must be finite and ≥ 0');
  }
  const headroom = Math.max(0, Number(e.supplyCeiling.hardCap) - totalSupply);
  const total = baseTarget + ashfallTarget;
  if (total <= headroom) return { base: baseTarget, ashfall: ashfallTarget };
  const scale = total > 0 ? headroom / total : 0;
  return { base: baseTarget * scale, ashfall: ashfallTarget * scale };
}

/** Claim cooldown for a position at `streakDays`, honouring relic perks. */
export function claimCooldownSeconds(streakDays: number, c: FurnaceConfig = furnaceConfig): number {
  let seconds: number = c.cooldowns.claim.seconds;
  for (const r of c.forge.relics) {
    if (streakDays >= r.days && r.perks.claimCooldownSeconds) seconds = Math.min(seconds, r.perks.claimCooldownSeconds);
  }
  return seconds;
}

/**
 * Withdrawal cooldown for exiting `withdrawPct` (0–100) of a position.
 * Progressive: small exits cool fast, whale exits face the full timer.
 */
export function withdrawCooldownSeconds(withdrawPct: number, c: FurnaceConfig = furnaceConfig): number {
  const tiers = c.cooldowns.withdraw.tiers;
  const pct = Math.min(Math.max(withdrawPct, 0), 100);
  for (const t of tiers) {
    if (pct <= t.maxWithdrawPct) return t.seconds;
  }
  return c.cooldowns.withdraw.seconds;
}

/** Conviction-track bonus for a `trackDays` track, or 0 if no such track. */
export function convictionBonus(trackDays: number, c: ForgeConfig = furnaceConfig.forge): number {
  if (!c.convictionTracks.enabled) return 0;
  return c.convictionTracks.tracks.find((t) => t.days === trackDays)?.bonus ?? 0;
}

/**
 * Ignition reward weight for a deposit at `elapsedHours` into the phase.
 * Early-bird bonus decays from +maxBonusPct to zero across the window —
 * urgency without a first-block landgrab. Multiplies the pro-rata share.
 */
export function ignitionWeight(elapsedHours: number, c: IgnitionConfig = furnaceConfig.ignition): number {
  if (!c.earlyBird.enabled) return 1;
  const t = Math.min(Math.max(elapsedHours, 0), c.durationHours) / c.durationHours;
  const decay = c.earlyBird.shape === 'exponential' ? (1 - t) * (1 - t) : 1 - t;
  return 1 + (c.earlyBird.maxBonusPct / 100) * decay;
}

/**
 * Heat age the BUYER of a Deed inherits. The seller's Streak resets to 0 and
 * badges stay with the seller; only a haircut share of the age moves.
 */
/**
 * Financial Heat age the Deed buyer inherits.
 * Review fix §4.1: age is capped at rampDays BEFORE the carry haircut.
 * deedHeatAge(730) was returning 584; correct is min(730,365)*0.80 = 292.
 * Streak is always chronological and is never capped; buyer's Streak resets to 0.
 */
export function deedHeatAge(sellerAgeDays: number, c: ForgeConfig = furnaceConfig.forge): number {
  if (!c.deeds.enabled) return 0;
  const financialAge = Math.min(Math.max(0, sellerAgeDays), c.heat.rampDays);
  return financialAge * (c.deeds.heatCarryPct / 100);
}

/**
 * The validated ceiling on the total multiplier any position can ever reach:
 * Heat at the ramp cap + Capstone max + Pyre max + best track bonus.
 * check:config asserts this equals forge.caps.maxTotalMultiplier.
 */
export function maxTotalMultiplier(c: ForgeConfig = furnaceConfig.forge): number {
  const trackBest = Math.max(0, ...c.convictionTracks.tracks.map((t) => t.bonus));
  return heatMultiplier(c.heat.rampDays, c) + c.capstone.maxBonus + c.pyre.maxBoost + trackBest;
}

/** Build-time sanity checks; `pnpm check:config` calls this. */
export function validateConfig(c: FurnaceConfig = furnaceConfig): string[] {
  const errors: string[] = [];
  const f = c.fees;
  const vent = f.vent;
  if (vent.burnPct + vent.liquidityPct + vent.hearthPct + vent.treasuryPct !== 100) errors.push('fees.vent must sum to 100');
  // Asymmetric swap fee: each side must sum to its own total.
  const buy = f.swap.buy;
  if (buy.lpBps + buy.burnBps + buy.liquidityBps + buy.treasuryBps !== buy.totalBps) {
    errors.push('fees.swap.buy parts must sum to buy.totalBps');
  }
  const sell = f.swap.sell;
  if (sell.lpBps + sell.burnBps + sell.liquidityBps + sell.quoteYieldBps + sell.treasuryBps !== sell.totalBps) {
    errors.push('fees.swap.sell parts must sum to sell.totalBps');
  }
  if (sell.totalBps < buy.totalBps) errors.push('fees.swap: sells must cost at least as much as buys (leavers pay more)');
  if (sell.totalBps > c.security.feeCeilings.swapBps) errors.push('fees.swap.sell above ceiling');
  if (buy.totalBps > c.security.feeCeilings.swapBps) errors.push('fees.swap.buy above ceiling');
  const bl = f.burnLane;
  if (bl.twapSeconds <= 0) errors.push('burnLane.twapSeconds must be positive');
  if (bl.twapSeconds < 1_800) errors.push('burnLane.twapSeconds must be at least 30 minutes');
  if (bl.maxPriceImpactBps < 0 || bl.maxPriceImpactBps > 10_000) errors.push('burnLane.maxPriceImpactBps out of range');
  if (bl.slippageCapBps <= 0 || bl.slippageCapBps > 100) {
    errors.push('burnLane.slippageCapBps must be between 0 and 100 (1%)');
  }
  if (bl.avgPriceBandBps <= 0) errors.push('burnLane.avgPriceBandBps must be positive');
  if (bl.maxChunkPctOfReserve <= 0 || bl.maxChunkPctOfReserve > 100) {
    errors.push('burnLane.maxChunkPctOfReserve must be between 0 and 100');
  }
  if (bl.maxDeferralHours <= 0) errors.push('burnLane.maxDeferralHours must be positive');
  // The fee vault: batched, permissionless processing.
  if (f.feeVault.enabled) {
    if (f.feeVault.minBatchUsd <= 0) errors.push('feeVault.minBatchUsd must be positive');
    if (f.feeVault.maxWaitHours <= 0) errors.push('feeVault.maxWaitHours must be positive');
  }
  // AutoStoke: keepers are opt-in per position. An open default pays bots to
  // skim every position's yield on cheap-gas chains.
  const as = c.forge.autoStoke;
  if (as.enabled) {
    if (as.defaultOn) errors.push('autoStoke.defaultOn must be false — keepers are opt-in per position');
    if (!(as.tip.minPct > 0) || as.tip.defaultPct < as.tip.minPct || as.tip.maxPct < as.tip.defaultPct) {
      errors.push('autoStoke.tip must satisfy 0 < min <= default <= max');
    }
    if (as.tip.maxPct > 1) errors.push('autoStoke.tip.maxPct must not exceed 1%');
    if (as.minInterval.minHours < 24) errors.push('autoStoke.minInterval.minHours must be at least 24');
    if (as.minInterval.defaultHours < as.minInterval.minHours) {
      errors.push('autoStoke.minInterval.defaultHours must be >= minHours');
    }
    if (!(Number(as.minSize) > 0)) errors.push('autoStoke.minSize must be positive');
  }
  // (Salt structure — bytes32, deployer guard, 0x00 flag, prefix match — is
  // checked in the deterministic deployment guards below.)
  if (f.quoteYield.enabled && f.swap.sell.quoteYieldBps <= 0) errors.push('quoteYield enabled but sell.quoteYieldBps is 0');
  const wtiers = c.cooldowns.withdraw.tiers;
  if (!wtiers.length) errors.push('withdraw cooldown needs at least one tier');
  if (wtiers.some((t, i) => i > 0 && t.maxWithdrawPct <= wtiers[i - 1].maxWithdrawPct)) {
    errors.push('withdraw cooldown tiers must ascend by maxWithdrawPct');
  }
  if (wtiers.some((t, i) => i > 0 && t.seconds < wtiers[i - 1].seconds)) {
    errors.push('withdraw cooldown tiers must not shorten as size grows');
  }
  if (wtiers[wtiers.length - 1]?.maxWithdrawPct !== 100) errors.push('last withdraw tier must cover 100%');
  if (wtiers[wtiers.length - 1]?.seconds !== c.cooldowns.withdraw.seconds) {
    errors.push('last withdraw tier seconds must equal cooldowns.withdraw.seconds (the max)');
  }
  const ctracks = c.forge.convictionTracks;
  if (ctracks.enabled) {
    if (ctracks.tracks.some((t, i) => i > 0 && t.days <= ctracks.tracks[i - 1].days)) {
      errors.push('conviction tracks must ascend by days');
    }
    if (ctracks.tracks.some((t) => t.bonus <= 0)) errors.push('conviction track bonus must be positive');
    if (ctracks.tracks.some((t) => t.bonus > c.forge.heat.rampBonus / 2)) {
      errors.push('conviction track bonus must stay below half the ramp bonus, or declaring outweighs staying');
    }
    const fr = ctracks.forfeitRouting;
    if (fr.burnPct + fr.matchReservePct + fr.sealedPotPct !== 100) {
      errors.push('conviction forfeitRouting must sum to 100');
    }
  }
  // Global multiplier cap: the validated ceiling on everything conviction can buy.
  {
    const computed =
      heatMultiplier(c.forge.heat.rampDays, c.forge) +
      c.forge.capstone.maxBonus +
      c.forge.pyre.maxBoost +
      Math.max(0, ...c.forge.convictionTracks.tracks.map((t) => t.bonus));
    if (Math.abs(computed - c.forge.caps.maxTotalMultiplier) > 1e-9) {
      errors.push(
        `forge.caps.maxTotalMultiplier (${c.forge.caps.maxTotalMultiplier}) must equal the computed sum of caps (${computed})`,
      );
    }
  }
  // Deeds: earned time must stay worth more than bought time.
  const deeds = c.forge.deeds;
  if (deeds.enabled) {
    if (deeds.heatCarryPct <= 0 || deeds.heatCarryPct >= 100) {
      errors.push('deeds.heatCarryPct must be strictly between 0 and 100');
    }
    if (deeds.marketFeePct > c.security.feeCeilings.deedSalePct) errors.push('deed market fee above ceiling');
    if (deeds.feeRouting.burnPct + deeds.feeRouting.liquidityPct !== 100) {
      errors.push('deeds.feeRouting must sum to 100');
    }
    if (deeds.auctionHours <= 0) errors.push('deeds.auctionHours must be positive');
  }
  // Referrals: zero-sum by construction; validate the gates when enabled.
  // Disabled by default — an enabled-by-default referral program is a hidden
  // emission vector the timelock never approved.
  const refs = c.forge.referrals;
  if (refs.enabled) errors.push('forge.referrals must be disabled by default — enable via timelock only');
  if (refs.enabled) {
    if (refs.sharePct <= 0 || refs.sharePct >= 100) errors.push('referrals.sharePct must be between 0 and 100');
    const relicKeys = new Set(c.forge.relics.map((r) => r.key));
    if (!relicKeys.has(refs.refereeMinRelic)) errors.push('referrals.refereeMinRelic is not a known relic');
    if (!relicKeys.has(refs.referrerMinRelic)) errors.push('referrals.referrerMinRelic is not a known relic');
  }
  // Deposit accounting: per-lot. Weighted-average is the pre-v5.1 design.
  if (c.forge.heat.depositDilution !== 'perLot') errors.push("forge.heat.depositDilution must be 'perLot'");
  // Emission curve: 21,600/day, 365-day half-life. These are the audited numbers.
  if (c.emissions.base.startPerDay !== '21600') errors.push("emissions.base.startPerDay must be '21600'");
  if (c.emissions.base.halfLifeDays !== 365) errors.push('emissions.base.halfLifeDays must be 365');
  // Casting: exactly 25% of emissions become LP.
  if (c.forge.casting.lpSharePct !== 25) errors.push('forge.casting.lpSharePct must be 25');
  // Execution window: 24h. Longer windows are stale-price windows.
  if (c.cooldowns.withdraw.executionWindowSeconds !== 86_400) {
    errors.push('cooldowns.withdraw.executionWindowSeconds must be 86_400 (24h)');
  }
  // Vent split: exactly 40 burn / 40 liquidity / 10 Hearth / 10 Treasury.
  const v = c.fees.vent;
  if (v.burnPct !== 40 || v.liquidityPct !== 40 || v.hearthPct !== 10 || v.treasuryPct !== 10) {
    errors.push('fees.vent must be exactly 40/40/10/10 (burn/liquidity/hearth/treasury)');
  }
  // EMBER genesis allocations must fit under the cap with room to spare —
  // the curve needs headroom from day one.
  const genesisMint =
    Number(c.token.allocations.kindlingPool) +
    Number(c.token.allocations.treasury.amount) +
    Number(c.token.allocations.team.amount);
  if (genesisMint >= Number(c.token.maxSupply)) {
    errors.push(`genesis allocations (${genesisMint}) must be well under maxSupply`);
  }
  // Fissures: satellite launches with loyalist priority.
  const fis = c.fissures;
  if (fis.enabled) {
    if (!(Number(fis.defaultAllocation) > 0)) errors.push('fissures.defaultAllocation must be positive');
    if (fis.feePct > c.security.feeCeilings.genesisPct) errors.push('fissures.feePct above genesis ceiling');
    if (fis.lpSplit.stakersPct + fis.lpSplit.burnPct !== 100) errors.push('fissures.lpSplit must sum to 100');
    if (!c.forge.relics.some((r) => r.key === fis.priorityMinRelic)) {
      errors.push('fissures.priorityMinRelic is not a known relic');
    }
  }
  // Vanity charset: an EVM prefix must be pure hex, a Solana prefix pure
  // base58 — a grinder searching for an impossible prefix runs forever.
  for (const [name, entry] of Object.entries(c.deployment.evm.contracts)) {
    const prefix = (entry as { prefix: string }).prefix;
    if (!/^[0-9a-fA-F]+$/.test(prefix)) {
      errors.push(`evm contract ${name}: prefix '${prefix}' is not valid hex`);
    }
  }
  // (Solana has no vanity prefixes in config yet — IDs are ground keypairs.
  // When vanity grinding lands, their prefixes get the base58 check here.)
  for (const r of c.forge.relics) {
    if (r.perks.feeRebatePct !== undefined && (r.perks.feeRebatePct < 0 || r.perks.feeRebatePct > 100)) {
      errors.push(`relic ${r.key}: feeRebatePct out of range`);
    }
  }
  if (c.ignition.depositFeePct !== 3) errors.push('ignition deposit fee must be exactly 3');
  if (c.ignition.depositFeePct > c.security.feeCeilings.genesisPct) errors.push('ignition fee above ceiling');
  // One genesis fee: the 3% applies to Ignition, Kindling, and every Fissure.
  if (c.kindling.depositFeePct !== 3) errors.push('kindling deposit fee must be exactly 3');
  if (c.kindling.feeDestination !== 'treasury') errors.push('kindling fee must go straight to the treasury');
  if (c.ignition.withdrawDuringWindow.enabled !== true) errors.push('ignition must allow withdrawal during the window — nothing is ever locked');
  if (c.ignition.withdrawDuringWindow.refundFee !== false) errors.push('ignition withdrawal must not refund the genesis fee');
  if (c.ignition.principalAtClose.usdc !== 'autoStakeColdStorage') errors.push('ignition USDC principal must auto-stake into Cold Storage at close');
  if (c.ignition.principalAtClose.otherAssets !== 'claimableFeeFree') errors.push('ignition non-USDC principal must be claimable fee-free at close');
  // Casting follows provenance: into the lot that earned it, never a rolling lot.
  if (c.forge.casting.castLot !== 'sourceLot') errors.push('casting must stake back into the lot that earned it');
  if (c.forge.casting.entersAs !== 'sourceLotAge') errors.push('cast LP must enter at the earning lot\'s age');
  // Conviction bucket per-position cap: the 4.15× ceiling must bind.
  if (c.forge.convictionTracks.bucketCap.enabled !== true) errors.push('conviction bucketCap must be enabled');
  if (c.forge.convictionTracks.bucketCap.unallocatedFlowsTo !== 'heatPool') errors.push('unallocated conviction bucket must flow back to the Heat pool');
  if (c.forge.fees.depositPct !== 1) errors.push('post-genesis deposit fee must be exactly 1');
  if (c.forge.fees.depositPct > c.security.feeCeilings.depositPct) errors.push('deposit fee above ceiling');
  if (c.forge.fees.withdrawPct !== 1) errors.push('withdraw fee must be exactly 1');
  if (c.forge.fees.withdrawPct > c.security.feeCeilings.withdrawPct) errors.push('withdraw fee above ceiling');
  if (c.forge.fees.compoundPct !== 0) errors.push('compound must be free');
  if (c.cooldowns.compound.seconds !== 0) errors.push('compound must be instant');
  // Early-bird: a bounded, decaying bonus — never a landgrab.
  if (c.ignition.earlyBird.enabled) {
    if (c.ignition.earlyBird.maxBonusPct < 0 || c.ignition.earlyBird.maxBonusPct > 100) {
      errors.push('ignition.earlyBird.maxBonusPct must be 0–100');
    }
  }
  if (c.fees.genesisDeposit.treasuryPct !== 100) errors.push('genesis deposit fee must go to the treasury');
  const r = c.forge.emergencyExit.routing;
  if (r.burnPct + r.liquidityPct + r.stakersPct !== 100) errors.push('emergencyExit.routing must sum to 100');
  if (c.emissions.split.flatPct + c.emissions.split.heatPct !== 100) errors.push('emissions.split must sum to 100');
  // Supply ceiling: the live-supply invariant. hardCap must equal the token
  // maxSupply — two numbers for one cap is how caps get quietly raised.
  if (c.emissions.supplyCeiling.hardCap !== c.token.maxSupply) {
    errors.push('emissions.supplyCeiling.hardCap must equal token.maxSupply');
  }
  if (c.emissions.supplyCeiling.mode !== 'liveSupply') errors.push('supply ceiling must be live-supply mode');
  // Conviction bucket: a distribution carve-out, 0–100.
  if (c.emissions.convictionBucketPct < 0 || c.emissions.convictionBucketPct > 100) {
    errors.push('emissions.convictionBucketPct must be 0–100');
  }
  // Ashfall recycle rates: each source 0–100.
  for (const [src, rate] of Object.entries(c.emissions.ashfall.recycleRates)) {
    if (rate < 0 || rate > 100) errors.push(`ashfall.recycleRates.${src} must be 0–100`);
  }
  // ASH conservation: recursively sum EVERY leaf of the allocation tree and
  // require exactly the 70k cap. This is what catches the next "just one
  // more bonus pool" — the 71k bug can never recur.
  const ashLeaves: number[] = [];
  const collectAsh = (node: unknown): void => {
    if (typeof node === 'string') ashLeaves.push(Number(node));
    else if (node && typeof node === 'object') Object.values(node).forEach(collectAsh);
  };
  collectAsh(c.shareToken.allocations);
  const ashTotal = ashLeaves.reduce((a, b) => a + b, 0);
  if (ashTotal !== Number(c.shareToken.maxSupply)) {
    errors.push(`ASH allocations sum to ${ashTotal}, must equal maxSupply ${c.shareToken.maxSupply}`);
  }
  // Ignition rewards must equal the Ignition leaf of the ASH tree — one number,
  // two places is how the 42k/41k drift happens.
  if (c.ignition.rewards.total !== c.shareToken.allocations.launch.ignition) {
    errors.push('ignition.rewards.total must equal shareToken.allocations.launch.ignition');
  }
  // Kindling bonus pool must equal the Kindling leaf.
  if (c.kindling.ashBonusPool !== c.shareToken.allocations.launch.kindling) {
    errors.push('kindling.ashBonusPool must equal shareToken.allocations.launch.kindling');
  }
  // Kindling LP split must sum to 100.
  if (c.kindling.lpSplit.depositorDeedsPct + c.kindling.lpSplit.burnPct !== 100) {
    errors.push('kindling.lpSplit must sum to 100');
  }
  // Anti-sniping sanity: extension can't exceed the total cap.
  const sn = c.forge.deeds.antiSnipe;
  if (sn.windowMinutes <= 0 || sn.extensionMinutes <= 0 || sn.maxTotalExtensionMinutes < sn.extensionMinutes) {
    errors.push('deeds.antiSnipe timings are inconsistent');
  }
  const tp = c.treasury.policy;
  if (tp.polSeedingPct + tp.matchReserveSeedPct + tp.incentivesPct + tp.buybackPct !== 100) errors.push('treasury.policy must sum to 100');
  if (c.forge.capstone.enabled && (c.forge.capstone.maxBonus <= 0 || c.forge.capstone.ratioForMax <= 0)) {
    errors.push('capstone bonus and ratio must be positive');
  }
  if (c.forge.capstone.maxBonus > c.forge.heat.rampBonus / 2) {
    errors.push('capstone bonus must stay below half the ramp bonus, or conviction outweighs time');
  }
  if (c.fees.liquidityLane.method === 'matchReserve' && !c.fees.liquidityLane.matchReserve) {
    errors.push('matchReserve settings missing');
  }
  if (c.fees.tokenFees.burnPct < 0 || c.fees.tokenFees.burnPct > 100) errors.push('tokenFees.burnPct out of range');
  // (autoStoke tip/interval/size/defaultOn validated above)
  const casting = c.forge.casting;
  if (casting.enabled) {
    if (casting.lpSharePct < 0 || casting.lpSharePct > 50) errors.push('casting.lpSharePct must be 0–50; more starves liquid rewards');
    if (c.fees.liquidityLane.method !== 'matchReserve') errors.push('casting needs liquidityLane.method "matchReserve" for its quote side');
  }
  const pyre = c.forge.pyre;
  if (pyre.enabled) {
    const burns = pyre.tiers.map((t) => Number(t.burnEmber));
    if (burns.some((b) => !(b > 0))) errors.push('pyre tier burnEmber must be positive');
    if (burns.some((b, i) => i > 0 && b <= burns[i - 1])) errors.push('pyre tiers must ascend by burnEmber');
    if (pyre.tiers.some((t) => t.heatBoost <= 0)) errors.push('pyre tier heatBoost must be positive');
    const sumBoost = pyre.tiers.reduce((a, t) => a + t.heatBoost, 0);
    if (Math.abs(sumBoost - pyre.maxBoost) > 1e-9) errors.push('pyre.maxBoost must equal the sum of tier boosts');
    if (pyre.maxBoost > c.forge.heat.rampBonus / 2) errors.push('pyre maxBoost must stay below half the ramp bonus, or burning outweighs time');
  }
  const enabled = c.chains.filter((ch) => ch.enabled);
  if (!c.emissions.gauge.enabled && enabled.reduce((a, ch) => a + ch.fixedEmissionSharePct, 0) !== 100) {
    errors.push('fixedEmissionSharePct of enabled chains must sum to 100');
  }
  if (enabled.filter((ch) => ch.role === 'home').length !== 1) errors.push('exactly one enabled home chain');
  if (!c.forge.relics.some((x) => x.key === c.emissions.ashfall.minRelic)) errors.push('ashfall.minRelic must be a relic key');
  const days = c.forge.relics.map((x) => x.days);
  if (days.some((d, i) => i > 0 && d <= days[i - 1])) errors.push('relics must be in ascending days');
  // ── review §7: 28 previously undetected mutations now caught ──────────────
  if (c.forge.fees.claimPct !== 0) errors.push('forge.fees.claimPct must be exactly 0');
  if (c.forge.emergencyExit.feePct !== 8) errors.push('forge.emergencyExit.feePct must be exactly 8');
  if (c.forge.heat.withdrawCooling !== 'proportional') errors.push('forge.heat.withdrawCooling must be \'proportional\'');
  if (!c.forge.heat.compoundInheritsAge) errors.push('forge.heat.compoundInheritsAge must be true');
  if (Number(c.emissions.base.floorPerDay) !== 1000) errors.push('emissions.base.floorPerDay must be exactly 1000');
  if (c.emissions.base.shape !== 'halfLife') errors.push('emissions.base.shape must be \'halfLife\'');
  if (c.emissions.split.flatPct !== 30 || c.emissions.split.heatPct !== 70)
    errors.push('emissions.split must be exactly 30/70');
  if (c.emissions.convictionBucketPct !== 10) errors.push('emissions.convictionBucketPct must be exactly 10');
  const _expTiers: Array<[number,number]> = [[10,21600],[25,43200],[50,86400],[75,172800],[100,259200]];
  for (const [pct,secs] of _expTiers) {
    const t = c.cooldowns.withdraw.tiers.find(t => t.maxWithdrawPct === pct);
    if (!t || t.seconds !== secs) errors.push(`cooldown tier ${pct}% must be ${secs}s`);
  }
  if ((c.fees.burnLane as any).maxChunkPctOfReserve > 0.5)
    errors.push('burnLane.maxChunkPctOfReserve must not exceed 0.5');
  if (!(c.fees.burnLane as any).allowlistedRoutersOnly)
    errors.push('burnLane.allowlistedRoutersOnly must be true');
  if (!(c.fees.burnLane as any).deferIfUnsafe)
    errors.push('burnLane.deferIfUnsafe must be true');
  if (c.kindling.lpSplit.burnPct !== 10 || c.kindling.lpSplit.depositorDeedsPct !== 90)
    errors.push('kindling.lpSplit must be exactly 90/10');
  if (!c.kindling.atomicPoolInit) errors.push('kindling.atomicPoolInit must be true');
  if (c.fissures.feePct !== 3) errors.push('fissures.feePct must be exactly 3');
  if (c.forge.cancelReturnsAsFreshLot !== false)
    errors.push('forge.cancelReturnsAsFreshLot must be false (resumeFrozen policy)');
  // ── review §7, pass 2: remaining identity + integrity checks ─────────────
  // Non-finite numbers anywhere in the config (NaN slips past every `>` check).
  const _walk = (v: unknown, path: string, visit: (v: unknown, p: string) => void): void => {
    visit(v, path);
    if (Array.isArray(v)) v.forEach((x, i) => _walk(x, `${path}[${i}]`, visit));
    else if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) _walk(x, path ? `${path}.${k}` : k, visit);
  };
  _walk(c, '', (v, p) => {
    if (typeof v === 'number' && !Number.isFinite(v)) errors.push(`${p} is not a finite number (${v})`);
    if (typeof v === 'string' && /^0x[0-9a-fA-F]+$/.test(v)) {
      const n = v.length - 2;
      if (n >= 36 && n <= 44 && n !== 40) errors.push(`${p} looks like a malformed EVM address (${n / 2} bytes): ${v}`);
      if (n === 40 && !isValidEvmAddress(v)) errors.push(`${p} fails its EIP-55 checksum — likely a typo: ${v}`);
    }
  });
  // Burn-lane identity numbers
  if (c.fees.burnLane.avgPriceBandBps !== 200) errors.push('burnLane.avgPriceBandBps must be exactly 200 (2%)');
  if (!Number.isFinite(c.fees.burnLane.slippageCapBps)) errors.push('burnLane.slippageCapBps must be finite');
  // Supply identity: raising a cap and its promises together is still a new protocol
  if (c.token.maxSupply !== '21000000') errors.push('token.maxSupply must be exactly 21000000');
  if (c.emissions.supplyCeiling.hardCap !== '21000000') errors.push('emissions.supplyCeiling.hardCap must be exactly 21000000');
  if (c.token.allocations.kindlingPool !== '420000') errors.push('token.allocations.kindlingPool must be exactly 420000');
  if (c.shareToken.maxSupply !== '70000') errors.push('shareToken.maxSupply must be exactly 70000');
  const _al = c.shareToken.allocations;
  if (_al.launch.ignition !== '41000' || _al.launch.kindling !== '1000' || _al.forge !== '28000') {
    errors.push('shareToken allocation leaves must be exactly 41000 / 1000 / 28000');
  }
  // Heat curve identity
  if (c.forge.heat.shape !== 'sqrt') errors.push('forge.heat.shape must be \'sqrt\'');
  if (c.forge.heat.rampDays !== 365 || c.forge.heat.rampBonus !== 1.5 || c.forge.heat.startMultiplier !== 1.0) {
    errors.push('forge.heat must be 1.0 start + 1.5 ramp over 365 days');
  }
  // Clocks
  if (c.cooldowns.withdraw.onCancelOrLapse !== 'resumeFrozen') errors.push('cooldowns.withdraw.onCancelOrLapse must be \'resumeFrozen\'');
  if (c.cooldowns.withdraw.executionWindowSeconds !== 86_400) errors.push('withdraw execution window must be exactly 24h');
  // Deed market rules that keep Deeds honest
  const _d = c.forge.deeds;
  if (_d.marketOnlyTransfers !== true) errors.push('deeds.marketOnlyTransfers must be true — every sale pays the Vent');
  if (_d.blockListingWithPending !== true) errors.push('deeds.blockListingWithPending must be true');
  if (_d.saleMode !== 'auction' || _d.auctionHours !== 24) errors.push('deeds must sell by 24-hour auction');
  if (_d.antiSnipe.windowMinutes !== 5 || _d.antiSnipe.extensionMinutes !== 5 || _d.antiSnipe.maxTotalExtensionMinutes !== 30) {
    errors.push('deeds.antiSnipe must be 5 / 5 / 30 minutes');
  }
  if (_d.heatCarryPct !== 80) errors.push('deeds.heatCarryPct must be exactly 80');
  if (_d.marketFeePct !== 1) errors.push('deeds.marketFeePct must be exactly 1');
  // CREATE3 registry: salts must be real bytes32 hex and DERIVE to the claimed address
  for (const [name, a] of Object.entries(c.deployment.evm.contracts)) {
    if (!a.salt || !a.address) continue; // unmined — reported above
    if (!/^0x[0-9a-fA-F]{64}$/.test(a.salt)) { errors.push(`deployment.evm.contracts.${name}: salt is not 32 bytes of hex`); continue; }
    const derived = create3Address(a.salt, c.deployment.evm.deployer, c.deployment.evm.factory);
    if (derived.toLowerCase() !== a.address.toLowerCase()) {
      errors.push(`deployment.evm.contracts.${name}: address ${a.address} does not derive from its salt (expected ${derived})`);
    }
  }
  // External routers, VM-aware (EVM hex ≠ Solana base58)
  for (const ch of c.chains) {
    const router = ch.externalDex?.router;
    if (!router) continue;
    const ok = ch.vm === 'svm' ? isValidSolanaPubkey(router) : isValidEvmAddress(router);
    if (!ok) errors.push(`${ch.key}: externalDex.router is not a valid ${ch.vm.toUpperCase()} address: ${router}`);
  }

  // CHAIN_VM cross-check
  for (const ch of c.chains) {
    if (CHAIN_VM[ch.key] !== ch.vm) errors.push(`CHAIN_VM mismatch for ${ch.key}`);
  }
  // deterministic deployment guards
  const dep = c.deployment.evm;
  if (/^0x1+$/i.test(dep.deployer)) errors.push('deployment.evm.deployer is still the placeholder');
  if (dep.treasurySafe.saltNonce === null) errors.push('deployment.evm.treasurySafe.saltNonce is not set');
  // Treasury Safe: threshold without signers is a vault nobody can open.
  const tc = c.treasury.controller;
  if (tc.signers.length === 0) errors.push('treasury.controller.signers is empty — set the Safe owners before deploy');
  if (tc.threshold < 1 || tc.threshold > tc.signers.length) {
    errors.push('treasury.controller.threshold must be 1..signers.length');
  }
  // Treasury: every enabled chain needs a real, VM-valid destination for genesis fees.
  for (const ch of c.chains.filter((x) => x.enabled)) {
    const t = c.treasury.addresses[ch.key];
    if (!t || /^0x0+$/i.test(t)) { errors.push(`treasury.addresses.${ch.key} is unset — set the deployed Safe / Squads vault`); continue; }
    const ok = ch.vm === 'svm' ? isValidSolanaPubkey(t) : isValidEvmAddress(t);
    if (!ok) errors.push(`treasury.addresses.${ch.key} is not a valid ${ch.vm.toUpperCase()} address`);
  }
  // Guardians: every ENABLED chain needs one, in its own VM's encoding (review §7).
  // Iterating only the entries that exist missed chains with no entry at all.
  for (const ch of c.chains.filter((x) => x.enabled)) {
    const g = c.security.guardian[ch.key];
    if (!g || /^0x0+$/i.test(g)) { errors.push(`security.guardian.${ch.key} is zero/empty — set a real guardian`); continue; }
    const ok = ch.vm === 'svm' ? isValidSolanaPubkey(g) : isValidEvmAddress(g);
    if (!ok) errors.push(`security.guardian.${ch.key} is not a valid ${ch.vm.toUpperCase()} address`);
  }
  // LayerZero DVNs: requiredDvnCount: 2 with empty dvns is a bridge secured
  // by nothing. Every chain must list at least requiredDvnCount DVNs.
  for (const ch of c.chains) {
    if (ch.lz.dvns.length < ch.lz.requiredDvnCount) {
      errors.push(`${ch.key}: dvns has ${ch.lz.dvns.length}, requiredDvnCount is ${ch.lz.requiredDvnCount}`);
    }
  }
  const deployerHex = dep.deployer.slice(2).toLowerCase();
  for (const [name, a] of Object.entries(dep.contracts)) {
    if (a.salt === null || a.address === null) {
      errors.push(`deployment.evm.contracts.${name}: salt and address must both be mined (run pnpm mine:salts)`);
      continue;
    }
    if (a.salt && a.salt.length !== 66) errors.push(`deployment.evm.contracts.${name}: salt must be bytes32`);
    if (a.salt && a.salt.slice(2, 42).toLowerCase() !== deployerHex) errors.push(`deployment.evm.contracts.${name}: salt not guarded to deployer`);
    if (a.salt && a.salt.slice(42, 44) !== '00') errors.push(`deployment.evm.contracts.${name}: salt byte 21 must be 0x00`);
    if (a.address && !a.address.slice(2).toUpperCase().startsWith(a.prefix.toUpperCase())) {
      errors.push(`deployment.evm.contracts.${name}: address does not start with its prefix`);
    }
  }
  for (const [name, a] of Object.entries(c.deployment.svm.contracts)) {
    if (!a.keypair) errors.push(`deployment.svm.contracts.${name}: keypair path missing`);
    if (a.address && !/^[1-9A-HJ-NP-Za-km-z]{32,50}$/.test(a.address)) {
      errors.push(`deployment.svm.contracts.${name}: address is not valid base58`);
    }
    if (a.address === null) errors.push(`deployment.svm.contracts.${name}: not ground — run \`pnpm gen:solana-ids\``);
  }
  for (const ch of c.chains) {
    if (ch.addressOverrides && Object.keys(ch.addressOverrides).length) {
      errors.push(`${ch.key}: addressOverrides set — deploy will stop and ask`);
    }
  }
  return errors;
}
