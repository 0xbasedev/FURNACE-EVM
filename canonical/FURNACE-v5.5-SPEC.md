# FURNACE - Canonical implementation specification, v5.5.0

**Status: selected design and executable configuration/reference accounting; not deployed or audited.**

**Full configuration-data hash:** `0x24f38f4aa11919503354bb5f8263978c7b3edc29723760928cb1eecdbafbe5ae`. See `results/manifest.json` for separate policy and source commitments.

This revision retains v5.4's monetary profile and core loyalty mechanics. It resolves remaining alternatives under the user's delegated design authority. `furnace.config.ts` is the canonical data source; `accounting.ts` defines the new fixed-point reference convention. `identity-rules.ts` is an independent acceptance specification, not an editable synonym for whichever values happen to be in the config. `results/manifest.json` commits separately to data and source files. Historical v5.4 inputs are preserved unchanged in `source-v5.4/`.

## 0. The idea and the limits of the claims

FURNACE pays for sustained participation, allows ordinary exits through disclosed click-start cooldowns, and represents a position as a tradable Deed. It has no additional fixed-term principal locks. Seals put unvested bonuses at risk, not principal. Emergency exits retain their disclosed fee.

Standard Forge deposit and withdrawal fees allocate 40% to burns, 40% to liquidity and matching, 10% to ASH stakers, and 10% to Treasury. Other actions have their own routes. There is no direct team allocation or team-fee destination. This is not a claim that a Treasury can never procure services or compensate contributors; any such spending must be separately disclosed.

Heat is a reward-allocation weight, not a promised return. Matching is a funded subsidy, not minted quote currency. Atomic execution avoids intermediate state exposure but does not eliminate MEV. Permanent LP means irretrievable redemption rights, not immunity to pool, token, or market failure.

## 1. Tokens and economic budgets

| Property | EMBER | ASH |
|---|---|---|
| Supply policy | 21,000,000 global live-supply ceiling | 70,000 cumulative economic issuance |
| Initial home chain | Ethereum | Ethereum |
| Standard | OFT-compatible token, transport initially inactive | OFT-compatible token, transport initially inactive |
| Decimals | EVM 18; planned SVM 9; shared 6 | EVM 18; planned SVM 9; shared 6 |
| Transfer tax | 0 | 0 |

EMBER allocations remain 420,000 Kindling seed, 500,000 Treasury vesting over 365 days, and zero team tokens. The base target remains 21,600 per day at open, a 365-day half-life, and a 1,000/day floor constrained by supply headroom. Daily epochs use the schedule value at epoch start; a production fixed-point schedule evaluator must match its pinned test vectors. The positive floor is a target, not an infinite unconditional mint promise.

ASH economic allocations are exactly 41,000 Ignition + 1,000 Kindling + 28,000 Forge. The Forge allocation vests over 730 days using cumulative integer entitlement, never a rounded daily payment authority:

`V(t) = floor(allocation * min(elapsed, duration) / duration)`.

A payout between checkpoints is `V(t1) - V(t0)`. A bridged ASH credit is transport, not another allocation. Neither a burn nor an unclaimed balance creates an additional ASH allocation.

The economic issuance authority is the home-chain Mantle. It reserves Genesis, vesting, base, and authorized burn-recycling budgets before minting. Satellite distributors receive funded budgets and have no independent economic mint authority. Economic burns reduce the global ledger only after unique authenticated recognition. Source transport debits do not lower the accounted global supply or create Ashfall credits.

`headroom = max(0, cap - globallyAccountedSupply - reservedEconomicIssuance)`.

Base and independently authorized Ashfall targets share this headroom pro-rata. Integer residuals stay unminted and tagged. The ledger must include outstanding transport claims, and late burn recognition may delay issuance rather than allow excess issuance. These are contract requirements, not claims that a local token's `totalSupply()` supplies a global proof.

## 2. Ignition

Ignition remains a 120-hour bootstrap farm. Configurable bounds remain 48 hours to 14 days for a separately reviewed event. USDC, WETH, WBTC, and a specifically bound WETH/USDC LP receipt have weights 100/100/100/150. The external LP address is intentionally unset until independently verified; a WETH address must never stand in for an LP receipt.

