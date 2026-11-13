import { useEffect, useState } from 'react';
import type { Address } from 'viem';
import type { Deployment } from '../deployment';
import { amount } from '../format';
import { balanceOf, clients, mint, type Eip1193 } from '../wallet';
import { TxStatus, errorText, type TxState } from './Common';

/** Test tokens: tUSDC and tWETH are open-mint stand-ins (up to 1,000,000 a call). EMBER is bought, not minted. */
export function FaucetPanel({ d, provider, account, onLiteForge, canSend, onDone, tick }: {
  d: Deployment | null; provider: Eip1193 | null; account: Address | null; onLiteForge: boolean;
  canSend: string | null; onDone: () => void; tick: number;
}) {
  const [bal, setBal] = useState<bigint[] | null>(null);
  const [tx, setTx] = useState<TxState>({ kind: 'idle' });
  const tokens = d ? [
    { sym: 'tUSDC', address: d.pairs[0].quote, dec: 6, drip: 10_000n * 10n ** 6n },
    { sym: 'tWETH', address: d.pairs[1].quote, dec: 18, drip: 5n * 10n ** 18n },
    { sym: 'EMBER', address: d.ember, dec: 18, drip: 0n },
  ] : [];

  useEffect(() => {
    if (!d || !account) return;
    const { read } = clients(onLiteForge ? provider : null, account);
    Promise.all(tokens.map((t) => balanceOf(read, t.address, account))).then(setBal).catch(() => setBal(null));
  }, [d, provider, account, onLiteForge, tick]); // eslint-disable-line react-hooks/exhaustive-deps

  const drip = async (t: (typeof tokens)[number]) => {
    if (!account) return;
    setTx({ kind: 'pending', label: `Mint ${t.sym}` });
    try {
      const r = await mint(clients(provider, account), t.address, t.drip);
      setTx({ kind: 'done', label: `Minted ${amount(t.drip, t.dec)} ${t.sym}`, hashes: r.hashes });
      onDone();
    } catch (e) {
      setTx({ kind: 'failed', label: `Mint ${t.sym}`, message: errorText(e) });
    }
  };

  return (
    <section className="panel wide" aria-labelledby="faucet-h">
      <header>
        <span className="eyebrow">Testnet only</span>
        <h2 id="faucet-h">Test tokens</h2>
        <p className="lede">Gas is zkLTC from the LiteForge faucet. tUSDC and tWETH are mintable stand-ins with no value. EMBER is never minted here: buy it on the Swap tab.</p>
      </header>
      <div className="row">
        <a className="btn" href="https://faucet.testnet.liteforge.zeeve.net/" target="_blank" rel="noreferrer">Get zkLTC for gas</a>
      </div>
      {tokens.length > 0 && (
        <div className="figures">
          {tokens.map((t, i) => (
            <div key={t.sym} className="figure">
              <span className="k">{t.sym}</span>
              <span className="v">{bal ? amount(bal[i], t.dec) : '—'}</span>
              {t.drip > 0n ? (
                <button type="button" className="btn" disabled={canSend !== null} onClick={() => drip(t)} title={canSend ?? undefined}>
                  Mint {amount(t.drip, t.dec)}
                </button>
              ) : (
                <span className="s">buy it on Swap</span>
              )}
            </div>
          ))}
        </div>
      )}
      <TxStatus s={tx} />
    </section>
  );
}
