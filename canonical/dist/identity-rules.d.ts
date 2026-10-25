export declare const IDENTITY_RULES: {
    readonly token: {
        readonly decimals: {
            readonly evm: 18;
            readonly svm: 9;
        };
        readonly standard: "lz-oft-v2";
        readonly oft: {
            readonly sharedDecimals: 6;
            readonly homeChain: "ethereum";
            readonly enforcedGas: {
                readonly send: 80000;
                readonly compose: 200000;
            };
            readonly rateLimit: {
                readonly amountPerWindow: "250000";
                readonly windowSeconds: 3600;
            };
        };
        readonly allocations: {
            readonly kindlingPool: "420000";
            readonly treasury: {
                readonly amount: "500000";
                readonly cliffDays: 0;
                readonly vestingDays: 365;
            };
            readonly team: {
                readonly amount: "0";
                readonly cliffDays: 180;
                readonly vestingDays: 730;
                readonly recipients: readonly [];
            };
        };
        readonly maxSupply: "21000000";
    };
    readonly shareToken: {
        readonly decimals: {
            readonly evm: 18;
            readonly svm: 9;
        };
        readonly standard: "lz-oft-v2";
        readonly maxSupply: "70000";
        readonly allocations: {
            readonly launch: {
                readonly ignition: "41000";
                readonly kindling: "1000";
            };
            readonly forge: "28000";
        };
        readonly forgeTrickleDays: 730;
    };
    readonly emissions: {
        readonly controllerChain: "ethereum";
        readonly epochSeconds: 86400;
        readonly split: {
            readonly flatPct: 30;
            readonly heatPct: 70;
        };
        readonly base: {
            readonly startPerDay: "21600";
            readonly shape: "halfLife";
            readonly halfLifeDays: 365;
            readonly floorPerDay: "1000";
        };
        readonly supplyCeiling: {
            readonly hardCap: "21000000";
            readonly mode: "liveSupply";
        };
        readonly convictionBucketPct: 10;
        readonly ashfall: {
            readonly enabled: true;
            readonly recycleRates: {
                readonly protocolBurns: 50;
                readonly pyreBurns: 25;
                readonly unsolicited: 0;
            };
            readonly lagEpochs: 1;
            readonly minRelic: "flame";
            readonly distributionWeight: "heatSquared";
            readonly rolloverUndistributed: true;
            readonly sources: readonly ["forgeFees", "swapFees", "emergencyExit", "manualBurns"];
        };
        readonly gauge: {
            readonly enabled: false;
            readonly weight: "heatWeightedStake";
            readonly reportIntervalSeconds: 86400;
            readonly maxCreditPerEpochPct: 60;
        };
    };
    readonly fees: {
        readonly vent: {
            readonly burnPct: 40;
            readonly liquidityPct: 40;
            readonly hearthPct: 10;
            readonly treasuryPct: 10;
        };
        readonly genesisDeposit: {
            readonly treasuryPct: 100;
        };
        readonly burnLane: {
            readonly method: "unwindAndBuyback";
            readonly twapSeconds: 1800;
            readonly maxPriceImpactBps: 300;
            readonly allowlistedRoutersOnly: true;
            readonly deferIfUnsafe: true;
            readonly maxDeferralHours: 72;
            readonly avgPriceBandBps: 200;
            readonly slippageCapBps: 100;
            readonly maxChunkPctOfReserve: 0.5;
        };
        readonly feeVault: {
            readonly enabled: true;
            readonly minBatchUsd: 5000;
            readonly maxWaitHours: 24;
        };
        readonly liquidityLane: {
            readonly method: "matchReserve";
            readonly matchReserve: {
                readonly idleEpochsBeforeAutoPair: 7;
                readonly burnMatchedLp: true;
                readonly idlePairEmberSource: "treasuryMatchSeed";
            };
            readonly permanentMustBeFullRange: true;
        };
        readonly tokenFees: {
            readonly burnPct: 100;
        };
        readonly swap: {
            readonly buy: {
                readonly totalBps: 25;
                readonly lpBps: 20;
                readonly burnBps: 2.5;
                readonly liquidityBps: 2.5;
                readonly treasuryBps: 0;
            };
            readonly sell: {
                readonly totalBps: 35;
                readonly lpBps: 20;
                readonly burnBps: 5;
                readonly liquidityBps: 5;
                readonly quoteYieldBps: 5;
                readonly treasuryBps: 0;
            };
            readonly waiveProtocolShareOnCompound: true;
        };
        readonly quoteYield: {
            readonly enabled: true;
            readonly eligibility: "ashfallEligible";
            readonly asset: "quoteAsset";
        };
    };
    readonly cooldowns: {
        readonly withdraw: {
            readonly seconds: 259200;
            readonly tiers: readonly [{
                readonly maxWithdrawPct: 10;
                readonly seconds: 21600;
            }, {
                readonly maxWithdrawPct: 25;
                readonly seconds: 43200;
            }, {
                readonly maxWithdrawPct: 50;
                readonly seconds: 86400;
            }, {
                readonly maxWithdrawPct: 75;
                readonly seconds: 172800;
            }, {
                readonly maxWithdrawPct: 100;
                readonly seconds: 259200;
            }];
            readonly executionWindowSeconds: 86400;
            readonly earnsWhileCooling: false;
            readonly onCancelOrLapse: "resumeFrozen";
        };
        readonly claim: {
            readonly seconds: 86400;
            readonly snapshotAtRequest: true;
        };
        readonly compound: {
            readonly seconds: 0;
        };
    };
    readonly execution: {
        readonly status: "design-canonical-not-deployed";
        readonly activation: {
            readonly initialChain: "ethereum";
            readonly bridgeEnabled: false;
            readonly satellitesRequireSeparateRelease: true;
        };
        readonly casting: {
            readonly eligibleRewardClasses: readonly ["ordinaryBase"];
            readonly denominator: "postConvictionOrdinaryBase";
            readonly singleTokenPolicy: "liquid";
            readonly requiresActiveSourceLot: true;
            readonly explicitZapConsent: true;
        };
        readonly matching: {
            readonly ownership: "user";
            readonly allocation: "epochProRataByEligibleBaseReward";
            readonly automaticCastPriority: true;
            readonly optionalStokeUsesOnlyRemainder: true;
            readonly claimWindowEpochs: 7;
            readonly oneUsePerRewardUnit: true;
            readonly expiry: "releaseQuoteOnlyKeepUserReward";
            readonly idlePairUsesOnlyUnreservedInventory: true;
            readonly idlePairEmber: "treasuryMatchSeed";
        };
        readonly settlement: {
            readonly weightBasis: "timeIntegratedPerLot";
            readonly budgetAccrual: "onlyWhilePoolHasActiveStake";
            readonly heatIntegral: "cappedSqrtAntiderivative";
            readonly multiplierScale: "1000000000000000000000000000";
            readonly maxLotsPerPage: 32;
            readonly aggregateAuthority: "onchainCheckpoints";
            readonly residue: "retainTaggedUnallocated";
            readonly exitsDependOnSettlement: false;
        };
        readonly withdrawals: {
            readonly aggregation: "frozenReferenceCumulativeRequests";
            readonly planHorizonSeconds: 259200;
            readonly cancelConsumesPlanQuota: true;
            readonly newRequestsNeverDelayMaturedTickets: true;
            readonly freeze: "requestedSlice";
            readonly lapse: "resumeFrozen";
            readonly exitAsset: "inKind";
            readonly exitRequiresOracle: false;
        };
        readonly seals: {
            readonly membership: "sealedCohortsOnly";
            readonly topupsJoinExistingSeal: false;
            readonly pendingCooling: "pauseSealAccrualAndExtendEnd";
            readonly tapBeforeMaturity: "forfeitUnvestedBonus";
            readonly walletKeystoneRequiresWholeTermOwnership: true;
        };
        readonly kindling: {
            readonly feeCustody: "dedicatedImmutableEscrow";
            readonly successRelease: "afterAtomicPoolInitialization";
            readonly failureRefundAsset: "depositedQuote";
            readonly maxSettlementDelaySeconds: 259200;
            readonly cutoff: "rejectNewDepositsAtDeadline";
            readonly cancelUntilSettlement: "netPrincipalNowFeeIfLaunchFails";
            readonly treasuryFallback: "separateFundedEvent";
            readonly closeBountyBasis: "acceptedGrossQuote";
        };
        readonly ashfall: {
            readonly lotEligibility: "actualParticipationAgeAndActiveStreak";
            readonly minimumParticipationDays: 30;
            readonly founderFloorCountsAsParticipation: false;
            readonly burnReceipt: "uniqueAuthenticatedEconomicBurn";
            readonly transportBurnCredit: false;
            readonly voluntaryRecapture: "possibleAndDisclosed";
        };
        readonly vent: {
            readonly aggregateWindowSeconds: 1800;
            readonly aggregateMaxReserveBps: 50;
            readonly reserveReference: "fixedWindowStart";
            readonly atDeferralLimit: "alertNeverWeakenGuards";
            readonly principalExitRequiresVent: false;
        };
        readonly deeds: {
            readonly unclaimedRewards: "goWithDeed";
            readonly sellerMutationsWhileListed: "cancelListingFirst";
            readonly cancellation: "allowedBeforeSettlementWithPullRefunds";
            readonly noInstantBuyout: true;
            readonly receiverFailure: "claimDeliveryCannotBlockSellerProceeds";
        };
        readonly hearth: {
            readonly feeScope: "chainLocalFundedLiabilities";
            readonly crossChainFeeAggregation: false;
        };
        readonly release: {
            readonly safeThreshold: 3;
            readonly safeOwnersRequired: 5;
            readonly minimumIndependentAudits: 2;
            readonly sourceHashRequired: true;
            readonly bytecodeHashRequired: true;
            readonly initializerHashRequired: true;
            readonly chainStateVerificationRequired: true;
        };
    };
    readonly forge: {
        readonly fees: {
            readonly depositPct: 1;
            readonly withdrawPct: 1;
            readonly claimPct: 0;
            readonly compoundPct: 0;
            readonly waiveDepositFeeFromFlow: true;
        };
        readonly heat: {
            readonly startMultiplier: 1;
            readonly rampBonus: 1.5;
            readonly rampDays: 365;
            readonly shape: "sqrt";
            readonly depositDilution: "perLot";
            readonly compoundInheritsAge: true;
            readonly compoundProvenance: "sourceLot";
            readonly maxLotsPerPosition: 32;
            readonly lotExhaustion: "newDeed";
            readonly withdrawCooling: "proportional";
            readonly tapDrawdownMode: "youngestFirst";
        };
        readonly compound: {
            readonly defaultTarget: "capstoneThenLp";
            readonly userCanChoose: true;
            readonly lpMatch: {
                readonly enabled: true;
                readonly source: "matchReserve";
                readonly fallback: "capstone";
            };
        };
        readonly capstone: {
            readonly enabled: true;
            readonly maxBonus: 0.5;
            readonly ratioForMax: 0.5;
            readonly earnsEmissions: false;
            readonly depositFeePct: 1;
            readonly withdrawFeePct: 1;
            readonly cooldown: "sameAsWithdraw";
            readonly affectsStreak: false;
            readonly affectsHeatAge: false;
        };
        readonly autoStoke: {
            readonly enabled: true;
            readonly defaultOn: false;
            readonly tip: {
                readonly minPct: 0.1;
                readonly defaultPct: 0.5;
                readonly maxPct: 1;
            };
            readonly minInterval: {
                readonly minHours: 24;
                readonly defaultHours: 168;
            };
            readonly minSize: "100";
        };
        readonly casting: {
            readonly enabled: true;
            readonly lpSharePct: 25;
            readonly quoteSource: "matchReserve";
            readonly fallback: "liquidEmber";
            readonly autoStake: true;
            readonly castLot: "sourceLot";
            readonly entersAs: "sourceLotAge";
            readonly incompatibleCollateral: "liquid";
            readonly matchedLpOwnership: "user";
        };
        readonly pyre: {
            readonly enabled: true;
            readonly tiers: readonly [{
                readonly key: "cinder";
                readonly burnEmber: "250";
                readonly heatBoost: 0.05;
            }, {
                readonly key: "wildfire";
                readonly burnEmber: "1250";
                readonly heatBoost: 0.05;
            }, {
                readonly key: "conflagration";
                readonly burnEmber: "6250";
                readonly heatBoost: 0.05;
            }];
            readonly maxBoost: 0.15;
            readonly soulbound: true;
        };
        readonly convictionTracks: {
            readonly enabled: true;
            readonly tracks: readonly [{
                readonly days: 30;
                readonly bonus: 0.15;
            }, {
                readonly days: 90;
                readonly bonus: 0.25;
            }, {
                readonly days: 180;
                readonly bonus: 0.35;
            }, {
                readonly days: 365;
                readonly bonus: 0.5;
            }];
            readonly vestAtTermEnd: true;
            readonly bucketCap: {
                readonly enabled: true;
                readonly capToSealBonusOfHeatShare: true;
                readonly unallocatedFlowsTo: "heatPool";
            };
            readonly escrow: {
                readonly enabled: true;
                readonly payout: "capstone";
            };
            readonly forfeitRouting: {
                readonly burnPct: 50;
                readonly matchReservePct: 25;
                readonly sealedPotPct: 25;
            };
            readonly keystone: {
                readonly walletRelic: {
                    readonly enabled: true;
                    readonly key: "keystone";
                    readonly soulbound: true;
                };
                readonly deedScar: {
                    readonly enabled: true;
                };
            };
        };
        readonly deeds: {
            readonly enabled: true;
            readonly heatCarryPct: 80;
            readonly marketFeePct: 1;
            readonly feeRouting: {
                readonly burnPct: 50;
                readonly liquidityPct: 50;
            };
            readonly marketOnlyTransfers: true;
            readonly blockListingWithPending: true;
            readonly saleMode: "auction";
            readonly auctionHours: 24;
            readonly antiSnipe: {
                readonly windowMinutes: 5;
                readonly extensionMinutes: 5;
                readonly maxTotalExtensionMinutes: 30;
            };
        };
        readonly referrals: {
            readonly enabled: false;
            readonly sharePct: 3;
            readonly refereeMinRelic: "spark";
            readonly referrerMinRelic: "flame";
        };
        readonly caps: {
            readonly maxTotalMultiplier: 4.15;
        };
        readonly relics: readonly [{
            readonly key: "spark";
            readonly days: 7;
            readonly heatBump: 0.1;
            readonly perks: {
                readonly claimCooldownSeconds: 72000;
            };
        }, {
            readonly key: "flame";
            readonly days: 30;
            readonly heatBump: 0.1;
            readonly perks: {
                readonly claimCooldownSeconds: 57600;
                readonly ashfallEligible: true;
            };
        }, {
            readonly key: "blaze";
            readonly days: 90;
            readonly heatBump: 0.1;
            readonly perks: {
                readonly tap: {
                    readonly maxPct: 10;
                    readonly everyDays: 90;
                };
            };
        }, {
            readonly key: "inferno";
            readonly days: 180;
            readonly heatBump: 0.1;
            readonly perks: {
                readonly claimCooldownSeconds: 43200;
                readonly kindlingPriority: true;
            };
        }, {
            readonly key: "eternal";
            readonly days: 365;
            readonly heatBump: 0.1;
            readonly perks: {
                readonly tap: {
                    readonly maxPct: 25;
                    readonly everyDays: 90;
                };
                readonly governanceWeight: 2;
                readonly feeRebatePct: 25;
            };
        }, {
            readonly key: "bedrock";
            readonly days: 730;
            readonly heatBump: 0;
            readonly perks: {
                readonly tap: {
                    readonly maxPct: 25;
                    readonly everyDays: 60;
                };
                readonly governanceWeight: 3;
                readonly feeRebatePct: 50;
            };
        }];
        readonly withdrawResetsStreak: true;
        readonly cancelReturnsAsFreshLot: false;
        readonly emergencyExit: {
            readonly enabled: true;
            readonly feePct: 8;
            readonly routing: {
                readonly burnPct: 50;
                readonly liquidityPct: 25;
                readonly stakersPct: 25;
            };
            readonly forfeitsAshfall: true;
        };
        readonly minStakeLp: "0.0001";
        readonly pools: readonly [{
            readonly id: "ember-usdc-lp";
            readonly stakeToken: "EMBER/USDC";
            readonly stakeKind: "lp";
            readonly allocPoints: 1000;
            readonly ashAllocPoints: 500;
            readonly withdrawCooldownHours: 72;
        }, {
            readonly id: "ember-weth-lp";
            readonly stakeToken: "EMBER/WETH";
            readonly stakeKind: "lp";
            readonly allocPoints: 400;
            readonly ashAllocPoints: 200;
            readonly withdrawCooldownHours: 72;
        }, {
            readonly id: "ember-single";
            readonly stakeToken: "EMBER";
            readonly stakeKind: "single";
            readonly allocPoints: 400;
            readonly ashAllocPoints: 300;
            readonly withdrawCooldownHours: 72;
        }, {
            readonly id: "usdc-single";
            readonly stakeToken: "USDC";
            readonly stakeKind: "single";
            readonly allocPoints: 200;
            readonly ashAllocPoints: 0;
            readonly withdrawCooldownHours: 72;
        }];
    };
    readonly kindling: {
        readonly enabled: true;
        readonly mode: "auction";
        readonly durationHours: 24;
        readonly quoteToken: "USDC";
        readonly seedEmberBpsOfMax: 200;
        readonly minRaiseUsd: 100000;
        readonly maxRaiseUsd: 5000000;
        readonly maxPerWalletUsd: 25000;
        readonly depositFeePct: 3;
        readonly feeDestination: "treasury";
        readonly feeEscrowUntilClose: true;
        readonly priceMode: "clearing";
        readonly polPair: "EMBER/USDC";
        readonly lpSplit: {
            readonly depositorDeedsPct: 90;
            readonly burnPct: 10;
        };
        readonly ashBonusPool: "1000";
        readonly fallback: "treasury-seed";
        readonly atomicPoolInit: true;
        readonly closeBountyBps: 5;
    };
    readonly ignition: {
        readonly durationHours: 120;
        readonly minDurationHours: 48;
        readonly maxDurationHours: 336;
        readonly depositFeePct: 3;
        readonly feeDestination: "treasury";
        readonly withdrawDuringWindow: {
            readonly enabled: true;
            readonly refundFee: false;
        };
        readonly exitWindowHours: 24;
        readonly exitFeePct: 0;
        readonly rewards: {
            readonly token: "ASH";
            readonly total: "41000";
            readonly mode: "per-second-pro-rata";
            readonly vesting: "none";
        };
        readonly founderBadge: {
            readonly enabled: true;
            readonly key: "first-flame";
            readonly phantomAgeBonusDays: 15;
        };
        readonly heatHeadStart: "ignitionStart";
        readonly principalAtClose: {
            readonly usdc: "autoStakeColdStorage";
            readonly usdcOptOutAtDeposit: true;
            readonly otherAssets: "claimableFeeFree";
            readonly headStartWindowDays: 7;
            readonly headStartCappedToUsdKept: true;
        };
        readonly earlyBird: {
            readonly enabled: true;
            readonly maxBonusPct: 10;
            readonly shape: "linear";
        };
        readonly pools: readonly [{
            readonly id: "ign-usdc";
            readonly stakeToken: "USDC";
            readonly weight: 100;
        }, {
            readonly id: "ign-weth";
            readonly stakeToken: "WETH";
            readonly weight: 100;
        }, {
            readonly id: "ign-wbtc";
            readonly stakeToken: "WBTC";
            readonly weight: 100;
        }, {
            readonly id: "ign-eth-usdc-lp";
            readonly stakeToken: "WETH/USDC";
            readonly weight: 150;
        }];
    };
};
