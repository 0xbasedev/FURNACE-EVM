import { useCallback, useEffect, useState } from 'react';
import type { Address } from 'viem';
import type { Deployment } from './deployment';
import { DEMO, type PairState } from './quote';
import { clients, pairState, rebateShareOf, type Eip1193 } from './wallet';

export interface Market {
  pairs: [PairState, PairState];
  share: bigint; // the connected wallet's protocol-share scale (10⁶ = no rebate)
  live: boolean; // read from the chain, not the demo
  refresh: () => void;
  error: string | null;
}

/** Reserves for both pairs and the wallet's rebate: live when deployed, the demo otherwise. */
export function useMarket(d: Deployment | null, provider: Eip1193 | null, account: Address | null, onLiteForge: boolean): Market {
  const [pairs, setPairs] = useState<[PairState, PairState]>(DEMO);
  const [share, setShare] = useState(1_000_000n);
  const [live, setLive] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const refresh = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!d || !d.pairsLive) return;
    let stop = false;
    // Reads use the wallet's provider only while it is on LiteForge; otherwise the public RPC.
    const { read } = clients(onLiteForge ? provider : null, account ?? d.flow);
    Promise.all([pairState(read, d.pairs[0].address, 6), pairState(read, d.pairs[1].address, 18)])
      .then(async ([a, b]) => {
        if (stop) return;
        setPairs([a, b]);
        setLive(true);
        setError(null);
        if (account) setShare(await rebateShareOf(read, d, account));
      })
      .catch((e) => !stop && setError((e as Error).message));
    const t = setInterval(() => setTick((x) => x + 1), 15_000);
    return () => { stop = true; clearInterval(t); };
  }, [d, provider, account, onLiteForge, tick]);

  return { pairs, share, live, refresh, error };
}