Ignition's 3% fee is paid to Treasury and is nonrefundable. Principal may leave throughout the phase. The 41,000-ASH reward allocation uses actual participating balances and participation time, with each deposit lot's fixed entry weight declining linearly from +10% to zero across the admission window. A common multiplier applied to everyone at a checkpoint is not an early-entry bonus. Withdrawn principal stops earning; return deposits obtain new entry times. Pool units are normalized explicitly by their adapter, never summed as raw USDC, WETH, and LP units.

At close, USDC may enter Cold Storage under the existing disclosed opt-out policy; other assets remain claimable without an additional exit fee. Ignition principal is not automatically spent in Kindling. Opting into Kindling is a new contribution with its own disclosed 3% fee. The 24-hour post-Ignition free exit window remains. A Kindling failure does not retroactively refund a separately earned Ignition fee.

First Flame remains a wallet-bound founder record with the existing 15-day financial-Heat floor. Phantom age is never actual participation time for Ashfall, Seal membership, or rebate eligibility. The finite head-start credit remains limited to retained contributing value and its seven-day claim window. It cannot be reused for multiple new deposits or sold as financial age through a Deed.

## 3. Kindling and refunds

Kindling opens after Ignition, lasts 24 hours, and accepts USDC on the home chain. Its seed is the single 420,000-EMBER allocation. Retain the $100,000 minimum, $5,000,000 maximum, $25,000 per-wallet admission cap, 3% fee, and 1,000-ASH bonus leaf. Wallet caps are admission rules, not a claim to prevent one entity using many wallets.

Kindling fees are held by a **dedicated immutable GenesisFeeEscrow** whose success beneficiary is Treasury. They are not spendable Safe balances. Each event and asset has a separate principal liability and fee liability. There is no rescue, arbitrary approval, upgrade, or administrative withdrawal path for live refund backing.

New deposits stop exactly at the deadline. Contributions can be cancelled until atomic successful settlement, including during a safe-settlement retry period. Cancellation returns net principal immediately; the fee remains escrowed. On success, the fee is earned by Treasury. On failure, any fee previously retained on a cancelled contribution is refundable, and a remaining contribution receives its remaining principal plus its fee. No refund pays previously returned principal again.

Below minimum at the deadline, the event fails. A funded event that cannot safely settle becomes refundable no later than 72 hours after its deadline. A valid success transition and failure transition are mutually exclusive. Passing time is not evidence of successful pool initialization. Treasury fallback seeding, if desired later, is a separately funded event and cannot repurpose refundable contributor assets.

Successful settlement performs pool initialization and LP custody atomically, then releases earned fees. The close bounty remains 5 bps of accepted gross quote, paid out of successful-event fee revenue, not added on top of user costs. Cancelled contributions do not enlarge its base. Call ordering and retry behavior must be adversarially tested.

After accounting separately for the AMM's minimum liquidity, 90% of distributable LP is allocated pro-rata to contributor-owned auto-staked Deeds; 10% goes to an irretrievable LP sink. The two destinations cannot own the same unit. Entitlements are initialized in aggregate and materialized in bounded pages or on demand; finalization never loops over every contributor.

A $100 gross contribution leaves $97 of net quote. A 90% contributor LP share corresponds approximately to $87.30 of quote-side reserves plus its token-side claim. Marking that token claim at the opening ratio produces a combined $174.60 LP mark before minimum-liquidity dilution. It is not a guaranteed cash exit, realized gain, or external valuation. The opening price is endogenous to net raised quote and the token seed.

## 4. Forge pools and fees

| Pool ID | Receipt asset | Base weight | ASH weight |
|---|---|---:|---:|
| ember-usdc-lp | EMBER/USDC full-range LP | 1000 | 500 |
| ember-weth-lp | EMBER/WETH full-range LP | 400 | 200 |
| ember-single | EMBER | 400 | 300 |
| usdc-single | USDC | 200 | 0 |

