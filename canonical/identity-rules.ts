/* Independent review expectations. Changing these is a protocol revision. */
export const IDENTITY_RULES = {
  "token": {
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
    }
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
          "burnEmber": "250",
          "heatBoost": 0.05
        },
        {
          "key": "wildfire",
          "burnEmber": "1250",
          "heatBoost": 0.05
        },
        {
          "key": "conflagration",
          "burnEmber": "6250",
          "heatBoost": 0.05
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
          "bonus": 0.15
        },
        {
          "days": 90,
          "bonus": 0.25
        },
        {
          "days": 180,
          "bonus": 0.35
        },
        {
          "days": 365,
          "bonus": 0.5
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
        }
      },
      {
        "key": "flame",
        "days": 30,
        "heatBump": 0.1,
        "perks": {
          "claimCooldownSeconds": 57600,
          "ashfallEligible": true
        }
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
        }
      },
      {
        "key": "inferno",
        "days": 180,
        "heatBump": 0.1,
        "perks": {
          "claimCooldownSeconds": 43200,
          "kindlingPriority": true
        }
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
        }
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
        }
      }
    ],
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
        "stakeToken": "EMBER/USDC",
        "stakeKind": "lp",
        "allocPoints": 1000,
        "ashAllocPoints": 500,
        "withdrawCooldownHours": 72
      },
      {
        "id": "ember-weth-lp",
        "stakeToken": "EMBER/WETH",
        "stakeKind": "lp",
        "allocPoints": 400,
        "ashAllocPoints": 200,
        "withdrawCooldownHours": 72
      },
      {
        "id": "ember-single",
        "stakeToken": "EMBER",
        "stakeKind": "single",
        "allocPoints": 400,
        "ashAllocPoints": 300,
        "withdrawCooldownHours": 72
      },
      {
        "id": "usdc-single",
        "stakeToken": "USDC",
        "stakeKind": "single",
        "allocPoints": 200,
        "ashAllocPoints": 0,
        "withdrawCooldownHours": 72
      }
    ]
  },
  "kindling": {
    "enabled": true,
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
  "ignition": {
    "durationHours": 120,
    "minDurationHours": 48,
    "maxDurationHours": 336,
    "depositFeePct": 3,
    "feeDestination": "treasury",
    "withdrawDuringWindow": {
      "enabled": true,
      "refundFee": false
    },
    "exitWindowHours": 24,
    "exitFeePct": 0,
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
    },
    "pools": [
      {
        "id": "ign-usdc",
        "stakeToken": "USDC",
        "weight": 100
      },
      {
        "id": "ign-weth",
        "stakeToken": "WETH",
        "weight": 100
      },
      {
        "id": "ign-wbtc",
        "stakeToken": "WBTC",
        "weight": 100
      },
      {
        "id": "ign-eth-usdc-lp",
        "stakeToken": "WETH/USDC",
        "weight": 150
      }
    ]
  }
} as const;
