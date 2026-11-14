import { getAddress, type Address } from 'viem';

/** What the dApp needs from a testnet manifest (contracts/script/DeployTestnet.s.sol `_report`). */
export interface Deployment {
  chainId: number;
  ember: Address;
  flow: Address;
  lens: Address;
  rebates: Address;
  pairsLive: boolean;
  pairs: [PairInfo, PairInfo];
  pools: [Address, Address, Address, Address];
  /** The real Kindling (FURNACE_TESTNET_KINDLING=1, ADR 0021); absent while the operator stands in. */
  kindling: { address: Address; escrow: Address; sink: Address } | null;
}

export interface PairInfo {
  name: 'Blast Furnace' | 'Smelter';
  address: Address;
  quote: Address;
  quoteSymbol: 'tUSDC' | 'tWETH';
  quoteDecimals: number;
  receipt: 'tBLAST-LP' | 'tSMELT-LP';
  pool: Address; // the Forge pool that stakes this pair's receipt
}

export class ManifestError extends Error {}

const addr = (m: Record<string, unknown>, key: string): Address => {
  const v = m[key];
  if (typeof v !== 'string') throw new ManifestError(`manifest: missing ${key}`);
  try {
    return getAddress(v);
  } catch {
    throw new ManifestError(`manifest: ${key} is not an address`);
  }
};

/** Validate a manifest; anything malformed is refused rather than half-used. */
export function parseManifest(m: unknown): Deployment {
  if (typeof m !== 'object' || m === null) throw new ManifestError('manifest: not an object');
  const r = m as Record<string, unknown>;
  const chainId = Number(r.chainId);
  if (!Number.isInteger(chainId)) throw new ManifestError('manifest: chainId');
  const pools = [0, 1, 2, 3].map((i) => addr(r, `ForgePool${i}`)) as Deployment['pools'];
  const pairs: Deployment['pairs'] = [
    { name: 'Blast Furnace', address: addr(r, 'BlastPool'), quote: addr(r, 'BlastPoolQuote'), quoteSymbol: 'tUSDC', quoteDecimals: 6, receipt: 'tBLAST-LP', pool: pools[0] },
    { name: 'Smelter', address: addr(r, 'SmelterPool'), quote: addr(r, 'SmelterPoolQuote'), quoteSymbol: 'tWETH', quoteDecimals: 18, receipt: 'tSMELT-LP', pool: pools[1] },
  ];
  return {
    chainId,
    ember: addr(r, 'EmberToken'),
    flow: addr(r, 'Flow'),
    lens: addr(r, 'ForgeLens'),
    rebates: addr(r, 'TestnetFeeRebate'),
    pairsLive: r.pairsLive === true,
    pairs,
    pools,
    // Older manifests predate Kindling; when the real one is live its three addresses are required.
    kindling: r.kindlingLive === true
      ? { address: addr(r, 'Kindling'), escrow: addr(r, 'GenesisFeeEscrow'), sink: addr(r, 'PermanentLiquidity') }
      : null,
  };
}

// The manifest exists only after the operator broadcasts (`pnpm testnet:deploy`).
const manifests = import.meta.glob('../../../deployments/testnet-4441.json', { eager: true, import: 'default' });

export function loadDeployment(): { deployment: Deployment | null; error: string | null } {
  const raw = Object.values(manifests)[0];
  if (raw === undefined) return { deployment: null, error: null };
  try {
    return { deployment: parseManifest(raw), error: null };
  } catch (e) {
    return { deployment: null, error: (e as Error).message };
  }
}