Pool weights split authorized pool budgets; raw units of different assets are never added into one staking denominator. Each pool has its own receipt identity, vault, and accumulator. The two LP pairs are separate contract identities, not two names for one `Pool` address. Single-token pools have no automatic conversion of their principal to LP. Cold Storage's lower reward scope does not make contract, token, or market risk disappear.

Standard fees remain 1% deposit and 1% executed withdrawal; Claim and owner Compound remain 0%. Authenticated same-route Flow LP formation retains its specified deposit-fee exemption. A public boolean cannot manufacture that exemption. Source exclusion for a waived fee means no burn credit is created for a fee not charged; new capital also cannot inherit immediate loyalty eligibility from an old dust position.

Max 32 live lots per position. Deposits create their own lot. Source-lot compounding and compatible Casting increase their existing source cohort and do not consume another timestamp slot. Equivalent financial states may share storage; averaging different timestamps is not an exact substitute under the nonlinear curve. At genuine capacity, open a separate Deed with consent or leave the reward claimable. Never erase historical settlement liabilities when a lot closes.

## 5. Deeds and auctions

A Deed holds a position's LP or single-asset receipt, Capstone, outstanding rewards, and eligible Seal state. A completed sale carries 80% of capped financial age; Streak resets for the new owner. Wallet Relics, Pyre, and First Flame do not transfer. Seal Scar metadata transfers with the position; the wallet Keystone requires continuous ownership for the whole completed term.

Keep 24-hour ascending auctions, a reserve price, no instant buyout, and the existing five-minute anti-sniping extension capped at 30 added minutes. A pending Claim or withdrawal blocks listing. Listing suspends seller mutations; changing or withdrawing collateral first cancels the listing. Seller cancellation remains possible before atomic settlement, with bid refunds recorded as pull claims. Bidders are told that a pre-settlement bid does not make the seller's commitment irrevocable. This preserves principal access rather than creating an auction-only custody trap.

Unclaimed position rewards travel with the Deed; the auction does not create a fee-free or timer-free Claim endpoint. The seller can complete normal Claim before listing. On settlement, price, receipt ownership, reward beneficiary, and financial-age haircut change exactly once. Recipient callbacks must not trap seller proceeds: use a buyer delivery claim or approved receiver mechanism with reentrancy protection. A failed callback cannot pay twice or return the same Deed to the seller.

Deed fee remains 1%, routed 50% burn / 50% liquidity. Transfer restrictions are contract-level restrictions; they do not prevent someone transferring control of a wallet that owns a Deed.

## 6. Capstone and Stoke

Capstone holds EMBER without its own base-emission stake weight. The bonus is at most +0.5 ordinary Heat at a held-value/LP-value ratio of 0.5. Its deposited and withdrawn fees remain 1%, burned; the existing withdrawal timer applies. Moving Capstone does not alter principal Streak or financial age. Eligible valuation must use the pool's protected valuation checkpoint, not an arbitrary caller price.

Stoke defaults to Capstone first, then compatible LP if a funded matching reservation exists. **Without a reservation, the default never sells:** rewards stay in Capstone or claimable. A selling zap is a separately authorized route with explicit owner consent, min-output, deadline, and the expected exposure shown. This is a selected change from the old automatic `zap` fallback, not a claim that v5.4 already behaved this way.

Only internally earned, unconsumed, source-identified reward receipts retain age. Tokens arriving from an external wallet are deposits. Closed source lots are not resurrected with old age; their earned rewards remain claimable without reopening the old multiplier.

## 7. Casting and the matching subsidy

Casting targets 25% of **ordinary base rewards after the Conviction allocation**, on compatible active LP lots. It returns to the source lot at that lot's age. Ember Vault and Cold Storage receive liquid EMBER instead. Ashfall, ASH, Quote yield, Conviction escrow, and Sealed-pot distributions are not automatically cast and do not obtain an additional base-reward matching entitlement.

All Cast/Stoke LP made with the user's reward receipt and reserve quote belongs to the user. The quote side is a disclosed subsidy. At a hypothetical 1:1 quote price, 100 ordinary reward tokens with a fully funded 25% Cast become 75 liquid tokens plus LP containing 25 tokens and 25 quote. The additional quote is reserve expense, not inflation or guaranteed realized return. The reward card displays emission amount, matched quote, and LP received separately.

