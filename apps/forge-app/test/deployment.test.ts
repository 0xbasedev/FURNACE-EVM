import { describe, expect, it } from 'vitest';
import { parseManifest, ManifestError, loadDeployment } from '../src/deployment';

import { MANIFEST } from './fixtures';

describe('the testnet manifest', () => {
  it('parses what DeployTestnet writes', () => {
    const d = parseManifest(MANIFEST);
    expect(d.chainId).toBe(4441);
    expect(d.pairs[0].pool).toBe(d.pools[0]);
    expect(d.pairs[1].quoteDecimals).toBe(18);
    expect(d.pairsLive).toBe(true);
  });
  it('refuses a malformed one rather than half-using it', () => {
    expect(() => parseManifest({ ...MANIFEST, Flow: 'nope' })).toThrow(ManifestError);
    expect(() => parseManifest({ ...MANIFEST, ForgePool3: undefined })).toThrow(/ForgePool3/);
    expect(() => parseManifest(null)).toThrow(ManifestError);
  });
  it('before the first broadcast there is no manifest, and no error', () => {
    expect(loadDeployment()).toEqual({ deployment: null, error: null });
  });
});
