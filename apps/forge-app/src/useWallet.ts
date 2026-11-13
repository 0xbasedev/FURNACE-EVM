import { useCallback, useEffect, useState } from 'react';
import type { Address } from 'viem';
import { LITEFORGE } from './chain';
import { chainIdOf, connect, ensureLiteForge, type Eip1193 } from './wallet';

const injected = (): Eip1193 | null =>
  typeof window !== 'undefined' ? ((window as unknown as { ethereum?: Eip1193 }).ethereum ?? null) : null;

export interface WalletState {
  provider: Eip1193 | null;
  account: Address | null;
  chainId: number | null;
  onLiteForge: boolean;
  busy: boolean;
  error: string | null;
  connect: () => Promise<void>;
  switchChain: () => Promise<void>;
}

export function useWallet(): WalletState {
  const [provider] = useState(injected);
  const [account, setAccount] = useState<Address | null>(null);
  const [chainId, setChainId] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!provider) return;
    const onAccounts = (a: unknown) => setAccount(((a as Address[])[0] ?? null) as Address | null);
    const onChain = (c: unknown) => setChainId(Number(c));
    provider.on?.('accountsChanged', onAccounts);
    provider.on?.('chainChanged', onChain);
    provider.request({ method: 'eth_accounts' }).then(onAccounts).catch(() => {});
    chainIdOf(provider).then(setChainId).catch(() => {});
    return () => {
      provider.removeListener?.('accountsChanged', onAccounts);
      provider.removeListener?.('chainChanged', onChain);
    };
  }, [provider]);

  const run = useCallback(async (f: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    try {
      await f();
    } catch (e) {
      setError((e as { shortMessage?: string; message?: string }).shortMessage ?? (e as Error).message);
    } finally {
      setBusy(false);
    }
  }, []);

  return {
    provider,
    account,
    chainId,
    onLiteForge: chainId === LITEFORGE.id,
    busy,
    error,
    connect: () => run(async () => {
      if (!provider) throw new Error('No browser wallet found. Install one, then reload.');
      setAccount(await connect(provider));
      setChainId(await chainIdOf(provider));
    }),
    switchChain: () => run(async () => {
      if (!provider) return;
      await ensureLiteForge(provider);
      setChainId(await chainIdOf(provider));
    }),
  };
}