Matching budgets are frozen per epoch, pool, and quote asset from unencumbered balances. Automatic Cast reservations have priority and are pro-rata to eligible ordinary-base reward demand. Optional Stoke can use only the remaining budget, also through source-bound entitlements rather than first-caller access. A reward unit receives at most one match. Claimed liquid rewards or externally redeposited tokens cannot reclaim its allowance. No new mint fills a dry quote reserve.

Reservations last seven epochs. Expiry releases only the unspent quote reservation; it never confiscates the user's reward. If the source is no longer compatible or active, the uncovered reward remains liquid. A stale oracle or failed safe execution releases no assets to the caller. Voluntary compounding remains immediately available into Capstone even when a match is unavailable.

Only the **idle auto-pair** path creates permanent LP: after seven idle epochs, unreserved quote can pair with already funded Treasury match-seed EMBER and the resulting LP becomes irretrievable. Never use reserved quote, principal, refundable fees, or unpaid rewards. If the Treasury seed is insufficient, idle pairing waits; it does not invent the token side or sell user rewards.

## 8. Pyre and loyalty eligibility

Keep cumulative burn thresholds 250 / 1,250 / 6,250 EMBER with +0.05 ordinary Heat each, capped at +0.15 wallet-wide. Registered burns must actually destroy economic token supply and create one typed burn receipt. Merely transferring to a nonzero dead address is not automatically an ERC20 supply burn. LP redemption and OFT transport burns are different operations.

Pyre recycling remains 25%, protocol-generated eligible burns 50%, unsolicited transfers 0. A burner holding fraction p of eligible weight may recapture approximately `0.25 * p * burn` from its own registered Pyre burn under otherwise unchanged weights. This is possible and disclosed, not advertised as eliminated.

Ashfall and Quote-yield participation require both the position's active qualifying Streak and the lot's actual 30-day participation age. Founder phantom age does not meet this test. Internally earned source-lot additions retain provenance; external top-ups start their own actual-participation clock. Buying a Deed resets active Streak, so acquired age is not instant access to every perk.

## 9. Heat, Relics and Taps

Financial age is capped at 365 days. Core Heat is `1 + 1.5*sqrt(age/365) + proratedMilestoneBump(age)`. The five +0.1 milestones at 7/30/90/180/365 days interpolate linearly between thresholds, total +0.5. Core Heat reaches 3.0; Capstone and Pyre bring the ordinary maximum to 3.65. Seal's +0.5 is a capped marginal allocation from a separate budget. A 4.15 nominal combined coefficient is not an APR or a ceiling on matching-subsidy value.

Streak is chronological, separate from financial age. Relics remain wallet history; current perks require active state rather than possession of an old NFT. Preserve Spark 20h Claim, Flame 16h Claim/Ashfall eligibility, Blaze 10% Tap every90d, Inferno 12h Claim/priority, Eternal25% Tap every90d/governance2x/protocol-fee rebate25%, and Bedrock25% Tap every60d/governance3x/protocol-fee rebate50%. Bedrock adds no further Heat.

Normal execution removes the specified pro-rata receipt fraction and scales each surviving lot's capped financial age by the surviving fraction. A two-year lot at 50% withdrawal lands at 182.5 financial days. Taps instead draw youngest lots first with no financial-age haircut or Streak reset. They still pay the normal withdrawal fee and timer and consume a fixed quota. A Tap during an active Seal forfeits its unvested bonus: a Streak exception is not a Seal exception.

## 10. Epoch accounting and Conviction

**New selected settlement convention:** use time-integrated per-position measures assembled from authoritative lot checkpoints. This is not a terminal snapshot and not the continuous integral of every instantaneous pool-share fraction. It removes that ambiguity by specifying a ratio of integrated measures per daily epoch.

For one pool and epoch, with stake s, ordinary Heat h, and eligible additive Seal bonus b:

