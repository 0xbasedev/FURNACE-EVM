/**
 * FURNACE v5.5.0 - canonical design/configuration consolidation.
 * This file supersedes the v5.4 configuration for subsequent implementation.
 * No contract deployment or audit is implied. Active launch: Ethereum only.
 * Amounts are human-unit strings; display helpers use numbers. Monetary
 * reference settlement is in accounting.ts and uses integer smallest units.
 * Presentation, configuration data, source, and deployment commitments differ.
 * See DECISIONS.md for the decisions made under delegated design authority.
 */
import { validateResolvedConfig, type CheckStage, type Diagnostic } from './validation.js';
export type AssetBinding = { kind: 'protocol'; contract: ContractName } | { kind: 'external'; address: Address | null; decimals: number };
export type ExecutionPolicy = {
  "status": "design-canonical-not-deployed",
  "activation": {
    "initialChain": "ethereum",
    "bridgeEnabled": false,
    "satellitesRequireSeparateRelease": true
  },
  "casting": {
    "eligibleRewardClasses": [
      "ordinaryBase"
    ],
    "denominator": "postConvictionOrdinaryBase",
    "singleTokenPolicy": "liquid",
    "requiresActiveSourceLot": true,
    "explicitZapConsent": true
  },
  "matching": {
    "ownership": "user",
    "allocation": "epochProRataByEligibleBaseReward",
    "automaticCastPriority": true,
    "optionalStokeUsesOnlyRemainder": true,
    "claimWindowEpochs": 7,
    "oneUsePerRewardUnit": true,
    "expiry": "releaseQuoteOnlyKeepUserReward",
    "idlePairUsesOnlyUnreservedInventory": true,
    "idlePairEmber": "treasuryMatchSeed"
  },
  "settlement": {
    "weightBasis": "timeIntegratedPerLot",
      "budgetAccrual": "onlyWhilePoolHasActiveStake",
    "heatIntegral": "cappedSqrtAntiderivative",
    "multiplierScale": "1000000000000000000000000000",
    "maxLotsPerPage": 32,
    "aggregateAuthority": "onchainCheckpoints",
    "residue": "retainTaggedUnallocated",
    "exitsDependOnSettlement": false
  },
  "withdrawals": {
    "aggregation": "frozenReferenceCumulativeRequests",
    "planHorizonSeconds": 259200,
    "cancelConsumesPlanQuota": true,
    "newRequestsNeverDelayMaturedTickets": true,
    "freeze": "requestedSlice",
    "lapse": "resumeFrozen",
    "exitAsset": "inKind",
    "exitRequiresOracle": false
  },
  "seals": {
    "membership": "sealedCohortsOnly",
    "topupsJoinExistingSeal": false,
    "pendingCooling": "pauseSealAccrualAndExtendEnd",
    "tapBeforeMaturity": "forfeitUnvestedBonus",
    "walletKeystoneRequiresWholeTermOwnership": true
  },
  "kindling": {
    "feeCustody": "dedicatedImmutableEscrow",
    "successRelease": "afterAtomicPoolInitialization",
    "failureRefundAsset": "depositedQuote",
    "maxSettlementDelaySeconds": 259200,
    "cutoff": "rejectNewDepositsAtDeadline",
    "cancelUntilSettlement": "netPrincipalNowFeeIfLaunchFails",
    "treasuryFallback": "separateFundedEvent",
    "closeBountyBasis": "acceptedGrossQuote"
  },
  "ashfall": {
    "lotEligibility": "actualParticipationAgeAndActiveStreak",
    "minimumParticipationDays": 30,
    "founderFloorCountsAsParticipation": false,
    "burnReceipt": "uniqueAuthenticatedEconomicBurn",
    "transportBurnCredit": false,
    "voluntaryRecapture": "possibleAndDisclosed"
  },
  "vent": {
    "aggregateWindowSeconds": 1800,
    "aggregateMaxReserveBps": 50,
    "reserveReference": "fixedWindowStart",
    "atDeferralLimit": "alertNeverWeakenGuards",
    "principalExitRequiresVent": false
  },
  "deeds": {
    "unclaimedRewards": "goWithDeed",
    "sellerMutationsWhileListed": "cancelListingFirst",
    "cancellation": "allowedBeforeSettlementWithPullRefunds",
    "noInstantBuyout": true,
    "receiverFailure": "claimDeliveryCannotBlockSellerProceeds"
  },
  "hearth": {
    "feeScope": "chainLocalFundedLiabilities",
    "crossChainFeeAggregation": false
  },
  "release": {
    "safeThreshold": 3,
    "safeOwnersRequired": 5,
    "minimumIndependentAudits": 2,
    "sourceHashRequired": true,
    "bytecodeHashRequired": true,
    "initializerHashRequired": true,
    "chainStateVerificationRequired": true
  }
};
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
    argumentFreeConstructors: boolean; // constructor args are allowed; initialization must remain atomic
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
      singleton: EvmAddress | null;
      initializerHash: string | null;
      initCodeHash: string | null;
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
 * A target share of compatible ordinary base rewards can be cast: the protocol
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
   * Pool-specific rule. Source-lot return works when the earning lot holds
   * compatible LP collateral. For single-token lots (Ember Vault's EMBER,
   * Cold Storage's USDC) LP units cannot be added to the balance, so the
   * cast share is paid LIQUID instead — the protocol never silently changes
   * a stable-only depositor's exposure, and never force-creates an LP
   * position they didn't ask for.
   */
  incompatibleCollateral: 'liquid';
  /**
   * Ownership. LP minted from a user's emission + match-reserve quote is
   * 100% USER-OWNED, staked in their lot — the reserve quote is a protocol
   * subsidy converting fee revenue into deep, sticky liquidity. It is NOT
   * burned. `liquidityLane.matchReserve.burnMatchedLp` applies only to the
   * idle auto-pair path (reserve quote + treasury-seeded EMBER after 7 idle
   * epochs), whose LP is burned as permanent protocol-owned liquidity.
   */
  matchedLpOwnership: 'user';
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
   * pre-return Heat pool that epoch (L * stake * additiveBonus / ordinaryWeight). Without the cap,
   * a single early sealer would collect the entire 10% and the 4.15×
   * ceiling would be a number in a doc. Whatever the cap holds back — and
   * the whole bucket in an epoch when nobody is sealed — flows back into
   * the Heat pool that same epoch. Conviction changes distribution, never
   * issuance.
   */
  bucketCap: {
    enabled: true;
    /**
     * Cap each sealed position at the ADDITIVE value of its seal bonus:
     *   cap_i = L × s_i × b_i / W
     * where L is the pre-return Heat budget (63% of the epoch), s_i the
     * position's stake, b_i its additive seal bonus (+0.15..+0.50), and
     * W = Σ s_j h_j over ordinary (pre-seal) Heat. This equals
     * (b_i / h_i) × P_i — the bonus's marginal worth in the Heat pool —
     * NOT b_i × P_i, which would overstate it by the Heat itself (3.65× at
     * h=3.65). Using the pre-return L keeps the cap non-circular.
     */
    capToSealBonusOfHeatShare: true;
    /** Where the unallocated bucket goes: back into the Heat pool. */
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
  /**
   * Cancel/lapse resumes the FROZEN Heat — the cooling interval never aged,
   * no LP left, so no Heat is lost. `true` (fresh lot at age 0) was the v5.2
   * wording; it contradicts onCancelOrLapse: 'resumeFrozen' and is rejected
   * by the validator.
   */
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
     * transfers at zero — voluntary self-recapture remains possible and is disclosed. The token disappears in every case.
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
    matchReserve?: {
      idleEpochsBeforeAutoPair: number;
      /**
       * Burns the LP from the IDLE AUTO-PAIR path only: after
       * idleEpochsBeforeAutoPair with no Stokes/Casts consuming the reserve,
       * the idle quote pairs with EMBER from `idlePairEmberSource` and the
       * resulting LP is burned as permanent protocol-owned liquidity.
       * Cast/Stoke matched LP is USER-OWNED (see casting.matchedLpOwnership)
       * and is never burned.
       */
      burnMatchedLp: true;
      /** Where the EMBER side of the idle auto-pair comes from. */
      idlePairEmberSource: 'treasuryMatchSeed';
    };
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
  addresses: Record<ChainKey, Address | null>;
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
  guardian: Record<ChainKey, Address | null>;
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
  /**
   * The 3% is forwarded to the treasury immediately, but it is ESCROWED
   * there until close: if the raise fails (below minRaiseUsd), the fee is
   * refunded with principal — "full refunds incl. fees" needs actual funding,
   * not a promise. The treasury cannot spend escrowed Kindling fees until a
   * successful close.
   */
  feeEscrowUntilClose: true;
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
   *  assets and burns the LP in the same transaction — no intermediate uninitialized pool state; not MEV immunity. */
  atomicPoolInit: boolean;
  /**
   * Bounty (bps of the raise, from the Treasury's fee) to whoever calls the
   * permissionless atomic close. Bots race to close it the second it is due —
   * no EOA to wait for, nothing to front-run.
   */
  closeBountyBps: Bps;
}

export interface FurnaceConfig {
  assets: Record<ChainKey, Record<string, AssetBinding>>;
  execution: ExecutionPolicy;
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

export const CREATEX_FACTORY: EvmAddress = '0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed';
export const DEPLOYER: EvmAddress = '0x1111111111111111111111111111111111111111'; // TEMPLATE ONLY; no signing authority implied.
export const evmContracts = {
  "EmberToken": {
    "salt": "0x111111111111111111111111111111111111111100000000000000000001415e",
    "address": "0xf1e5b7820a8c6f6349a576db516142c8d341dcc4",
    "prefix": "F1E5",
    "description": "EMBER \u2014 LayerZero OFT protocol token"
  },
  "AshToken": {
    "salt": "0x11111111111111111111111111111111111111110000000000000000000014c3",
    "address": "0xa5e55c164036f63e9b6e6337c465eedead49fb5b",
    "prefix": "A5E5",
    "description": "ASH \u2014 LayerZero OFT share/governance token"
  },
  "FeeRouter": {
    "salt": "0x111111111111111111111111111111111111111100000000000000000000faf3",
    "address": "0xfee5356949802d661959360a5e4004e1d8c685a2",
    "prefix": "FEE5",
    "description": "FeeRouter \u2014 auto-routes fees to burn + liquidity"
  },
  "Forge": {
    "salt": "0x11111111111111111111111111111111111111110000000000000000000135c5",
    "address": "0xf09551c13e2ca9cbeed634452a1f37d89a25532d",
    "prefix": "F095",
    "description": "Forge \u2014 post-launch staking (all pools)"
  },
  "Ignition": {
    "salt": "0x11111111111111111111111111111111111111110000000000000000000035e7",
    "address": "0x19172ad5c06ccc86a6e2712d06500f1028cf185b",
    "prefix": "1917",
    "description": "Ignition \u2014 Genesis bootstrap staking"
  },
  "Kindling": {
    "salt": "0x1111111111111111111111111111111111111111000000000000000000005c57",
    "address": "0x5a1d6ee608bf6e94b53789824705427ea40f2746",
    "prefix": "5A1D",
    "description": "Kindling \u2014 liquidity bootstrap auction"
  },
  "Hearth": {
    "salt": "0x111111111111111111111111111111111111111100000000000000000004d0a0",
    "address": "0xea272470c2529afe408d13bf6057b72a1a8763ce",
    "prefix": "EA27",
    "description": "Hearth \u2014 ASH staking, fee share + governance"
  },
  "Relics": {
    "salt": "0x111111111111111111111111111111111111111100000000000000000001d233",
    "address": "0x2e1c923b32c214c4b7b2b8bd30daeb9f0a183dbd",
    "prefix": "2E1C",
    "description": "Relics \u2014 soulbound duration-milestone NFTs"
  },
  "Deeds": {
    "salt": "0x1111111111111111111111111111111111111111000000000000000000015534",
    "address": "0xdeed54948eab9875d89a77cc383714d6a5d7dc6d",
    "prefix": "DEED",
    "description": "Deeds \u2014 position NFTs + the Deed Market"
  },
  "Mantle": {
    "prefix": "BA5E",
    "salt": null,
    "address": null,
    "description": "Economic issuance ledger and epoch budget controller"
  },
  "BlastPool": {
    "prefix": "F001",
    "salt": null,
    "address": null,
    "description": "EMBER/USDC full-range constant-product pair"
  },
  "SmelterPool": {
    "prefix": "F002",
    "salt": null,
    "address": null,
    "description": "EMBER/WETH full-range constant-product pair"
  },
  "Flow": {
    "prefix": "F10A",
    "salt": null,
    "address": null,
    "description": "Protocol swap and zap entrypoint"
  },
  "GenesisFeeEscrow": {
    "prefix": "E5C0",
    "salt": null,
    "address": null,
    "description": "Non-spendable refundable Kindling/Fissure fees"
  },
  "TreasuryVesting": {
    "prefix": "7E57",
    "salt": null,
    "address": null,
    "description": "Cumulative exact treasury token vesting"
  },
  "Timelock": {
    "prefix": "71AE",
    "salt": null,
    "address": null,
    "description": "Governance execution delay controller"
  }
} as const;
export const solanaIds = {
  "stakingProgram": {
    "keypair": "keys/staking-program.json",
    "address": "HVQT6MycoarDw9ktbZBv282HH8SttSR4ycvTeSTw9kKe",
    "description": "Furnace staking program (Forge + Ignition)"
  },
  "feeRouterProgram": {
    "keypair": "keys/fee-router-program.json",
    "address": "ECgH9KPnFW9GoM9fe6uVYrmaJpQMsacA8EiiSKwo3Egu",
    "description": "FeeRouter program (burn + POL builder)"
  },
  "emberMint": {
    "keypair": "keys/ember-mint.json",
    "address": "AtbnZK5DQibjpxkhynqq7617iuseoWaABytXN7Q3RnbD",
    "description": "EMBER SPL mint (9 decimals)"
  },
  "ashMint": {
    "keypair": "keys/ash-mint.json",
    "address": "7a2HrKABUqNEsPntziBaDMVMboQ6hThWJVFu9Zp3cAnW",
    "description": "ASH SPL mint (9 decimals)"
  },
  "relicsCollection": {
    "keypair": "keys/relics-collection.json",
    "address": "GgpFhkNfS4Y16gX746NNzWJup6yDcpCRHjw5NNVKFdCL",
    "description": "Relics Metaplex collection mint (soulbound)"
  }
} as const;
export type ContractName = keyof typeof evmContracts;
export function contractAddress(name: ContractName, c: FurnaceConfig = furnaceConfig): EvmAddress {
  const entry = c.deployment.evm.contracts[name];
  if (!entry?.address) throw new Error(`Unmined contract: ${name}`);
  return entry.address;
}
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
export const furnaceConfig: FurnaceConfig = {
  "version": "5.5.0",
  "brand": {
    "protocolName": "FURNACE",
    "shortName": "Furnace",
    "tagline": "Stake longer. Burn brighter.",
    "description": "Loyalty staking with source-lot rewards, disclosed matching subsidies, tradable positions, and funded fee sharing. Standard Forge fees follow the fixed 40/40/10/10 routing.",
    "domain": "furnace.fi",
    "supportEmail": "hello@furnace.fi",
    "assets": {
      "logo": "/brand/furnace-wordmark.svg",
      "logoMark": "/brand/furnace-mark.svg",
      "favicon": "/brand/favicon.svg",
      "ogImage": "/brand/og.png",
      "tokenIcon": "/brand/ember.svg",
      "lpIcon": "/brand/ember-eth-lp.svg",
      "relicArtDir": "/brand/relics/"
    },
    "theme": {
      "mode": "dark",
      "colors": {
        "bg": "#0d0a08",
        "surface": "#171310",
        "surfaceRaised": "#221b16",
        "border": "#33281f",
        "text": "#f5ede6",
        "textMuted": "#a89a8c",
        "accent": "#ff6a00",
        "accentGlow": "#ffb347",
        "warning": "#f59e0b",
        "danger": "#e5484d",
        "ready": "#22c55e",
        "heat": "#ff7a00",
        "cooling": "#6b7a8f"
      },
      "fonts": {
        "display": "Space Grotesk",
        "body": "Inter",
        "mono": "JetBrains Mono"
      },
      "radius": "14px"
    },
    "social": {
      "x": "https://x.com/furnacefi",
      "discord": "https://discord.gg/furnacefi",
      "telegram": "https://t.me/furnacefi",
      "github": "https://github.com/furnacefi",
      "docs": "https://docs.furnace.fi"
    },
    "legal": {
      "termsUrl": "https://furnace.fi/terms",
      "riskDisclosureUrl": "https://furnace.fi/risk"
    }
  },
  "names": FURNACE_NAMES,
  "pages": [
    {
      "key": "dashboard",
      "path": "/",
      "title": "Dashboard",
      "navLabel": "Home",
      "order": 0,
      "enabled": true,
      "gate": "always"
    },
    {
      "key": "ignition",
      "path": "/ignition",
      "title": "Ignition",
      "navLabel": "Ignition",
      "order": 1,
      "enabled": true,
      "gate": "duringGenesis"
    },
    {
      "key": "kindling",
      "path": "/kindling",
      "title": "Kindling",
      "navLabel": "Kindling",
      "order": 2,
      "enabled": true,
      "gate": "duringGenesis"
    },
    {
      "key": "forge",
      "path": "/forge",
      "title": "The Forge",
      "navLabel": "Forge",
      "order": 3,
      "enabled": true,
      "gate": "afterGenesis"
    },
    {
      "key": "relics",
      "path": "/relics",
      "title": "Relics",
      "navLabel": "Relics",
      "order": 4,
      "enabled": true,
      "gate": "afterGenesis"
    },
    {
      "key": "hearth",
      "path": "/hearth",
      "title": "The Hearth",
      "navLabel": "Hearth",
      "order": 5,
      "enabled": true,
      "gate": "afterGenesis"
    },
    {
      "key": "flow",
      "path": "/flow",
      "title": "Flow",
      "navLabel": "Flow",
      "order": 6,
      "enabled": true,
      "gate": "afterGenesis"
    },
    {
      "key": "deeds",
      "path": "/deeds",
      "title": "Deed Market",
      "navLabel": "Deeds",
      "order": 7,
      "enabled": true,
      "gate": "afterGenesis"
    },
    {
      "key": "docs",
      "path": "/docs",
      "title": "Docs",
      "navLabel": "Docs",
      "order": 8,
      "enabled": true,
      "gate": "always"
    }
  ],
  "copy": {
    "buttons": {
      "connect": "Connect wallet",
      "genesisDeposit": "Join the Ignition",
      "genesisWithdraw": "Pull out (fee not refunded)",
      "deposit": "Stake",
      "withdraw": "Start cooling",
      "withdrawNow": "Withdraw Now",
      "claim": "Start venting",
      "claimNow": "Claim Now",
      "compound": "Compound",
      "stokeToCapstone": "Stoke into Capstone",
      "stokeToLp": "Stoke into LP",
      "cancel": "Cancel",
      "emergency": "Emergency exit",
      "tap": "Use a Tap",
      "feedPyre": "Feed the Pyre",
      "chooseTrack": "Choose a track",
      "zapStake": "Stake it",
      "swap": "Swap",
      "buyLp": "Buy LP",
      "sellLp": "Sell LP",
      "listDeed": "List this Deed",
      "buyDeed": "Buy this Deed",
      "delistDeed": "Delist",
      "placeBid": "Place bid"
    },
    "warnings": {
      "withdrawResets": "Executed ordinary withdrawal resets this position's {streak} and cools financial age proportionally. Only the requested slice stops earning during its {withdrawHours} h cooldown.",
      "claimVsCompound": "{compoundVerb} is instant and keeps your {multiplier}. Claiming starts a {claimHours} h timer.",
      "emergency": "This skips the timer and costs {emergencyFee}%: {emergencyBurn}% burned, {emergencyLiquidity}% to permanent liquidity, {emergencyStakers}% to everyone who stayed.",
      "depositDilutes": "New liquidity enters at 1.0\u00d7. Your blended {multiplier} will drop to {newMultiplier}\u00d7.",
      "genesisFee": "The {genesisFee}% fee follows this phase's escrow and refund rules; review the phase-specific confirmation.",
      "tapNotice": "A Tap keeps your {streak}. The {withdrawFee}% fee and the cooling timer still apply.",
      "withdrawCools": "Withdrawing {pct}% keeps {keptPct}% of your {multiplier} age and resets your {streak}.",
      "capstone": "{capstone} earns no emissions. It adds up to +{maxBonus}\u00d7 {multiplier} when it is worth {ratioForMax}% of your LP, and it never sells.",
      "stokeFallback": "Without an available match, Stoke holds rewards in Capstone or leaves them claimable. A selling zap requires separate explicit approval.",
      "pyreBurn": "Burning {amount} {symbol} is permanent and irreversible. The {pyre} badge is soulbound \u2014 it can never be sold \u2014 and its +{boost}\u00d7 {multiplier} lasts forever.",
      "castingNote": "Up to {pct}% of ordinary base rewards from compatible LP lots is cast into user-owned LP using reserved quote. Other reward classes use their designated payout paths; incompatible single-token lots receive liquid EMBER. The source lot keeps its age; no market sale completes a cast.",
      "trackForfeit": "Leaving before day {days} forfeits the unvested +{bonus}\u00d7 {tracks} bonus. Your principal is never locked and never slashed \u2014 it still exits through the normal {withdraw} timer.",
      "deedSale": "Selling this {deed} transfers its collateral, {capstone}, escrow and rewards. The buyer receives {heatCarry}% of capped financial age and starts a new {streak}. Your wallet badges stay with you; {marketFee}% of the price goes to the {feeRouter}.",
      "deedBuy": "This {deed} carries {heatAge} days of {multiplier} age ({heatCarry}% of what the seller earned). The {streak} starts at 0 for you; badges are earned, never bought.",
      "sealForfeit": "Withdrawing before the {tracks} term ends forfeits the escrowed bonus: {burn}% burned, {reserve}% to the {matchReserve}, {pot}% to positions still inside their term. Principal is untouched.",
      "deedAuction": "This {deed} uses a {auctionHours}-hour ascending auction with reserve {reserve} {currency}. The seller may cancel before atomic settlement; bid refunds are pull-based. No instant buyout.",
      "ignitionFee": "Ignition charges {genesisFee}% to Treasury immediately; this earned fee is not refunded.",
      "kindlingFee": "Kindling holds the {genesisFee}% Treasury fee in escrow. Success releases it; event failure refunds it with any remaining principal."
    },
    "toasts": {
      "cooling": "Cooling started. {withdrawHours} h to go.",
      "readyToWithdraw": "Cooled. Withdraw Now is live for {windowHours} h.",
      "venting": "Venting started. {claimHours} h to go.",
      "readyToVent": "Vented. Claim Now is live.",
      "stoked": "Stoked. {amount} {symbol} added at {multiplier}\u00d7.",
      "lapsed": "The request lapsed. Its slice resumes from frozen financial age, adjusted for any intervening executed cooling. No fresh-age reset.",
      "pyreMinted": "{pyre} {tier} forged. +{boost}\u00d7 {multiplier}, forever.",
      "emissionCast": "Matched {quoteAmount} {quoteSymbol} to {castAmount} {symbol}; {lpAmount} user-owned LP added to the source lot. Unmatched rewards remain claimable.",
      "trackVested": "{tracks} complete: +{bonus}\u00d7 bonus vested.",
      "quoteYieldPaid": "Real yield: {amount} {symbol} from swap fees.",
      "deedListed": "{deed} listed for {price} {currency}.",
      "deedSold": "{deed} sold. {fee} went to the {feeRouter}; the pool kept its liquidity.",
      "deedBought": "{deed} bought with {heatAge} days of {multiplier} age.",
      "keystoneMinted": "Keystone forged \u2014 your {tracks} term is complete.",
      "sealForfeited": "Escrow forfeited: {burn} burned, {reserve} to the reserve, {pot} to the Sealed.",
      "bidPlaced": "Bid placed: {amount} {currency}. Auction ends in {time}.",
      "deedAuctionWon": "Auction won \u2014 the {deed} is yours with {heatAge} days of {multiplier} age.",
      "deedAuctionExpired": "Auction ended below reserve. Your {deed} was delisted."
    },
    "timeline": {
      "title": "Your {streak}",
      "heatVsStreak": "The top-up added a fresh lot. Existing lots kept their age; the displayed blended Heat changed.",
      "nextBump": "Next Relic: {relic} in {days} days. Financial-age bonuses accrue continuously.",
      "pending": "Cooling {amount} LP \u2014 withdraw in {time}."
    },
    "empty": {
      "noPosition": "Nothing in the {staking} yet. Stake LP or buy some on {swap}.",
      "noRelics": "Your first relic forms at {firstRelicDays} days."
    }
  },
  "chains": [
    {
      "key": "ethereum",
      "name": "Ethereum",
      "vm": "evm",
      "enabled": true,
      "role": "home",
      "chainId": 1,
      "nativeSymbol": "ETH",
      "rpcUrls": [
        "https://eth.llamarpc.com"
      ],
      "explorerUrl": "https://etherscan.io",
      "lz": {
        "eid": 30101,
        "endpoint": "0x1a44076050125825900e736c501f859c50fE728c",
        "dvns": [],
        "requiredDvnCount": 2
      },
      "quoteAsset": {
        "symbol": "WETH",
        "address": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "decimals": 18,
        "conversion": "none"
      },
      "listedTokens": [
        {
          "symbol": "USDC",
          "address": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          "decimals": 6,
          "conversion": "swapAtClose",
          "maxSlippageBps": 50
        },
        {
          "symbol": "WBTC",
          "address": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
          "decimals": 8
        }
      ],
      "externalDex": {
        "kind": "uniswap-v2",
        "router": "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"
      },
      "fixedEmissionSharePct": 100,
      "runsGenesis": true,
      "genesisAcceptedAssets": [
        {
          "symbol": "WETH",
          "address": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
          "decimals": 18,
          "conversion": "none"
        },
        {
          "symbol": "USDC",
          "address": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          "decimals": 6,
          "conversion": "swapAtClose",
          "maxSlippageBps": 50
        },
        {
          "symbol": "WBTC",
          "address": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
          "decimals": 8
        }
      ]
    },
    {
      "key": "bsc",
      "name": "BNB Chain",
      "vm": "evm",
      "enabled": false,
      "role": "satellite",
      "chainId": 56,
      "nativeSymbol": "BNB",
      "rpcUrls": [
        "https://bsc-dataseed.binance.org"
      ],
      "explorerUrl": "https://bscscan.com",
      "lz": {
        "eid": 30102,
        "endpoint": "0x1a44076050125825900e736c501f859c50fE728c",
        "dvns": [],
        "requiredDvnCount": 2
      },
      "quoteAsset": {
        "symbol": "WBNB",
        "address": "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
        "decimals": 18,
        "conversion": "none"
      },
      "listedTokens": [
        {
          "symbol": "USDT",
          "address": "0x55d398326f99059fF775485246999027B3197955",
          "decimals": 18,
          "conversion": "swapAtClose",
          "maxSlippageBps": 50
        }
      ],
      "externalDex": {
        "kind": "pancake-v2",
        "router": "0x10ED43C718714eb63d5aA57B78B54704E256024E"
      },
      "fixedEmissionSharePct": 0,
      "runsGenesis": false,
      "genesisAcceptedAssets": [
        {
          "symbol": "WBNB",
          "address": "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
          "decimals": 18,
          "conversion": "none"
        },
        {
          "symbol": "USDT",
          "address": "0x55d398326f99059fF775485246999027B3197955",
          "decimals": 18,
          "conversion": "swapAtClose",
          "maxSlippageBps": 50
        }
      ]
    },
    {
      "key": "base",
      "name": "Base",
      "vm": "evm",
      "enabled": false,
      "role": "satellite",
      "chainId": 8453,
      "nativeSymbol": "ETH",
      "rpcUrls": [
        "https://mainnet.base.org"
      ],
      "explorerUrl": "https://basescan.org",
      "lz": {
        "eid": 30184,
        "endpoint": "0x1a44076050125825900e736c501f859c50fE728c",
        "dvns": [],
        "requiredDvnCount": 2
      },
      "quoteAsset": {
        "symbol": "WETH",
        "address": "0x4200000000000000000000000000000000000006",
        "decimals": 18,
        "conversion": "none"
      },
      "listedTokens": [
        {
          "symbol": "USDC",
          "address": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
          "decimals": 6,
          "conversion": "swapAtClose",
          "maxSlippageBps": 50
        }
      ],
      "externalDex": {
        "kind": "aerodrome",
        "router": "0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43"
      },
      "fixedEmissionSharePct": 0,
      "runsGenesis": false,
      "genesisAcceptedAssets": [
        {
          "symbol": "WETH",
          "address": "0x4200000000000000000000000000000000000006",
          "decimals": 18,
          "conversion": "none"
        },
        {
          "symbol": "USDC",
          "address": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
          "decimals": 6,
          "conversion": "swapAtClose",
          "maxSlippageBps": 50
        }
      ]
    },
    {
      "key": "arbitrum",
      "name": "Arbitrum One",
      "vm": "evm",
      "enabled": false,
      "role": "satellite",
      "chainId": 42161,
      "nativeSymbol": "ETH",
      "rpcUrls": [
        "https://arb1.arbitrum.io/rpc"
      ],
      "explorerUrl": "https://arbiscan.io",
      "lz": {
        "eid": 30110,
        "endpoint": "0x1a44076050125825900e736c501f859c50fE728c",
        "dvns": [],
        "requiredDvnCount": 2
      },
      "quoteAsset": {
        "symbol": "WETH",
        "address": "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
        "decimals": 18,
        "conversion": "none"
      },
      "listedTokens": [
        {
          "symbol": "USDC",
          "address": "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
          "decimals": 6,
          "conversion": "swapAtClose",
          "maxSlippageBps": 50
        }
      ],
      "externalDex": {
        "kind": "uniswap-v3",
        "router": "0xE592427A0AEce92De3Edee1F18E0157C05861564"
      },
      "fixedEmissionSharePct": 0,
      "runsGenesis": false,
      "genesisAcceptedAssets": [
        {
          "symbol": "WETH",
          "address": "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
          "decimals": 18,
          "conversion": "none"
        },
        {
          "symbol": "USDC",
          "address": "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
          "decimals": 6,
          "conversion": "swapAtClose",
          "maxSlippageBps": 50
        }
      ]
    },
    {
      "key": "solana",
      "name": "Solana",
      "vm": "svm",
      "enabled": false,
      "role": "satellite",
      "cluster": "mainnet-beta",
      "nativeSymbol": "SOL",
      "rpcUrls": [
        "https://api.mainnet-beta.solana.com"
      ],
      "explorerUrl": "https://solscan.io",
      "lz": {
        "eid": 30168,
        "endpoint": "76y77prsiCMvXMjuoZ5VRrhG5qYBrUMYTE5WgHqgjEn6",
        "dvns": [],
        "requiredDvnCount": 2
      },
      "quoteAsset": {
        "symbol": "wSOL",
        "address": "So11111111111111111111111111111111111111112",
        "decimals": 9,
        "conversion": "none"
      },
      "listedTokens": [
        {
          "symbol": "USDC",
          "address": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
          "decimals": 6,
          "conversion": "swapAtClose",
          "maxSlippageBps": 50
        }
      ],
      "externalDex": {
        "kind": "jupiter",
        "router": "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4"
      },
      "fixedEmissionSharePct": 0,
      "runsGenesis": false,
      "genesisAcceptedAssets": [
        {
          "symbol": "wSOL",
          "address": "So11111111111111111111111111111111111111112",
          "decimals": 9,
          "conversion": "none"
        },
        {
          "symbol": "USDC",
          "address": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
          "decimals": 6,
          "conversion": "swapAtClose",
          "maxSlippageBps": 50
        }
      ]
    }
  ],
  "deployment": {
    "evm": {
      "strategy": "create3",
      "factory": CREATEX_FACTORY,
      "deployer": DEPLOYER,
      "saltGuard": "msgSender",
      "argumentFreeConstructors": false,
      "initializeInDeployTx": true,
      "contracts": evmContracts,
      "treasurySafe": {
        "factory": "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67",
        "saltNonce": null,
        "singleton": null,
        "initializerHash": null,
        "initCodeHash": null
      }
    },
    "svm": {
      "cluster": "mainnet-beta",
      "upgradeAuthority": "",
      "contracts": solanaIds
    }
  },
  "token": {
    "name": "Ember",
    "symbol": "EMBER",
    "decimals": {
      "evm": 18,
      "svm": 9
    },
    "standard": "lz-oft-v2",
    "oft": {
      "sharedDecimals": 6,
      "homeChain": "ethereum",
      "enforcedGas": {
        "send": 80000,
        "compose": 200000
      },
      "rateLimit": {
        "amountPerWindow": "250000",
        "windowSeconds": 3600
      }
    },
    "allocations": {
      "kindlingPool": "420000",
      "treasury": {
        "amount": "500000",
        "cliffDays": 0,
        "vestingDays": 365
      },
      "team": {
        "amount": "0",
        "cliffDays": 180,
        "vestingDays": 730,
        "recipients": []
      }
    },
    "maxSupply": "21000000"
  },
  "shareToken": {
    "name": "Ash",
    "symbol": "ASH",
    "decimals": {
      "evm": 18,
      "svm": 9
    },
    "standard": "lz-oft-v2",
    "maxSupply": "70000",
    "allocations": {
      "launch": {
        "ignition": "41000",
        "kindling": "1000"
      },
      "forge": "28000"
    },
    "forgeTrickleDays": 730
  },
  "ignition": {
    "name": "IGNITION",
    "address": evmContracts.Ignition.address,
    "durationHours": 120,
    "minDurationHours": 48,
    "maxDurationHours": 336,
    "startTimestamp": null,
    "depositFeePct": 3,
    "feeDestination": "treasury",
    "withdrawDuringWindow": {
      "enabled": true,
      "refundFee": false
    },
    "exitWindowHours": 24,
    "exitFeePct": 0,
    "pools": [
      {
        "id": "ign-usdc",
        "stakeToken": "USDC",
        "weight": 100,
        "name": "USDC Pool"
      },
      {
        "id": "ign-weth",
        "stakeToken": "WETH",
        "weight": 100,
        "name": "WETH Pool"
      },
      {
        "id": "ign-wbtc",
        "stakeToken": "WBTC",
        "weight": 100,
        "name": "WBTC Pool"
      },
      {
        "id": "ign-eth-usdc-lp",
        "stakeToken": "WETH/USDC",
        "weight": 150,
        "name": "WETH/USDC LP Pool"
      }
    ],
    "rewards": {
      "token": "ASH",
      "total": "41000",
      "mode": "per-second-pro-rata",
      "vesting": "none"
    },
    "founderBadge": {
      "enabled": true,
      "key": "first-flame",
      "phantomAgeBonusDays": 15
    },
    "heatHeadStart": "ignitionStart",
    "principalAtClose": {
      "usdc": "autoStakeColdStorage",
      "usdcOptOutAtDeposit": true,
      "otherAssets": "claimableFeeFree",
      "headStartWindowDays": 7,
      "headStartCappedToUsdKept": true
    },
    "earlyBird": {
      "enabled": true,
      "maxBonusPct": 10,
      "shape": "linear"
    }
  },
  "kindling": {
    "enabled": true,
    "name": "KINDLING",
    "address": evmContracts.Kindling.address,
    "mode": "auction",
    "durationHours": 24,
    "quoteToken": "USDC",
    "seedEmberBpsOfMax": 200,
    "minRaiseUsd": 100000,
    "maxRaiseUsd": 5000000,
    "maxPerWalletUsd": 25000,
    "depositFeePct": 3,
    "feeDestination": "treasury",
    "feeEscrowUntilClose": true,
    "priceMode": "clearing",
    "polPair": "EMBER/USDC",
    "lpSplit": {
      "depositorDeedsPct": 90,
      "burnPct": 10
    },
    "ashBonusPool": "1000",
    "fallback": "treasury-seed",
    "atomicPoolInit": true,
    "closeBountyBps": 5
  },
  "forge": {
    "fees": {
      "depositPct": 1,
      "withdrawPct": 1,
      "claimPct": 0,
      "compoundPct": 0,
      "waiveDepositFeeFromFlow": true
    },
    "heat": {
      "startMultiplier": 1,
      "rampBonus": 1.5,
      "rampDays": 365,
      "shape": "sqrt",
      "depositDilution": "perLot",
      "compoundInheritsAge": true,
      "compoundProvenance": "sourceLot",
      "maxLotsPerPosition": 32,
      "lotExhaustion": "newDeed",
      "withdrawCooling": "proportional",
      "tapDrawdownMode": "youngestFirst"
    },
    "compound": {
      "defaultTarget": "capstoneThenLp",
      "userCanChoose": true,
      "lpMatch": {
        "enabled": true,
        "source": "matchReserve",
        "fallback": "capstone"
      }
    },
    "capstone": {
      "enabled": true,
      "maxBonus": 0.5,
      "ratioForMax": 0.5,
      "earnsEmissions": false,
      "depositFeePct": 1,
      "withdrawFeePct": 1,
      "cooldown": "sameAsWithdraw",
      "affectsStreak": false,
      "affectsHeatAge": false
    },
    "autoStoke": {
      "enabled": true,
      "defaultOn": false,
      "tip": {
        "minPct": 0.1,
        "defaultPct": 0.5,
        "maxPct": 1
      },
      "minInterval": {
        "minHours": 24,
        "defaultHours": 168
      },
      "minSize": "100"
    },
    "casting": {
      "enabled": true,
      "lpSharePct": 25,
      "quoteSource": "matchReserve",
      "fallback": "liquidEmber",
      "autoStake": true,
      "castLot": "sourceLot",
      "entersAs": "sourceLotAge",
      "incompatibleCollateral": "liquid",
      "matchedLpOwnership": "user"
    },
    "pyre": {
      "enabled": true,
      "tiers": [
        {
          "key": "cinder",
          "name": "Cinder",
          "burnEmber": "250",
          "heatBoost": 0.05,
          "art": "pyre-cinder.svg"
        },
        {
          "key": "wildfire",
          "name": "Wildfire",
          "burnEmber": "1250",
          "heatBoost": 0.05,
          "art": "pyre-wildfire.svg"
        },
        {
          "key": "conflagration",
          "name": "Conflagration",
          "burnEmber": "6250",
          "heatBoost": 0.05,
          "art": "pyre-conflagration.svg"
        }
      ],
      "maxBoost": 0.15,
      "soulbound": true
    },
    "convictionTracks": {
      "enabled": true,
      "tracks": [
        {
          "days": 30,
          "bonus": 0.15,
          "name": "Ember"
        },
        {
          "days": 90,
          "bonus": 0.25,
          "name": "Forge"
        },
        {
          "days": 180,
          "bonus": 0.35,
          "name": "Kiln"
        },
        {
          "days": 365,
          "bonus": 0.5,
          "name": "Eternal"
        }
      ],
      "vestAtTermEnd": true,
      "bucketCap": {
        "enabled": true,
        "capToSealBonusOfHeatShare": true,
        "unallocatedFlowsTo": "heatPool"
      },
      "escrow": {
        "enabled": true,
        "payout": "capstone"
      },
      "forfeitRouting": {
        "burnPct": 50,
        "matchReservePct": 25,
        "sealedPotPct": 25
      },
      "keystone": {
        "walletRelic": {
          "enabled": true,
          "key": "keystone",
          "soulbound": true
        },
        "deedScar": {
          "enabled": true
        }
      }
    },
    "deeds": {
      "enabled": true,
      "heatCarryPct": 80,
      "marketFeePct": 1,
      "feeRouting": {
        "burnPct": 50,
        "liquidityPct": 50
      },
      "marketOnlyTransfers": true,
      "blockListingWithPending": true,
      "saleMode": "auction",
      "auctionHours": 24,
      "antiSnipe": {
        "windowMinutes": 5,
        "extensionMinutes": 5,
        "maxTotalExtensionMinutes": 30
      }
    },
    "referrals": {
      "enabled": false,
      "sharePct": 3,
      "refereeMinRelic": "spark",
      "referrerMinRelic": "flame"
    },
    "caps": {
      "maxTotalMultiplier": 4.15
    },
    "relics": [
      {
        "key": "spark",
        "days": 7,
        "heatBump": 0.1,
        "perks": {
          "claimCooldownSeconds": 72000
        },
        "art": "spark.svg"
      },
      {
        "key": "flame",
        "days": 30,
        "heatBump": 0.1,
        "perks": {
          "claimCooldownSeconds": 57600,
          "ashfallEligible": true
        },
        "art": "flame.svg"
      },
      {
        "key": "blaze",
        "days": 90,
        "heatBump": 0.1,
        "perks": {
          "tap": {
            "maxPct": 10,
            "everyDays": 90
          }
        },
        "art": "blaze.svg"
      },
      {
        "key": "inferno",
        "days": 180,
        "heatBump": 0.1,
        "perks": {
          "claimCooldownSeconds": 43200,
          "kindlingPriority": true
        },
        "art": "inferno.svg"
      },
      {
        "key": "eternal",
        "days": 365,
        "heatBump": 0.1,
        "perks": {
          "tap": {
            "maxPct": 25,
            "everyDays": 90
          },
          "governanceWeight": 2,
          "feeRebatePct": 25
        },
        "art": "eternal.svg"
      },
      {
        "key": "bedrock",
        "days": 730,
        "heatBump": 0,
        "perks": {
          "tap": {
            "maxPct": 25,
            "everyDays": 60
          },
          "governanceWeight": 3,
          "feeRebatePct": 50
        },
        "art": "bedrock.svg"
      }
    ],
    "badges": {
      "standard": {
        "evm": "erc721-locked",
        "svm": "metaplex-core-frozen"
      },
      "metadata": "onchain-svg",
      "revokeOnReset": false
    },
    "withdrawResetsStreak": true,
    "cancelReturnsAsFreshLot": false,
    "emergencyExit": {
      "enabled": true,
      "feePct": 8,
      "routing": {
        "burnPct": 50,
        "liquidityPct": 25,
        "stakersPct": 25
      },
      "forfeitsAshfall": true
    },
    "minStakeLp": "0.0001",
    "pools": [
      {
        "id": "ember-usdc-lp",
        "name": "Blast Furnace",
        "stakeToken": "EMBER/USDC",
        "stakeKind": "lp",
        "allocPoints": 1000,
        "ashAllocPoints": 500,
        "withdrawCooldownHours": 72
      },
      {
        "id": "ember-weth-lp",
        "name": "Smelter",
        "stakeToken": "EMBER/WETH",
        "stakeKind": "lp",
        "allocPoints": 400,
        "ashAllocPoints": 200,
        "withdrawCooldownHours": 72
      },
      {
        "id": "ember-single",
        "name": "Ember Vault",
        "stakeToken": "EMBER",
        "stakeKind": "single",
        "allocPoints": 400,
        "ashAllocPoints": 300,
        "withdrawCooldownHours": 72
      },
      {
        "id": "usdc-single",
        "name": "Cold Storage",
        "stakeToken": "USDC",
        "stakeKind": "single",
        "allocPoints": 200,
        "ashAllocPoints": 0,
        "withdrawCooldownHours": 72
      }
    ]
  },
  "cooldowns": {
    "withdraw": {
      "seconds": 259200,
      "tiers": [
        {
          "maxWithdrawPct": 10,
          "seconds": 21600
        },
        {
          "maxWithdrawPct": 25,
          "seconds": 43200
        },
        {
          "maxWithdrawPct": 50,
          "seconds": 86400
        },
        {
          "maxWithdrawPct": 75,
          "seconds": 172800
        },
        {
          "maxWithdrawPct": 100,
          "seconds": 259200
        }
      ],
      "executionWindowSeconds": 86400,
      "earnsWhileCooling": false,
      "onCancelOrLapse": "resumeFrozen"
    },
    "claim": {
      "seconds": 86400,
      "snapshotAtRequest": true
    },
    "compound": {
      "seconds": 0
    }
  },
  "emissions": {
    "controllerChain": "ethereum",
    "epochSeconds": 86400,
    "split": {
      "flatPct": 30,
      "heatPct": 70
    },
    "base": {
      "startPerDay": "21600",
      "shape": "halfLife",
      "halfLifeDays": 365,
      "floorPerDay": "1000"
    },
    "supplyCeiling": {
      "hardCap": "21000000",
      "mode": "liveSupply"
    },
    "convictionBucketPct": 10,
    "ashfall": {
      "enabled": true,
      "recycleRates": {
        "protocolBurns": 50,
        "pyreBurns": 25,
        "unsolicited": 0
      },
      "lagEpochs": 1,
      "minRelic": "flame",
      "distributionWeight": "heatSquared",
      "rolloverUndistributed": true,
      "sources": [
        "forgeFees",
        "swapFees",
        "emergencyExit",
        "manualBurns"
      ]
    },
    "gauge": {
      "enabled": false,
      "weight": "heatWeightedStake",
      "reportIntervalSeconds": 86400,
      "maxCreditPerEpochPct": 60
    }
  },
  "fees": {
    "vent": {
      "burnPct": 40,
      "liquidityPct": 40,
      "hearthPct": 10,
      "treasuryPct": 10
    },
    "genesisDeposit": {
      "treasuryPct": 100
    },
    "burnLane": {
      "method": "unwindAndBuyback",
      "twapSeconds": 1800,
      "maxPriceImpactBps": 300,
      "allowlistedRoutersOnly": true,
      "deferIfUnsafe": true,
      "maxDeferralHours": 72,
      "avgPriceBandBps": 200,
      "slippageCapBps": 100,
      "maxChunkPctOfReserve": 0.5
    },
    "feeVault": {
      "enabled": true,
      "minBatchUsd": 5000,
      "maxWaitHours": 24
    },
    "liquidityLane": {
      "method": "matchReserve",
      "matchReserve": {
        "idleEpochsBeforeAutoPair": 7,
        "burnMatchedLp": true,
        "idlePairEmberSource": "treasuryMatchSeed"
      },
      "permanentMustBeFullRange": true
    },
    "tokenFees": {
      "burnPct": 100
    },
    "swap": {
      "buy": {
        "totalBps": 25,
        "lpBps": 20,
        "burnBps": 2.5,
        "liquidityBps": 2.5,
        "treasuryBps": 0
      },
      "sell": {
        "totalBps": 35,
        "lpBps": 20,
        "burnBps": 5,
        "liquidityBps": 5,
        "quoteYieldBps": 5,
        "treasuryBps": 0
      },
      "waiveProtocolShareOnCompound": true
    },
    "quoteYield": {
      "enabled": true,
      "eligibility": "ashfallEligible",
      "asset": "quoteAsset"
    },
    "burnAddress": {
      "evm": "0x000000000000000000000000000000000000dEaD",
      "svm": "1nc1nerator11111111111111111111111111111111"
    }
  },
  "swap": {
    "amm": "protocol-cpmm",
    "listLpAsAsset": true,
    "tokenListOrder": [
      "EMBER",
      "LP",
      "ASH",
      "WETH",
      "USDC",
      "WBTC"
    ],
    "zap": {
      "defaultSlippageBps": 50,
      "maxSlippageBps": 300,
      "stakeAfterZap": "offer"
    },
    "showPriceImpact": true,
    "showLpPrice": true,
    "showTwentyFourHourChange": true
  },
  "treasury": {
    "addresses": {
      "ethereum": null,
      "bsc": null,
      "base": null,
      "arbitrum": null,
      "solana": null
    },
    "controller": {
      "type": "safe-multisig",
      "threshold": 3,
      "signers": []
    },
    "timelockSeconds": 172800,
    "policy": {
      "polSeedingPct": 30,
      "matchReserveSeedPct": 30,
      "incentivesPct": 20,
      "buybackPct": 20,
      "reportOnChain": true
    }
  },
  "security": {
    "feeCeilings": {
      "depositPct": 5,
      "withdrawPct": 5,
      "genesisPct": 5,
      "emergencyPct": 10,
      "swapBps": 100,
      "deedSalePct": 5
    },
    "paramTimelockSeconds": 172800,
    "pausable": {
      "deposits": true,
      "swaps": true,
      "withdrawalsNever": true
    },
    "upgradeable": {
      "core": false,
      "periphery": true
    },
    "guardian": {
      "ethereum": null,
      "bsc": null,
      "base": null,
      "arbitrum": null,
      "solana": null
    },
    "audits": [],
    "bugBountyUrl": "https://immunefi.com/bounty/furnace"
  },
  "ui": {
    "timeline": {
      "show": true,
      "showRelicMarkers": true,
      "showNextBumpCountdown": true,
      "showHeatVsStreakNote": true,
      "pendingWithdrawAsRedSegment": true,
      "horizonDays": 365
    },
    "countdown": {
      "style": "ring",
      "showInNav": true,
      "browserNotification": true
    },
    "readyButtonColor": "#22c55e",
    "positionCard": {
      "showImpermanentLoss": true
    },
    "locale": "en-US",
    "numberFormat": {
      "compact": true,
      "aprDecimals": 1
    },
    "charts": {
      "emissionCurve": true,
      "heatCurve": true,
      "supplyChart": true
    }
  },
  "fissures": {
    "enabled": false,
    "defaultAllocation": "250000",
    "priorityWindowHours": 24,
    "priorityMinRelic": "inferno",
    "feePct": 3,
    "lpSplit": {
      "stakersPct": 90,
      "burnPct": 10
    }
  },
  "governance": {
    "model": "timelock-then-two-chambers",
    "chambers": {
      "hearth": {
        "electorate": "ASH holders",
        "scope": "Hearth, ASH, fee routing"
      },
      "forge": {
        "electorate": "liquidity \u00d7 Heat",
        "scope": "Forge, staking, cooldowns"
      }
    },
    "dualChamberRequired": [
      "treasuryPolicy",
      "newChains",
      "flowFeeBands",
      "emissionCurves",
      "newContracts"
    ],
    "relicVoteMultiplier": {
      "eternal": 2,
      "bedrock": 3
    },
    "neverAllowed": [
      "mintOutsideMantle",
      "pauseWithdrawals",
      "touchUserBalances",
      "redirectVent"
    ]
  },
  "assets": {
    "ethereum": {
      "EMBER": {
        "kind": "protocol",
        "contract": "EmberToken"
      },
      "ASH": {
        "kind": "protocol",
        "contract": "AshToken"
      },
      "EMBER/USDC": {
        "kind": "protocol",
        "contract": "BlastPool"
      },
      "EMBER/WETH": {
        "kind": "protocol",
        "contract": "SmelterPool"
      },
      "WETH": {
        "kind": "external",
        "address": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "decimals": 18
      },
      "USDC": {
        "kind": "external",
        "address": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        "decimals": 6
      },
      "WBTC": {
        "kind": "external",
        "address": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
        "decimals": 8
      },
      "WETH/USDC": {
        "kind": "external",
        "address": null,
        "decimals": 18
      }
    }
  },
  "execution": {
    "status": "design-canonical-not-deployed",
    "activation": {
      "initialChain": "ethereum",
      "bridgeEnabled": false,
      "satellitesRequireSeparateRelease": true
    },
    "casting": {
      "eligibleRewardClasses": [
        "ordinaryBase"
      ],
      "denominator": "postConvictionOrdinaryBase",
      "singleTokenPolicy": "liquid",
      "requiresActiveSourceLot": true,
      "explicitZapConsent": true
    },
    "matching": {
      "ownership": "user",
      "allocation": "epochProRataByEligibleBaseReward",
      "automaticCastPriority": true,
      "optionalStokeUsesOnlyRemainder": true,
      "claimWindowEpochs": 7,
      "oneUsePerRewardUnit": true,
      "expiry": "releaseQuoteOnlyKeepUserReward",
      "idlePairUsesOnlyUnreservedInventory": true,
      "idlePairEmber": "treasuryMatchSeed"
    },
    "settlement": {
      "weightBasis": "timeIntegratedPerLot",
      "budgetAccrual": "onlyWhilePoolHasActiveStake",
      "heatIntegral": "cappedSqrtAntiderivative",
      "multiplierScale": "1000000000000000000000000000",
      "maxLotsPerPage": 32,
      "aggregateAuthority": "onchainCheckpoints",
      "residue": "retainTaggedUnallocated",
      "exitsDependOnSettlement": false
    },
    "withdrawals": {
      "aggregation": "frozenReferenceCumulativeRequests",
      "planHorizonSeconds": 259200,
      "cancelConsumesPlanQuota": true,
      "newRequestsNeverDelayMaturedTickets": true,
      "freeze": "requestedSlice",
      "lapse": "resumeFrozen",
      "exitAsset": "inKind",
      "exitRequiresOracle": false
    },
    "seals": {
      "membership": "sealedCohortsOnly",
      "topupsJoinExistingSeal": false,
      "pendingCooling": "pauseSealAccrualAndExtendEnd",
      "tapBeforeMaturity": "forfeitUnvestedBonus",
      "walletKeystoneRequiresWholeTermOwnership": true
    },
    "kindling": {
      "feeCustody": "dedicatedImmutableEscrow",
      "successRelease": "afterAtomicPoolInitialization",
      "failureRefundAsset": "depositedQuote",
      "maxSettlementDelaySeconds": 259200,
      "cutoff": "rejectNewDepositsAtDeadline",
      "cancelUntilSettlement": "netPrincipalNowFeeIfLaunchFails",
      "treasuryFallback": "separateFundedEvent",
      "closeBountyBasis": "acceptedGrossQuote"
    },
    "ashfall": {
      "lotEligibility": "actualParticipationAgeAndActiveStreak",
      "minimumParticipationDays": 30,
      "founderFloorCountsAsParticipation": false,
      "burnReceipt": "uniqueAuthenticatedEconomicBurn",
      "transportBurnCredit": false,
      "voluntaryRecapture": "possibleAndDisclosed"
    },
    "vent": {
      "aggregateWindowSeconds": 1800,
      "aggregateMaxReserveBps": 50,
      "reserveReference": "fixedWindowStart",
      "atDeferralLimit": "alertNeverWeakenGuards",
      "principalExitRequiresVent": false
    },
    "deeds": {
      "unclaimedRewards": "goWithDeed",
      "sellerMutationsWhileListed": "cancelListingFirst",
      "cancellation": "allowedBeforeSettlementWithPullRefunds",
      "noInstantBuyout": true,
      "receiverFailure": "claimDeliveryCannotBlockSellerProceeds"
    },
    "hearth": {
      "feeScope": "chainLocalFundedLiabilities",
      "crossChainFeeAggregation": false
    },
    "release": {
      "safeThreshold": 3,
      "safeOwnersRequired": 5,
      "minimumIndependentAudits": 2,
      "sourceHashRequired": true,
      "bytecodeHashRequired": true,
      "initializerHashRequired": true,
      "chainStateVerificationRequired": true
    }
  }
};
export default furnaceConfig;
export type Config = FurnaceConfig;

/** Reject invalid numeric domains at exported helper boundaries. */
function requireNonnegativeFinite(label: string, values: readonly number[]): void {
  if (values.some((value) => !Number.isFinite(value) || value < 0)) {
    throw new Error(`[config] ${label}: inputs must be finite and nonnegative`);
  }
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
 * Heat age after withdrawing `fraction` (0..1) of the LP. Delegates to
 * cooledAgeAfterWithdrawal: the single proportional-cooling implementation.
 * (The old uncapped variant is retired — two helpers with different age
 * policies for the same input was an interface inconsistency.)
 */
export function heatAgeAfterWithdrawal(ageDays: number, fraction: number, c: ForgeConfig = furnaceConfig.forge): number {
  return cooledAgeAfterWithdrawal(ageDays, fraction, c);
}

/** Display-only blended age. Never use this number to replace per-lot financial accounting. */
export function heatAgeAfterDeposit(oldAge: number, oldStake: number, newStake: number): number {
  const total = oldStake + newStake;
  if (total <= 0) return 0;
  return (oldAge * oldStake) / total; // new money enters at age 0
}

/**
 * A position's share of one epoch's base emission across both buckets.
 * `totalStake` / `totalWeighted` are the pool-wide sums of stake and stake × multiplier.
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

/**
 * A sealed position's Conviction-bucket payout cap for one epoch.
 * Additive bonus b on ordinary Heat h is worth (b/h) × P — the bonus's
 * marginal value in the Heat pool — computed non-circularly as:
 *   cap = heatBudget × stake × sealBonus / totalHeatWeightedStake
 * `heatBudget` is the pre-return Heat slice (63% of the epoch); pass the
 * ordinary (pre-seal) heat-weighted stake sum. Returns 0 when unsealed.
 */
export function convictionCap(
  stake: number,
  sealBonus: number,
  totalHeatWeightedStake: number,
  epochMint: number,
  e: EmissionsConfig = furnaceConfig.emissions,
): number {
  requireNonnegativeFinite('convictionCap', [stake, sealBonus, totalHeatWeightedStake, epochMint]);
  if (sealBonus <= 0 || totalHeatWeightedStake <= 0 || epochMint <= 0) return 0;
  const bucket = e.convictionBucketPct / 100;
  const heatBudget = epochMint * (1 - bucket) * (e.split.heatPct / 100);
  return (heatBudget * stake * sealBonus) / totalHeatWeightedStake;
}

/**
 * Effective epoch split after the Conviction bucket. The ordinary budget is
 * 27% flat / 63% Heat / 10% bucket; whatever the per-position caps hold back
 * — and the whole bucket when nobody is sealed — returns to the Heat pool.
 * With an empty bucket the effective split is 27% flat / 73% Heat (not 30/70).
 */
export function epochSplit(
  epochMint: number,
  bucketUnallocated: number,
  e: EmissionsConfig = furnaceConfig.emissions,
): { flat: number; heat: number; bucket: number } {
  requireNonnegativeFinite('epochSplit', [epochMint, bucketUnallocated]);
  const bucket = epochMint * (e.convictionBucketPct / 100);
  if (bucketUnallocated > bucket) {
    throw new Error('[config] epochSplit: unallocated amount exceeds the Conviction bucket');
  }
  const ordinary = epochMint - bucket;
  const flat = ordinary * (e.split.flatPct / 100);
  const heat = ordinary * (e.split.heatPct / 100) + Math.min(bucketUnallocated, bucket);
  return { flat, heat, bucket: bucket - Math.min(bucketUnallocated, bucket) };
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
  return totalMintForEpoch(targetEmission, 0, totalSupply, e).base;
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
  if (!Number.isFinite(baseTarget) || !Number.isFinite(ashfallTarget) || !Number.isFinite(totalSupply)) {
    throw new Error('[config] totalMintForEpoch: non-finite input');
  }
  if (baseTarget < 0 || ashfallTarget < 0 || totalSupply < 0) {
    throw new Error('[config] totalMintForEpoch: negative input — mint targets and supply must be ≥ 0');
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
 * Heat age the BUYER of a Deed inherits. The position's Streak resets to 0 and
 * badges stay with the seller; only a haircut share of the age moves.
 * Financial age is capped at the Heat ramp BEFORE the haircut: an 80% carry
 * on a 730-day lot yields 292 days, not 584. (Streak is chronological and is
 * never capped — capping financial age does not shorten anyone's Streak.)
 */
export function deedHeatAge(sellerAgeDays: number, c: ForgeConfig = furnaceConfig.forge): number {
  if (!c.deeds.enabled) return 0;
  const capped = Math.min(Math.max(sellerAgeDays, 0), c.heat.rampDays);
  return capped * (c.deeds.heatCarryPct / 100);
}

/**
 * Maximum nominal allocation coefficient (not an APR or subsidy-value ceiling):
 * Heat at the ramp cap + Capstone max + Pyre max + best track bonus.
 * check:config asserts this equals forge.caps.maxTotalMultiplier.
 */
export function maxTotalMultiplier(c: ForgeConfig = furnaceConfig.forge): number {
  const trackBest = Math.max(0, ...c.convictionTracks.tracks.map((t) => t.bonus));
  return heatMultiplier(c.heat.rampDays, c) + c.capstone.maxBonus + c.pyre.maxBoost + trackBest;
}


/** Build-time sanity checks; `pnpm check:config` calls this. */

/** Compatibility entrypoint: deployment diagnostics are never hidden by default. */
export function validateConfig(c: FurnaceConfig = furnaceConfig): string[] {
  return validateResolvedConfig(c, 'deployment').map(d => `[${d.code}] ${d.path}: ${d.message}`);
}
export function validateConfigDetailed(c: FurnaceConfig = furnaceConfig, stage: CheckStage = 'deployment'): Diagnostic[] {
  return validateResolvedConfig(c, stage);
}
export function assetAddress(symbol: string, chain: ChainKey, c: FurnaceConfig = furnaceConfig): Address {
  const binding = c.assets[chain]?.[symbol];
  if (!binding) throw new Error(`Unconfigured asset ${symbol} on ${chain}`);
  if (binding.kind === 'protocol') return contractAddress(binding.contract, c);
  if (!binding.address) throw new Error(`Unverified external asset ${symbol} on ${chain}`);
  return binding.address;
}
/** Pool/category-aware allocation display. Uncast amounts retain their existing payout ledger; uncast is not an escrow unlock. A subsidy reservation is still required. */
export function castForPool(poolId: string, rewardClass: string, reward: number, reserveValue: number, c: FurnaceConfig = furnaceConfig): { uncast: number; cast: number } {
  requireNonnegativeFinite('castForPool', [reward, reserveValue]);
  const pool = c.forge.pools.find(p => p.id === poolId);
  if (!pool) throw new Error(`Unknown pool ${poolId}`);
  if (pool.stakeKind !== 'lp' || !c.execution.casting.eligibleRewardClasses.includes(rewardClass as 'ordinaryBase')) return { uncast: reward, cast: 0 };
  const quote = castEmissionSplit(reward, reserveValue, c.forge);
  return { uncast: quote.liquid, cast: quote.cast };
}
