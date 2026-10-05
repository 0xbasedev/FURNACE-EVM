/**
 * FURNACE v5.5.0 - canonical design/configuration consolidation.
 * This file supersedes the v5.4 configuration for subsequent implementation.
 * No contract deployment or audit is implied. Active launch: Ethereum only.
 * Amounts are human-unit strings; display helpers use numbers. Monetary
 * reference settlement is in accounting.ts and uses integer smallest units.
 * Presentation, configuration data, source, and deployment commitments differ.
 * See DECISIONS.md for the decisions made under delegated design authority.
 */
import { type CheckStage, type Diagnostic } from './validation.js';
export type AssetBinding = {
    kind: 'protocol';
    contract: ContractName;
} | {
    kind: 'external';
    address: Address | null;
    decimals: number;
};
export type ExecutionPolicy = {
    "status": "design-canonical-not-deployed";
    "activation": {
        "initialChain": "ethereum";
        "bridgeEnabled": false;
        "satellitesRequireSeparateRelease": true;
    };
    "casting": {
        "eligibleRewardClasses": [
            "ordinaryBase"
        ];
        "denominator": "postConvictionOrdinaryBase";
        "singleTokenPolicy": "liquid";
        "requiresActiveSourceLot": true;
        "explicitZapConsent": true;
    };
    "matching": {
        "ownership": "user";
        "allocation": "epochProRataByEligibleBaseReward";
        "automaticCastPriority": true;
        "optionalStokeUsesOnlyRemainder": true;
        "claimWindowEpochs": 7;
        "oneUsePerRewardUnit": true;
        "expiry": "releaseQuoteOnlyKeepUserReward";
        "idlePairUsesOnlyUnreservedInventory": true;
        "idlePairEmber": "treasuryMatchSeed";
    };
    "settlement": {
        "weightBasis": "timeIntegratedPerLot";
        "budgetAccrual": "onlyWhilePoolHasActiveStake";
        "heatIntegral": "cappedSqrtAntiderivative";
        "multiplierScale": "1000000000000000000000000000";
        "maxLotsPerPage": 32;
        "aggregateAuthority": "onchainCheckpoints";
        "residue": "retainTaggedUnallocated";
        "exitsDependOnSettlement": false;
    };
    "withdrawals": {
        "aggregation": "frozenReferenceCumulativeRequests";
        "planHorizonSeconds": 259200;
        "cancelConsumesPlanQuota": true;
        "newRequestsNeverDelayMaturedTickets": true;
        "freeze": "requestedSlice";
        "lapse": "resumeFrozen";
        "exitAsset": "inKind";
        "exitRequiresOracle": false;
    };
    "seals": {
        "membership": "sealedCohortsOnly";
        "topupsJoinExistingSeal": false;
        "pendingCooling": "pauseSealAccrualAndExtendEnd";
        "tapBeforeMaturity": "forfeitUnvestedBonus";
        "walletKeystoneRequiresWholeTermOwnership": true;
    };
    "kindling": {
        "feeCustody": "dedicatedImmutableEscrow";
        "successRelease": "afterAtomicPoolInitialization";
        "failureRefundAsset": "depositedQuote";
        "maxSettlementDelaySeconds": 259200;
        "cutoff": "rejectNewDepositsAtDeadline";
        "cancelUntilSettlement": "netPrincipalNowFeeIfLaunchFails";
        "treasuryFallback": "separateFundedEvent";
        "closeBountyBasis": "acceptedGrossQuote";
    };
    "ashfall": {
        "lotEligibility": "actualParticipationAgeAndActiveStreak";
        "minimumParticipationDays": 30;
        "founderFloorCountsAsParticipation": false;
        "burnReceipt": "uniqueAuthenticatedEconomicBurn";
        "transportBurnCredit": false;
        "voluntaryRecapture": "possibleAndDisclosed";
    };
    "vent": {
        "aggregateWindowSeconds": 1800;
        "aggregateMaxReserveBps": 50;
        "reserveReference": "fixedWindowStart";
        "atDeferralLimit": "alertNeverWeakenGuards";
        "principalExitRequiresVent": false;
    };
    "deeds": {
        "unclaimedRewards": "goWithDeed";
        "sellerMutationsWhileListed": "cancelListingFirst";
        "cancellation": "allowedBeforeSettlementWithPullRefunds";
        "noInstantBuyout": true;
        "receiverFailure": "claimDeliveryCannotBlockSellerProceeds";
    };
    "hearth": {
        "feeScope": "chainLocalFundedLiabilities";
        "crossChainFeeAggregation": false;
    };
    "release": {
        "safeThreshold": 3;
        "safeOwnersRequired": 5;
        "minimumIndependentAudits": 2;
        "sourceHashRequired": true;
        "bytecodeHashRequired": true;
        "initializerHashRequired": true;
        "chainStateVerificationRequired": true;
    };
};
export type Pct = number;
export type Bps = number;
export type Seconds = number;
export type Days = number;
export type Hours = number;
export type Amount = string;
export type EvmAddress = `0x${string}`;
export type SolanaAddress = string;
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
        fonts: {
            display: string;
            body: string;
            mono: string;
        };
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
    cooldowns: {
        withdraw: string;
        claim: string;
        compound: string;
        emergency: string;
    };
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
        eid: number;
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
    keypair: string;
    address: SolanaAddress | null;
    description: string;
}
export interface DeploymentConfig {
    evm: {
        strategy: 'create3';
        factory: EvmAddress;
        deployer: EvmAddress;
        saltGuard: 'msgSender';
        argumentFreeConstructors: boolean;
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
        upgradeAuthority: SolanaAddress;
        contracts: Record<string, SolanaIdEntry>;
    };
}
export interface TokenConfig {
    name: string;
    symbol: string;
    decimals: {
        evm: number;
        svm: number;
    };
    standard: 'lz-oft-v2' | 'single-chain-erc20';
    oft: {
        sharedDecimals: number;
        homeChain: ChainKey;
        enforcedGas: {
            send: number;
            compose: number;
        };
        rateLimit: {
            amountPerWindow: Amount;
            windowSeconds: Seconds;
        };
    };
    allocations: {
        kindlingPool: Amount;
        treasury: {
            amount: Amount;
            cliffDays: Days;
            vestingDays: Days;
        };
        team: {
            amount: Amount;
            cliffDays: Days;
            vestingDays: Days;
            recipients: readonly {
                address: Address;
                sharePct: Pct;
            }[];
        };
    };
    maxSupply: Amount | null;
}
export interface ShareTokenConfig {
    name: string;
    symbol: string;
    decimals: {
        evm: number;
        svm: number;
    };
    standard: 'lz-oft-v2' | 'single-chain-erc20';
    maxSupply: Amount;
    /**
     * The full ASH allocation tree. The validator sums EVERY leaf recursively
     * and requires exactly 70_000. Launch = Ignition rewards + Kindling bonus.
     */
    allocations: {
        launch: {
            ignition: Amount;
            kindling: Amount;
        };
        forge: Amount;
    };
    forgeTrickleDays: Days;
}
export interface RelicConfig {
    key: RelicKey;
    days: Days;
    heatBump: number;
    perks: {
        claimCooldownSeconds?: Seconds;
        ashfallEligible?: boolean;
        tap?: {
            maxPct: Pct;
            everyDays: Days;
        };
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
    feeRouting: {
        burnPct: Pct;
        liquidityPct: Pct;
    };
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
        windowMinutes: number;
        extensionMinutes: number;
        maxTotalExtensionMinutes: number;
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
    refereeMinRelic: RelicKey;
    referrerMinRelic: RelicKey;
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
    priorityMinRelic: RelicKey;
    feePct: Pct;
    lpSplit: {
        stakersPct: Pct;
        burnPct: Pct;
    };
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
        hearth: {
            electorate: 'ASH holders';
            scope: 'Hearth, ASH, fee routing';
        };
        forge: {
            electorate: 'liquidity × Heat';
            scope: 'Forge, staking, cooldowns';
        };
    };
    /**
     * Changes that require BOTH chambers: Treasury policy, new chains, Flow
     * fee bands, emission curves, new contracts.
     */
    dualChamberRequired: readonly ('treasuryPolicy' | 'newChains' | 'flowFeeBands' | 'emissionCurves' | 'newContracts')[];
    relicVoteMultiplier: Record<RelicKey, number>;
    /**
     * Above BOTH chambers — no vote, no chamber, no multisig can authorize
     * these. Ever.
     */
    neverAllowed: readonly ('mintOutsideMantle' | 'pauseWithdrawals' | 'touchUserBalances' | 'redirectVent')[];
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
    escrow: {
        enabled: true;
        payout: 'capstone';
    };
    /**
     * Early exit forfeits the ESCROW (never principal): 50% burn lane, 25%
     * match reserve, 25% Sealed pot streamed to positions still inside term.
     */
    forfeitRouting: {
        burnPct: Pct;
        matchReservePct: Pct;
        sealedPotPct: Pct;
    };
    /**
     * Keystone, dual ownership. The wallet earns a soulbound Keystone Relic —
     * proof the PERSON completed the term, never transfers. The Deed gets a
     * Seal Scar in permanent metadata — proof the CAPITAL completed one,
     * always travels with the Deed on sale.
     */
    keystone: {
        walletRelic: {
            enabled: boolean;
            key: string;
            soulbound: true;
        };
        deedScar: {
            enabled: boolean;
        };
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
        rampBonus: number;
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
        maxBonus: number;
        ratioForMax: number;
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
        tip: {
            minPct: Pct;
            defaultPct: Pct;
            maxPct: Pct;
        };
        /** Shortest gap between keeper stokes on one position. */
        minInterval: {
            minHours: Hours;
            defaultHours: Hours;
        };
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
    caps: {
        maxTotalMultiplier: number;
    };
    relics: readonly RelicConfig[];
    badges: {
        standard: {
            evm: 'erc721-locked';
            svm: 'metaplex-core-frozen';
        };
        metadata: 'onchain-svg' | 'ipfs';
        baseUri?: string;
        revokeOnReset: boolean;
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
        routing: {
            burnPct: Pct;
            liquidityPct: Pct;
            stakersPct: Pct;
        };
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
        tiers: readonly {
            maxWithdrawPct: Pct;
            seconds: Seconds;
        }[];
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
    compound: {
        seconds: 0;
    };
}
export interface EmissionsConfig {
    controllerChain: ChainKey;
    epochSeconds: Seconds;
    /** Each epoch's base emission: flat by stake (newcomer floor) + by stake × Heat. */
    split: {
        flatPct: Pct;
        heatPct: Pct;
    };
    base: {
        startPerDay: Amount;
        shape: 'halfLife' | 'linear' | 'steps';
        halfLifeDays: Days;
        floorPerDay: Amount;
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
        hardCap: Amount;
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
            protocolBurns: Pct;
            pyreBurns: Pct;
            unsolicited: Pct;
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
    vent: {
        burnPct: Pct;
        liquidityPct: Pct;
        hearthPct: Pct;
        treasuryPct: Pct;
    };
    genesisDeposit: {
        treasuryPct: Pct;
    };
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
    tokenFees: {
        burnPct: Pct;
    };
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
    burnAddress: {
        evm: EvmAddress;
        svm: SolanaAddress;
    };
}
export interface SwapConfig {
    amm: 'protocol-cpmm';
    listLpAsAsset: boolean;
    tokenListOrder: readonly string[];
    zap: {
        defaultSlippageBps: Bps;
        maxSlippageBps: Bps;
        stakeAfterZap: 'offer' | 'always' | 'never';
    };
    showPriceImpact: boolean;
    showLpPrice: boolean;
    showTwentyFourHourChange: boolean;
}
export interface TreasuryConfig {
    addresses: Record<ChainKey, Address | null>;
    controller: {
        type: 'safe-multisig' | 'squads';
        threshold: number;
        signers: readonly Address[];
    };
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
    feeCeilings: {
        depositPct: Pct;
        withdrawPct: Pct;
        genesisPct: Pct;
        emergencyPct: Pct;
        swapBps: Bps;
        deedSalePct: Pct;
    };
    paramTimelockSeconds: Seconds;
    pausable: {
        deposits: boolean;
        swaps: boolean;
        withdrawalsNever: true;
    };
    upgradeable: {
        core: boolean;
        periphery: boolean;
    };
    guardian: Record<ChainKey, Address | null>;
    audits: readonly {
        firm: string;
        reportUrl: string;
        date: string;
    }[];
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
    positionCard: {
        showImpermanentLoss: boolean;
    };
    countdown: {
        style: 'flip' | 'ring' | 'digits';
        showInNav: boolean;
        browserNotification: boolean;
    };
    readyButtonColor: string;
    locale: string;
    numberFormat: {
        compact: boolean;
        aprDecimals: number;
    };
    charts: {
        emissionCurve: boolean;
        heatCurve: boolean;
        supplyChart: boolean;
    };
}
export interface IgnitionConfig {
    name: string;
    address: EvmAddress;
    durationHours: Hours;
    minDurationHours: Hours;
    maxDurationHours: Hours;
    startTimestamp: number | null;
    depositFeePct: Pct;
    feeDestination: 'treasury';
    /**
     * Nothing is ever locked — not even in Ignition. Principal can be
     * withdrawn at any time during the window; the 3% genesis fee is not
     * refunded. (v5.2 locked it; the lock contradicted the protocol's
     * load-bearing invariant.)
     */
    withdrawDuringWindow: {
        enabled: true;
        refundFee: false;
    };
    exitWindowHours: Hours;
    exitFeePct: Pct;
    pools: readonly {
        id: string;
        stakeToken: string;
        weight: number;
        name: string;
    }[];
    rewards: {
        token: 'ASH';
        total: Amount;
        mode: 'per-second-pro-rata';
        vesting: 'none';
    };
    founderBadge: {
        enabled: boolean;
        key: string;
        phantomAgeBonusDays: Days;
    };
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
    earlyBird: {
        enabled: boolean;
        maxBonusPct: Pct;
        shape: 'linear' | 'exponential';
    };
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
    lpSplit: {
        depositorDeedsPct: Pct;
        burnPct: Pct;
    };
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
export declare const CREATEX_FACTORY: EvmAddress;
export declare const DEPLOYER: EvmAddress;
export declare const evmContracts: {
    readonly EmberToken: {
        readonly salt: "0x111111111111111111111111111111111111111100000000000000000001415e";
        readonly address: "0xf1e5b7820a8c6f6349a576db516142c8d341dcc4";
        readonly prefix: "F1E5";
        readonly description: "EMBER — LayerZero OFT protocol token";
    };
    readonly AshToken: {
        readonly salt: "0x11111111111111111111111111111111111111110000000000000000000014c3";
        readonly address: "0xa5e55c164036f63e9b6e6337c465eedead49fb5b";
        readonly prefix: "A5E5";
        readonly description: "ASH — LayerZero OFT share/governance token";
    };
    readonly FeeRouter: {
        readonly salt: "0x111111111111111111111111111111111111111100000000000000000000faf3";
        readonly address: "0xfee5356949802d661959360a5e4004e1d8c685a2";
        readonly prefix: "FEE5";
        readonly description: "FeeRouter — auto-routes fees to burn + liquidity";
    };
    readonly Forge: {
        readonly salt: "0x11111111111111111111111111111111111111110000000000000000000135c5";
        readonly address: "0xf09551c13e2ca9cbeed634452a1f37d89a25532d";
        readonly prefix: "F095";
        readonly description: "Forge — post-launch staking (all pools)";
    };
    readonly Ignition: {
        readonly salt: "0x11111111111111111111111111111111111111110000000000000000000035e7";
        readonly address: "0x19172ad5c06ccc86a6e2712d06500f1028cf185b";
        readonly prefix: "1917";
        readonly description: "Ignition — Genesis bootstrap staking";
    };
    readonly Kindling: {
        readonly salt: "0x1111111111111111111111111111111111111111000000000000000000005c57";
        readonly address: "0x5a1d6ee608bf6e94b53789824705427ea40f2746";
        readonly prefix: "5A1D";
        readonly description: "Kindling — liquidity bootstrap auction";
    };
    readonly Hearth: {
        readonly salt: "0x111111111111111111111111111111111111111100000000000000000004d0a0";
        readonly address: "0xea272470c2529afe408d13bf6057b72a1a8763ce";
        readonly prefix: "EA27";
        readonly description: "Hearth — ASH staking, fee share + governance";
    };
    readonly Relics: {
        readonly salt: "0x111111111111111111111111111111111111111100000000000000000001d233";
        readonly address: "0x2e1c923b32c214c4b7b2b8bd30daeb9f0a183dbd";
        readonly prefix: "2E1C";
        readonly description: "Relics — soulbound duration-milestone NFTs";
    };
    readonly Deeds: {
        readonly salt: "0x1111111111111111111111111111111111111111000000000000000000015534";
        readonly address: "0xdeed54948eab9875d89a77cc383714d6a5d7dc6d";
        readonly prefix: "DEED";
        readonly description: "Deeds — position NFTs + the Deed Market";
    };
    readonly Mantle: {
        readonly prefix: "BA5E";
        readonly salt: null;
        readonly address: null;
        readonly description: "Economic issuance ledger and epoch budget controller";
    };
    readonly BlastPool: {
        readonly prefix: "F001";
        readonly salt: null;
        readonly address: null;
        readonly description: "EMBER/USDC full-range constant-product pair";
    };
    readonly SmelterPool: {
        readonly prefix: "F002";
        readonly salt: null;
        readonly address: null;
        readonly description: "EMBER/WETH full-range constant-product pair";
    };
    readonly Flow: {
        readonly prefix: "F10A";
        readonly salt: null;
        readonly address: null;
        readonly description: "Protocol swap and zap entrypoint";
    };
    readonly GenesisFeeEscrow: {
        readonly prefix: "E5C0";
        readonly salt: null;
        readonly address: null;
        readonly description: "Non-spendable refundable Kindling/Fissure fees";
    };
    readonly TreasuryVesting: {
        readonly prefix: "7E57";
        readonly salt: null;
        readonly address: null;
        readonly description: "Cumulative exact treasury token vesting";
    };
    readonly Timelock: {
        readonly prefix: "71AE";
        readonly salt: null;
        readonly address: null;
        readonly description: "Governance execution delay controller";
    };
};
export declare const solanaIds: {
    readonly stakingProgram: {
        readonly keypair: "keys/staking-program.json";
        readonly address: "HVQT6MycoarDw9ktbZBv282HH8SttSR4ycvTeSTw9kKe";
        readonly description: "Furnace staking program (Forge + Ignition)";
    };
    readonly feeRouterProgram: {
        readonly keypair: "keys/fee-router-program.json";
        readonly address: "ECgH9KPnFW9GoM9fe6uVYrmaJpQMsacA8EiiSKwo3Egu";
        readonly description: "FeeRouter program (burn + POL builder)";
    };
    readonly emberMint: {
        readonly keypair: "keys/ember-mint.json";
        readonly address: "AtbnZK5DQibjpxkhynqq7617iuseoWaABytXN7Q3RnbD";
        readonly description: "EMBER SPL mint (9 decimals)";
    };
    readonly ashMint: {
        readonly keypair: "keys/ash-mint.json";
        readonly address: "7a2HrKABUqNEsPntziBaDMVMboQ6hThWJVFu9Zp3cAnW";
        readonly description: "ASH SPL mint (9 decimals)";
    };
    readonly relicsCollection: {
        readonly keypair: "keys/relics-collection.json";
        readonly address: "GgpFhkNfS4Y16gX746NNzWJup6yDcpCRHjw5NNVKFdCL";
        readonly description: "Relics Metaplex collection mint (soulbound)";
    };
};
export type ContractName = keyof typeof evmContracts;
export declare function contractAddress(name: ContractName, c?: FurnaceConfig): EvmAddress;
export declare const namePresets: {
    readonly furnace: NamesConfig;
    readonly tephra: NamesConfig;
};
export declare const furnaceConfig: FurnaceConfig;
export default furnaceConfig;
export type Config = FurnaceConfig;
/** Heat multiplier for a position of `ageDays`, including relic bumps. */
export declare function heatMultiplier(ageDays: number, c?: ForgeConfig): number;
/**
 * Milestone bumps belong to the LOT'S AGE, not to badges — computed from the
 * lot's Heat age against the milestone schedule, prorated linearly between
 * milestones so no withdrawal ever falls off a cliff. A 365-day lot sits at
 * 3.0× (2.5× curve + 0.5× bumps); a 135-day lot carries +0.35×. Cooling,
 * Deed transfer, and wallet reset all follow from this one rule: the bumps
 * cool with the age, transfer with the inherited age, and never attach to
 * new money until that money ages.
 */
export declare function milestoneBump(ageDays: number, c?: ForgeConfig): number;
/**
 * Proportional cooling, defined per lot. Executing a withdrawal of fraction
 * `f` (0–1) of a position removes f of every lot's LP AND scales every
 * remaining lot's age by (1 − f). Ages are capped at the Heat ramp BEFORE
 * scaling, so banked age past the curve can't absorb a withdrawal: a
 * two-year lot that withdraws 50% lands at 182.5 days, exactly like a
 * one-year lot. Taps are the exception — they draw the youngest lots first
 * and cool nothing.
 */
export declare function cooledAgeAfterWithdrawal(ageDays: number, withdrawFraction: number, c?: ForgeConfig): number;
/** Extra Heat from a Capstone worth `capstoneValue` beside LP worth `lpValue`. */
export declare function capstoneBonus(capstoneValue: number, lpValue: number, c?: ForgeConfig): number;
/**
 * Permanent account-wide Heat boost from `burnedEmber` EMBER fed to the Pyre.
 * Soulbound tiers; capped at maxBoost. Add to heatMultiplier() — it is not
 * age-derived, so it lives outside the age curve by design.
 */
export declare function pyreBoost(burnedEmber: number, c?: ForgeConfig): number;
/**
 * Split of one emission payout into liquid EMBER and LP-cast portions.
 * `reserveQuoteValue` is the match reserve's holdings measured in EMBER value
 * at pool price. The cast share is capped by what pairs cleanly — the
 * uncovered remainder stays liquid. The protocol never market-sells here.
 */
export declare function castEmissionSplit(emission: number, reserveQuoteValue: number, c?: ForgeConfig): {
    liquid: number;
    cast: number;
};
/**
 * Heat age after withdrawing `fraction` (0..1) of the LP. Delegates to
 * cooledAgeAfterWithdrawal: the single proportional-cooling implementation.
 * (The old uncapped variant is retired — two helpers with different age
 * policies for the same input was an interface inconsistency.)
 */
export declare function heatAgeAfterWithdrawal(ageDays: number, fraction: number, c?: ForgeConfig): number;
/** Display-only blended age. Never use this number to replace per-lot financial accounting. */
export declare function heatAgeAfterDeposit(oldAge: number, oldStake: number, newStake: number): number;
/**
 * A position's share of one epoch's base emission across both buckets.
 * `totalStake` / `totalWeighted` are the pool-wide sums of stake and stake × multiplier.
 */
export declare function rewardShare(stake: number, multiplier: number, totalStake: number, totalWeighted: number, e?: EmissionsConfig): number;
/**
 * A sealed position's Conviction-bucket payout cap for one epoch.
 * Additive bonus b on ordinary Heat h is worth (b/h) × P — the bonus's
 * marginal value in the Heat pool — computed non-circularly as:
 *   cap = heatBudget × stake × sealBonus / totalHeatWeightedStake
 * `heatBudget` is the pre-return Heat slice (63% of the epoch); pass the
 * ordinary (pre-seal) heat-weighted stake sum. Returns 0 when unsealed.
 */
export declare function convictionCap(stake: number, sealBonus: number, totalHeatWeightedStake: number, epochMint: number, e?: EmissionsConfig): number;
/**
 * Effective epoch split after the Conviction bucket. The ordinary budget is
 * 27% flat / 63% Heat / 10% bucket; whatever the per-position caps hold back
 * — and the whole bucket when nobody is sealed — returns to the Heat pool.
 * With an empty bucket the effective split is 27% flat / 73% Heat (not 30/70).
 */
export declare function epochSplit(epochMint: number, bucketUnallocated: number, e?: EmissionsConfig): {
    flat: number;
    heat: number;
    bucket: number;
};
/** Base emission per day at `day` after pool open. */
export declare function baseEmissionPerDay(day: number, e?: EmissionsConfig): number;
/**
 * The live-supply ceiling, executable. What actually mints in an epoch is
 * the TARGET emission capped by remaining headroom under 21M:
 *   mint = min(targetEmission, max(0, 21M − totalSupply)).
 * Burns reduce totalSupply and reopen headroom — the 1,000/day tail is a
 * target the protocol must earn through deflation, not a promise the cap
 * must break for. When headroom < target, all recipients scale down pro-rata.
 */
export declare function mintForEpoch(targetEmission: number, totalSupply: number, e?: EmissionsConfig): number;
/**
 * Ashfall is a mint, so it shares the epoch's headroom check with base
 * emission. ONE budget: base target + Ashfall target scale down PRO-RATA
 * when headroom is short. Ashfall can never push supply past 21M on its own.
 */
export declare function totalMintForEpoch(baseTarget: number, ashfallTarget: number, totalSupply: number, e?: EmissionsConfig): {
    base: number;
    ashfall: number;
};
/** Claim cooldown for a position at `streakDays`, honouring relic perks. */
export declare function claimCooldownSeconds(streakDays: number, c?: FurnaceConfig): number;
/**
 * Withdrawal cooldown for exiting `withdrawPct` (0–100) of a position.
 * Progressive: small exits cool fast, whale exits face the full timer.
 */
export declare function withdrawCooldownSeconds(withdrawPct: number, c?: FurnaceConfig): number;
/** Conviction-track bonus for a `trackDays` track, or 0 if no such track. */
export declare function convictionBonus(trackDays: number, c?: ForgeConfig): number;
/**
 * Ignition reward weight for a deposit at `elapsedHours` into the phase.
 * Early-bird bonus decays from +maxBonusPct to zero across the window —
 * urgency without a first-block landgrab. Multiplies the pro-rata share.
 */
export declare function ignitionWeight(elapsedHours: number, c?: IgnitionConfig): number;
/**
 * Heat age the BUYER of a Deed inherits. The position's Streak resets to 0 and
 * badges stay with the seller; only a haircut share of the age moves.
 * Financial age is capped at the Heat ramp BEFORE the haircut: an 80% carry
 * on a 730-day lot yields 292 days, not 584. (Streak is chronological and is
 * never capped — capping financial age does not shorten anyone's Streak.)
 */
export declare function deedHeatAge(sellerAgeDays: number, c?: ForgeConfig): number;
/**
 * Maximum nominal allocation coefficient (not an APR or subsidy-value ceiling):
 * Heat at the ramp cap + Capstone max + Pyre max + best track bonus.
 * check:config asserts this equals forge.caps.maxTotalMultiplier.
 */
export declare function maxTotalMultiplier(c?: ForgeConfig): number;
/** Build-time sanity checks; `pnpm check:config` calls this. */
/** Compatibility entrypoint: deployment diagnostics are never hidden by default. */
export declare function validateConfig(c?: FurnaceConfig): string[];
export declare function validateConfigDetailed(c?: FurnaceConfig, stage?: CheckStage): Diagnostic[];
export declare function assetAddress(symbol: string, chain: ChainKey, c?: FurnaceConfig): Address;
/** Pool/category-aware allocation display. Uncast amounts retain their existing payout ledger; uncast is not an escrow unlock. A subsidy reservation is still required. */
export declare function castForPool(poolId: string, rewardClass: string, reward: number, reserveValue: number, c?: FurnaceConfig): {
    uncast: number;
    cast: number;
};