```
S_i = integral(s_i dt)
W_i = integral(s_i * h_i dt)
B_i = integral(sealed s_i * b_i dt)
C_i = integral(sealed s_i * h_i * b_i dt)
S = sum(S_i); W = sum(W_i); C = sum(C_i)
```

Checkpoint whenever stake, ownership-derived boosts, eligibility, cooling, or Seal state changes. Exclude cooling slices. Count chronological actual participation separately from financial age. Group a Deed's lots before applying the per-position cap; a storage-page boundary cannot change its financial identity.

A pool checkpoints whether its participating principal is nonzero. The daily target accrues only across those occupied intervals; empty intervals stay unallocated, so the first late deposit cannot inherit a whole previously empty day. With the daily rate fixed at epoch start, the admitted budget is `floor(poolEpochTarget * occupiedSeconds / epochSeconds)`. Use the actually cap-authorized amount no larger than that admitted budget. For this already authorized base budget E, reserve `bucket=floor(E*10/100)`. Of the rest, `flat=floor((E-bucket)*30/100)` and `L=E-bucket-flat`. Candidate escrow is `floor(bucket*C_i/C)`; additive cap is `floor(L*B_i/W)`. Pay the smaller. Use zero when the corresponding denominator is zero. Return unused bucket to the Heat budget before ordinary payouts. Ordinary payout is `floor(flat*S_i/S)+floor(finalHeat*W_i/W)`. Any unpaid rounding residue remains tagged, never paid again or silently swept.

At constant stake and Heat, this reduces to v5.4's `cap_i=L*s_i*b_i/W`. With no eligible Seals it yields27/73. An empty pool retains its unused budget under the same epoch identifier; it does not select a later depositor as a retroactive recipient.

The age curve has an analytic antiderivative. In seconds with cap R, the integral of `1.5*sqrt(a/R)` is `a^(3/2)/sqrt(R)`. Integrate each linear bump segment as a trapezoid; past R, core Heat is constant. `accounting.ts` defines a single 1e27-scaled integer primitive; differences telescope under checkpoint subdivision. The reference uses BigInt and is not a proof of Solidity/Anchor overflow safety.

**Bounded onchain implementation:** append authoritative checkpoint state; freeze epoch eligibility; accumulate totals in deterministic pages of at most 32 lots; then finalize capped escrow totals in bounded pages and make per-position ordinary/reward claims available. No privileged offchain signer may choose the denominators. Total work still grows with population; gas, storage, and keeper liveness must be measured before mainnet. Archive exited lots and liabilities so principal withdrawal never depends on this process completing. The supplied complete-cohort function is a mathematical oracle, not a production loop.

Seals keep 30/90/180/365-day terms and +0.15/.25/.35/.50 marginal coefficients. Membership is fixed to the committed cohorts; later external deposits cannot join a nearly completed term. Requested cooling pauses Seal accrual and extends its uncompleted term by the paused duration without restricting principal. Cancellation restores valid paused state; actual early withdrawal forfeits only unvested escrow, routed50/25/25. A completed term pays funded escrow into Capstone. No second mint occurs at vesting. Seal Scar follows capital; wallet Keystone requires whole-term ownership.

## 11. Withdrawal, Claim and emergency state

Keep withdrawal tiers6/12/24/48/72h at 10/25/50/75/100% and a 24-hour execution window. There is no Eternal principal calendar lock.

A position uses a cooling plan with a frozen reference balance and cumulative requested quantity. Added requests cannot each pretend to be the first10%. Top-ups do not enlarge the current reference. Cancellation consumes that plan's request allowance; resetting a plan requires its 72-hour horizon and all tickets resolved. New tickets never delay matured tickets. Each individual ticket remains bounded by the ordinary 72-hour maximum. This is position-level anti-fragmentation, not wallet identity detection.

Only requested slices stop earning and stop gaining financial age. Cancellation or lapse resumes their frozen state, adjusted for any intervening executed age haircut; it cannot restore an obsolete pre-withdrawal age. Existing unrelated stake continues normally. The 1% fee and ordinary Streak reset occur on execution, with Taps as the stated exception. No pending ticket may be consumed twice.

