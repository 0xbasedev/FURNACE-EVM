/**
 * FURNACE v5.5.0 - canonical design/configuration consolidation.
 * This file supersedes the v5.4 configuration for subsequent implementation.
 * No contract deployment or audit is implied. Active launch: Ethereum only.
 * Amounts are human-unit strings; display helpers use numbers. Monetary
 * reference settlement is in accounting.ts and uses integer smallest units.
 * Presentation, configuration data, source, and deployment commitments differ.
 * See DECISIONS.md for the decisions made under delegated design authority.
 */
import { validateResolvedConfig } from './validation.js';
export const CREATEX_FACTORY = '0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed';
export const DEPLOYER = '0x1111111111111111111111111111111111111111'; // TEMPLATE ONLY; no signing authority implied.
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
};
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
};
export function contractAddress(name, c = furnaceConfig) {
    const entry = c.deployment.evm.contracts[name];
    if (!entry?.address)
        throw new Error(`Unmined contract: ${name}`);
    return entry.address;
}
const FURNACE_NAMES = {
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
const TEPHRA_NAMES = {
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
export const namePresets = { furnace: FURNACE_NAMES, tephra: TEPHRA_NAMES };
// ─── The config ─────────────────────────────────────────────────────────────
export const furnaceConfig = {
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
/** Reject invalid numeric domains at exported helper boundaries. */
function requireNonnegativeFinite(label, values) {
    if (values.some((value) => !Number.isFinite(value) || value < 0)) {
        throw new Error(`[config] ${label}: inputs must be finite and nonnegative`);
    }
}
/** Heat multiplier for a position of `ageDays`, including relic bumps. */
export function heatMultiplier(ageDays, c = furnaceConfig.forge) {
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
export function milestoneBump(ageDays, c = furnaceConfig.forge) {
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
        }
        else {
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
export function cooledAgeAfterWithdrawal(ageDays, withdrawFraction, c = furnaceConfig.forge) {
    const capped = Math.min(Math.max(ageDays, 0), c.heat.rampDays);
    const f = Math.min(Math.max(withdrawFraction, 0), 1);
    return capped * (1 - f);
}
/** Extra Heat from a Capstone worth `capstoneValue` beside LP worth `lpValue`. */
export function capstoneBonus(capstoneValue, lpValue, c = furnaceConfig.forge) {
    if (!c.capstone.enabled || lpValue <= 0)
        return 0;
    const ratio = Math.min(capstoneValue / lpValue, c.capstone.ratioForMax);
    return c.capstone.maxBonus * (ratio / c.capstone.ratioForMax);
}
/**
 * Permanent account-wide Heat boost from `burnedEmber` EMBER fed to the Pyre.
 * Soulbound tiers; capped at maxBoost. Add to heatMultiplier() — it is not
 * age-derived, so it lives outside the age curve by design.
 */
export function pyreBoost(burnedEmber, c = furnaceConfig.forge) {
    if (!c.pyre.enabled)
        return 0;
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
export function castEmissionSplit(emission, reserveQuoteValue, c = furnaceConfig.forge) {
    if (!c.casting.enabled || c.casting.lpSharePct <= 0)
        return { liquid: emission, cast: 0 };
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
export function heatAgeAfterWithdrawal(ageDays, fraction, c = furnaceConfig.forge) {
    return cooledAgeAfterWithdrawal(ageDays, fraction, c);
}
/** Display-only blended age. Never use this number to replace per-lot financial accounting. */
export function heatAgeAfterDeposit(oldAge, oldStake, newStake) {
    const total = oldStake + newStake;
    if (total <= 0)
        return 0;
    return (oldAge * oldStake) / total; // new money enters at age 0
}
/**
 * A position's share of one epoch's base emission across both buckets.
 * `totalStake` / `totalWeighted` are the pool-wide sums of stake and stake × multiplier.
 */
export function rewardShare(stake, multiplier, totalStake, totalWeighted, e = furnaceConfig.emissions) {
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
export function convictionCap(stake, sealBonus, totalHeatWeightedStake, epochMint, e = furnaceConfig.emissions) {
    requireNonnegativeFinite('convictionCap', [stake, sealBonus, totalHeatWeightedStake, epochMint]);
    if (sealBonus <= 0 || totalHeatWeightedStake <= 0 || epochMint <= 0)
        return 0;
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
export function epochSplit(epochMint, bucketUnallocated, e = furnaceConfig.emissions) {
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
export function baseEmissionPerDay(day, e = furnaceConfig.emissions) {
    const start = Number(e.base.startPerDay);
    const floor = Number(e.base.floorPerDay);
    if (e.base.shape === 'halfLife')
        return Math.max(floor, start * Math.pow(2, -day / e.base.halfLifeDays));
    if (e.base.shape === 'linear')
        return Math.max(floor, start * (1 - day / (e.base.halfLifeDays * 2)));
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
export function mintForEpoch(targetEmission, totalSupply, e = furnaceConfig.emissions) {
    return totalMintForEpoch(targetEmission, 0, totalSupply, e).base;
}
/**
 * Ashfall is a mint, so it shares the epoch's headroom check with base
 * emission. ONE budget: base target + Ashfall target scale down PRO-RATA
 * when headroom is short. Ashfall can never push supply past 21M on its own.
 */
export function totalMintForEpoch(baseTarget, ashfallTarget, totalSupply, e = furnaceConfig.emissions) {
    if (!Number.isFinite(baseTarget) || !Number.isFinite(ashfallTarget) || !Number.isFinite(totalSupply)) {
        throw new Error('[config] totalMintForEpoch: non-finite input');
    }
    if (baseTarget < 0 || ashfallTarget < 0 || totalSupply < 0) {
        throw new Error('[config] totalMintForEpoch: negative input — mint targets and supply must be ≥ 0');
    }
    const headroom = Math.max(0, Number(e.supplyCeiling.hardCap) - totalSupply);
    const total = baseTarget + ashfallTarget;
    if (total <= headroom)
        return { base: baseTarget, ashfall: ashfallTarget };
    const scale = total > 0 ? headroom / total : 0;
    return { base: baseTarget * scale, ashfall: ashfallTarget * scale };
}
/** Claim cooldown for a position at `streakDays`, honouring relic perks. */
export function claimCooldownSeconds(streakDays, c = furnaceConfig) {
    let seconds = c.cooldowns.claim.seconds;
    for (const r of c.forge.relics) {
        if (streakDays >= r.days && r.perks.claimCooldownSeconds)
            seconds = Math.min(seconds, r.perks.claimCooldownSeconds);
    }
    return seconds;
}
/**
 * Withdrawal cooldown for exiting `withdrawPct` (0–100) of a position.
 * Progressive: small exits cool fast, whale exits face the full timer.
 */
export function withdrawCooldownSeconds(withdrawPct, c = furnaceConfig) {
    const tiers = c.cooldowns.withdraw.tiers;
    const pct = Math.min(Math.max(withdrawPct, 0), 100);
    for (const t of tiers) {
        if (pct <= t.maxWithdrawPct)
            return t.seconds;
    }
    return c.cooldowns.withdraw.seconds;
}
/** Conviction-track bonus for a `trackDays` track, or 0 if no such track. */
export function convictionBonus(trackDays, c = furnaceConfig.forge) {
    if (!c.convictionTracks.enabled)
        return 0;
    return c.convictionTracks.tracks.find((t) => t.days === trackDays)?.bonus ?? 0;
}
/**
 * Ignition reward weight for a deposit at `elapsedHours` into the phase.
 * Early-bird bonus decays from +maxBonusPct to zero across the window —
 * urgency without a first-block landgrab. Multiplies the pro-rata share.
 */
export function ignitionWeight(elapsedHours, c = furnaceConfig.ignition) {
    if (!c.earlyBird.enabled)
        return 1;
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
export function deedHeatAge(sellerAgeDays, c = furnaceConfig.forge) {
    if (!c.deeds.enabled)
        return 0;
    const capped = Math.min(Math.max(sellerAgeDays, 0), c.heat.rampDays);
    return capped * (c.deeds.heatCarryPct / 100);
}
/**
 * Maximum nominal allocation coefficient (not an APR or subsidy-value ceiling):
 * Heat at the ramp cap + Capstone max + Pyre max + best track bonus.
 * check:config asserts this equals forge.caps.maxTotalMultiplier.
 */
export function maxTotalMultiplier(c = furnaceConfig.forge) {
    const trackBest = Math.max(0, ...c.convictionTracks.tracks.map((t) => t.bonus));
    return heatMultiplier(c.heat.rampDays, c) + c.capstone.maxBonus + c.pyre.maxBoost + trackBest;
}
/** Build-time sanity checks; `pnpm check:config` calls this. */
/** Compatibility entrypoint: deployment diagnostics are never hidden by default. */
export function validateConfig(c = furnaceConfig) {
    return validateResolvedConfig(c, 'deployment').map(d => `[${d.code}] ${d.path}: ${d.message}`);
}
export function validateConfigDetailed(c = furnaceConfig, stage = 'deployment') {
    return validateResolvedConfig(c, stage);
}
export function assetAddress(symbol, chain, c = furnaceConfig) {
    const binding = c.assets[chain]?.[symbol];
    if (!binding)
        throw new Error(`Unconfigured asset ${symbol} on ${chain}`);
    if (binding.kind === 'protocol')
        return contractAddress(binding.contract, c);
    if (!binding.address)
        throw new Error(`Unverified external asset ${symbol} on ${chain}`);
    return binding.address;
}
/** Pool/category-aware allocation display. Uncast amounts retain their existing payout ledger; uncast is not an escrow unlock. A subsidy reservation is still required. */
export function castForPool(poolId, rewardClass, reward, reserveValue, c = furnaceConfig) {
    requireNonnegativeFinite('castForPool', [reward, reserveValue]);
    const pool = c.forge.pools.find(p => p.id === poolId);
    if (!pool)
        throw new Error(`Unknown pool ${poolId}`);
    if (pool.stakeKind !== 'lp' || !c.execution.casting.eligibleRewardClasses.includes(rewardClass))
        return { uncast: reward, cast: 0 };
    const quote = castEmissionSplit(reward, reserveValue, c.forge);
    return { uncast: quote.liquid, cast: quote.cast };
}