Claim remains fee-free with a 24-hour click-start snapshot, reduced by active Relic perks. Rewards accruing after the snapshot are not silently added to a matured claim. Compounding consumes unclaimed source receipts; a simultaneously pending Claim cannot spend the same receipt.

Emergency exits charge 8%, route50%burn/25%liquidity/25%stayers, and forfeit pending Ashfall as specified. They do not require a successful swap or reward settlement. A direct in-kind receipt exit must remain available if routers, oracles, bridges, or reward calculations are unavailable. Underlying asset or chain failure may still prevent delivery; this is not an unconditional guarantee under all external failures.

## 12. Ashfall, Quote yield and the Sealed pot

Ashfall uses typed unique economic-burn receipts and the selected source rates, one-epoch lag, eligible active lot measures, and Heat-squared weighting. Burn credits are independently required in addition to spare mint headroom. Duplicate categories cannot credit the same burn twice. Cap-constrained unused authorized credits remain queued without a second authorization. Heat-squared is a per-unit loyalty advantage, not immunity to larger capital positions.

Ordinary Heat excludes the Seal coefficient for Ashfall and Quote yield. These programs have separate funded budgets and denominators; they never multiply base issuance. Heat-squared weights use the separately implemented canonical antiderivative in `accounting.ts`, not the square of average Heat. On each linear-bump interval, expand ordinary Heat squared into polynomial terms plus square-root cross terms and evaluate its fixed-point primitive. The EVM/Anchor differential port and its overflow bounds remain release requirements.

Quote yield is funded from the sell-side protocol share in the pool's actual quote asset. Nominal five bps is reduced by applicable protocol-fee rebates; display the effective amount. There is no cross-chain conversion or global fee-sharing promise at initial launch. The Sealed pot streams already forfeited escrow over its configured period to eligible ongoing Seals; it is not a new mint and receives no extra automatic Cast match.

## 13. Vent and permanent liquidity

Standard Forge fees follow 40/40/10/10; Deed fees1% follow 50/50; Capstone fees burn100%; emergency fees use their own schedule; Genesis follows section2 or3; swaps follow section14. Book liabilities at receipt, process safe conversions later. A failed burn conversion must not prevent principal exit or make Treasury the beneficiary of staker liabilities.

Retain the$5,000 batch threshold or24h eligibility, 1800s TWAP,2% average-price band,1% slippage cap, and0.5% per-call reserve chunk. Add a cumulative 0.5% quote-reserve limit per 1800-second window measured against its fixed starting reserve. Repeated `vent()` calls cannot reset that window or enlarge the base with a donation. This is a conservative first-release throughput limit, not a claim to remove every boundary or oracle attack.

The 72-hour deferral is an alert/escalation threshold, never an override of min-output, oracle freshness, allowlisting, or the cumulative limit. Permissionless means anyone may submit a valid transaction; it does not mean autonomous time-based execution or guaranteed safe processing. Unsupported paths wait without transferring custody to an administrator.

User matching and idle permanent auto-pairing have separate accounting. Reserve quote is not Treasury-spendable. Idle pairing may spend only unreserved inventory and already funded match-seed EMBER. Permanent LP is held in an immutable sink with no redemption, approval, rescue, migration, delegatecall, or upgrade route. Never call an AMM's redemption `burn()` and call that permanent liquidity.

## 14. Flow

Keep protocol CPMM routing, LP rows, explicit zap/unzap paths, and 25bps buys/35bps sells. LP fees are20bps both ways. Buy protocol share is2.5burn+2.5liquidity; sell protocol share is5burn+5liquidity+5Quote yield. These fees apply to the defined protocol pool/routes, not every possible external venue trading EMBER. Transfer tax stays zero.

At Bedrock's50% protocol rebate, effective totals are22.5bpsbuy and27.5bpssell, not half the entire trading fee. Quote yield on that sell is2.5bps. Internal settlement exemptions are authorized action paths, not user-set flags. Off-protocol routers cannot obtain special Compound privileges by pretending to be Forge.

## 15. Hearth

Hearth distributes only realized, funded fee-asset liabilities to staked ASH. Use a global per-asset reward index with checkpointed stake changes, so a new staker cannot capture an old batch. The24h ASH exit cooldown is retained. The first release pays Ethereum-local fees to Ethereum Hearth stakeholders. Satellite activation must define its own local funded distribution before admitting stake; global fee aggregation is not inferred from OFT transport.

## 16. Treasury

Choose a 3-of-5 Safe with actual distinct owners, not placeholder identities. Preserve48h parameter timelocks and the30/30/20/20 policy buckets for permanent-liquidity seed, match-reserve seed, incentives, and buybacks. Fee liabilities in GenesisFeeEscrow cannot be counted as available Treasury assets. Match-seed token funding must come from vested Treasury inventory or separately disclosed funding, never arbitrary economic minting.

A policy table is not proof that the Safe enforces a budget. Treasury proposals, disbursements, beneficiaries, and reports must be observable. No audit or legal approval is inferred from the config's template URLs.

## 17. Fissures

Fissures are defined but disabled. A later release must authorize the specific chain, funded250,000-EMBER seed from Treasury inventory, local receipt identities, operator set, secure transport pathways, and reassigned global budget. Sending an already issued Treasury token is not a new allocation against the cap. The90/10 Kindling LP and escrow rules apply.

Priority access requires a source-attested eligible identity proof without transporting Heat or synchronizing loyalty balances. That proof path is not supplied in this release; no cross-chain priority claim is activated by a boolean alone.

## 18. Referrals and AutoStoke

Referrals remain disabled. Their potential3% redirect is funded from the referee's own allocation, not new issuance. No referral path may multiply matched rewards or launder another lot's age.

AutoStoke is owner-opt-in per position. Keep0.1%-1% allowed tip,0.5% default, minimum24h/default7d interval, and100EMBER default minimum. Tips are disclosed compensation, separate from the zero protocol Compound fee. A keeper cannot alter the destination, sell fallback, or receipt set beyond the owner's signed settings. Manual owner compounding never earns the keeper tip.

## 19. Governance

Initial governance is the3-of-5 Safe through the existing48h timelock. Do not create an operational DAO merely by naming two chambers. Preserve the intended future Hearth/Forge constituency split, but a voting implementation requires a separate release with snapshot, quorum, delegation, proposal-class and deadlock rules. Until then, no tokenholder voting interface is represented as controlling contracts.

No role can seize principal, redirect protected fee liabilities, bypass the issuance ledger, or administratively pause in-kind withdrawal initiation/execution. A pause can stop new risk-taking routes. Core contracts must lack upgrade authority; periphery changes observe their timelock and cannot acquire custody escape rights. A displayed immutable-fields list does not prove those powers absent from bytecode.

## 20. Security and release posture

Keep the existing hard fee ceilings but preserve the exact nominal FURNACE identity in this revision. A cosmetic rebrand does not change economic invariants. An intentional economic fork must change its policy identity, tests, and disclosures. Use deterministic integer amounts/rates in contract arithmetic, with differential Solidity/Anchor vectors, overflow bounds, and directed rounding.

No mainnet release before the two independent audits selected by the project, unresolved critical/high findings resolved, complete operational evidence, adversarial integration tests, and operational monitoring. Audit count alone is not proof of safety. No artifact in this package represents an audit report, signed deployment, or live code verification.

## 21. Initial activation and omnichain accounting

**Ethereum alone is active with 100% of the emission allocation.** BNB Chain, Base, Arbitrum, and Solana remain present as planned definitions, disabled with 0%. Gauge and OFT pathways are disabled at initial activation. This is a staging decision; the home chain and monetary curve are not changed.

Enable no satellite merely because elapsed time reaches a milestone. Require its funded launch, complete receipt registry, bidirectional peer/library/DVN/executor settings, independent runtime evidence, audited payout accounting, and explicit budget reassignment. Chain-local Heat, Streak, timers, and Relics never ride on an OFT token transfer.

## 22. Solana

Solana is not part of initial launch. Its future deployment distinguishes executable programs, mint accounts, collections, and PDAs. Base58 decoding must yield32bytes; EIP-55 is inapplicable. A valid public key does not prove usable signer/upgrade authority. Do not reuse the historical registry examples as proof that deployment keys are held. A separate audited Anchor/SPL/Metaplex integration and independent supply/transport tests are mandatory before activation.

## 23. Deterministic deployment

Keep sender-guarded CreateX CREATE3 prediction with sender20bytes +00flag +11entropybytes, using the guarded salt. The nine preserved fixtures are calculated against the known placeholder sender; they convey no key control and cannot be signed from that identity unless actual authority is established. The actual sender must be supplied; fixtures inconsistent with it are cleared/recomputed, not silently blessed.

The registry now explicitly reserves16 EVM identities, including Mantle, the two independent pools, Flow, GenesisFeeEscrow, TreasuryVesting and Timelock. New entries stay null, so deployment validation fails honestly. No address is fabricated to make the build green. The Safe uses its own factory, full creation input and nonce; it is not a CreateX entry. Constructor arguments are allowed: CREATE3 address independence does not require insecure argument-free initialization. Whatever initialization pattern is chosen must be atomic and authenticated.

Economic/template checks can run before mining. Deployment checks require completed, correctly derived identities and real owners. A local checksum or prediction is never code/role/initializer verification. The provided package has no transaction-broadcast command.

## 24. Configuration, hashes and tests

`npm run check:config` validates the selected economic template, including explicit null operational fields. `npm run check:deploy` rejects them. `npm test` runs the included TypeScript/reference tests, not absent contract tests. `npm run config:hash` writes canonical data, a policy-identity hash, and source SHA-256 commitments.

Full config hash, economic policy identity, source hash, compiled bytecode hash, and initialized deployment state are separate commitments. A code-only repair can leave the data hash unchanged. Conversely, branding can change full data without changing economic identity. The release manifest must identify all relevant artifacts, compiler versions, dependencies, and actual deployment state.

The local hashing runtime in this package is the prior review's transcribed upstream js-sha3 runtime with its license and independent test vectors. It was not newly installed from npm in this environment. Replace/verify it against a locked production dependency and reproducible toolchain before a real release.

## 25. Deliberate rejections retained

No transfer taxes; no total-reset partial withdrawals; no calendar-locked commitment principal; no purchased blended age for unrelated new deposits; no open keeper skim; no lossy rolling Cast timestamps; no governance-redeemable permanent LP; no unbounded reward-budget multiplier; no claim of whale immunity or MEV immunity; no funds assigned to two owners; and no inferred global supply from a single chain's local counter.

Single-asset pools, the two-token model, progressive exits, source-lot age, the capped Conviction bucket, Pyre, Deeds, and the user-owned matching subsidy all remain. Their limitations are described instead of replacing them with another design branch.

## 26. Decisions made in v5.5

The delegated decisions are: keep the FURNACE/Ethereum slow monetary profile; stage one chain; apply the identified helper/VM validation repairs; independently pin exact economics; select ordinary-base-only Casting; make matching reservations pro-rata and one-use; default to no selling; use a dedicated fee escrow; keep principal exits independent of external settlement; select time-integrated checkpoint measures and bounded onchain passes; and separate hashes and release evidence. See `DECISIONS.md` for rationale and policy deltas.

## 27. Implementation order and completion criteria

First port and differentially test integer measures, supply reservations, exact vesting, receipt provenance and escrow transitions. Next implement Forge in-kind custody exits, cooling tickets and Seal transitions with reward debt archived independently. Then implement bounded epoch settlement, funded matching and Vent liabilities. Finally integrate Kindling, the two pools, Deed auctions, and the Ethereum-only transport-disabled deployment profile.

The reference TypeScript is executable; Solidity/Anchor custody, authenticated ledgers, oracle enforcement, full epoch paging, auction transfer logic, mining/broadcast automation, deployed bytecode checks and audits are not implemented here. These are implementation deliverables with selected rules, not decisions delegated back to the user. Actual signers, custody keys, operational start time, external LP identity and audit evidence remain factual deployment inputs that software must not invent.
