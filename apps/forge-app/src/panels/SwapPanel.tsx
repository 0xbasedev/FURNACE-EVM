import { useMemo, useState } from 'react';
import type { Deployment } from '../deployment';
import type { Market } from '../useMarket';
import { midPrice, quoteSwap, tierName } from '../quote';
import { assess, DEFAULT_SLIPPAGE_BPS, IMPACT_BLOCK_PPM, IMPACT_WARN_PPM, withSlippage } from '../policy';
import { amount, parseAmount, pct } from '../format';
import { clients, deadlineIn, swap, type Eip1193 } from '../wallet';
import { Field, Nudges, REASONS, Slippage, TxStatus, errorText, type TxState } from './Common';

const QUOTES = [{ sym: 'tUSDC', dec: 6 }, { sym: 'tWETH', dec: 18 }] as const;

/** A swap through Flow, at the wallet's Relic rebate, with the fee shown lane by lane. */
export function SwapPanel({ d, market, provider, account, canSend, onDone }: {
  d: Deployment | null; market: Market; provider: Eip1193 | null; account: `0x${string}` | null;
  canSend: string | null; onDone: () => void;
}) {
  const [pair, setPair] = useState(0);
  const [buy, setBuy] = useState(true);
  const [text, setText] = useState('100');
  const [bps, setBps] = useState(DEFAULT_SLIPPAGE_BPS);
  const [tx, setTx] = useState<TxState>({ kind: 'idle' });
  const qt = QUOTES[pair];
  const inDec = buy ? qt.dec : 18;
  const outDec = buy ? 18 : qt.dec;
  const amountIn = parseAmount(text, inDec);
  const q = useMemo(() => quoteSwap(market.pairs[pair], buy, amountIn, market.share), [market, pair, buy, amountIn]);
  const a = assess({ impactPpm: q.ok ? q.impactPpm : 0n, slippageBps: bps, selling: !buy });
  const minOut = q.ok ? withSlippage(q.out, bps) : 0n;
  const blocked = a.level === 'blocked' || !q.ok || amountIn === 0n;

  const submit = async () => {
    if (!d || !account || !q.ok) return;
    setTx({ kind: 'pending', label: buy ? 'Buy' : 'Sell' });
    try {
      const r = await swap(clients(provider, account), d, { pair, buy, amountIn, minOut, deadline: deadlineIn(20 * 60) });
      setTx({ kind: 'done', label: buy ? 'Buy' : 'Sell', hashes: r.hashes });
      onDone();
    } catch (e) {
      setTx({ kind: 'failed', label: buy ? 'Buy' : 'Sell', message: errorText(e) });
    }
  };

  const lanes = q.ok ? [
    { k: 'LP', v: q.fee.lp, cls: 'lp', note: 'stays in the pool' },
    { k: 'Burn', v: q.fee.burn, cls: 'burn', note: 'to the Vent' },
    { k: 'Liquidity', v: q.fee.liquidity, cls: 'liq', note: 'permanent liquidity' },
    { k: 'Quote yield', v: q.fee.quoteYield, cls: 'qy', note: 'to loyal stakers' },
  ].filter((l) => l.v > 0n) : [];

  return (
    <section className="panel wide" aria-labelledby="swap-h">
      <header>
        <span className="eyebrow">Flow</span>
        <h2 id="swap-h">Swap</h2>
        <p className="lede">Buys pay 25 bps and sells 35 bps, every part in the quote asset. A Relic rebate cuts the protocol's share, never the LPs'.</p>
      </header>
      <div className="row">
        <div className="seg" role="group" aria-label="Pool">
          {QUOTES.map((x, i) => (
            <button key={x.sym} type="button" aria-pressed={pair === i} onClick={() => setPair(i)}>EMBER/{x.sym}</button>
          ))}
        </div>
        <div className="seg" role="group" aria-label="Direction">
          <button type="button" aria-pressed={buy} onClick={() => setBuy(true)}>Buy EMBER</button>
          <button type="button" aria-pressed={!buy} onClick={() => setBuy(false)}>Sell EMBER</button>
        </div>
        <span className="unit">1 EMBER ≈ {midPrice(market.pairs[pair]).toPrecision(5)} {qt.sym}</span>
      </div>
      <Field label={`You pay (${buy ? qt.sym : 'EMBER'})`} aside={<span className="unit">{tierName(market.share)}</span>}>
        <input className="input big" inputMode="decimal" value={text} onChange={(e) => setText(e.target.value)} aria-label="Amount in" />
      </Field>
      {q.ok ? (
        <>
          <div className="figures">
            <div className="figure"><span className="k">You receive</span><span className="v">{amount(q.out, outDec)}</span><span className="s">{buy ? 'EMBER' : qt.sym}</span></div>
            <div className="figure"><span className="k">Fee</span><span className="v">{amount(q.fee.total, qt.dec, 6)}</span><span className="s">{qt.sym}</span></div>
            <div className="figure"><span className="k">Price impact</span><span className={`v ${q.impactPpm > IMPACT_BLOCK_PPM ? 'bad-text' : q.impactPpm > IMPACT_WARN_PPM ? 'warn-text' : ''}`}>{pct(q.impactPpm)}</span><span className="s">the curve alone</span></div>
          </div>
          <div className="lanes" role="list" aria-label="Fee by lane">
            {lanes.map((l) => (
              <div key={l.k} role="listitem" className={`lane ${l.cls}`} style={{ flexGrow: Number(l.v) }}>
                <span>{l.k}</span><b>{amount(l.v, qt.dec, 6)}</b><i>{l.note}</i>
              </div>
            ))}
          </div>
        </>
      ) : (
        <div className="nudge warn"><span className="ico" aria-hidden="true">i</span><span>{REASONS[q.reason] ?? q.reason}</span></div>
      )}
      <Slippage bps={bps} set={setBps} />
      <Nudges a={a} />
      <div className="row">
        <button type="button" className="btn primary big" disabled={blocked || canSend !== null} onClick={submit} title={canSend ?? undefined}>
          {canSend ?? (buy ? `Buy EMBER with ${text || 0} ${qt.sym}` : `Sell ${text || 0} EMBER`)}
        </button>
        {q.ok && <span className="unit">Minimum {amount(minOut, outDec)} {buy ? 'EMBER' : qt.sym} or it reverts.</span>}
      </div>
      <TxStatus s={tx} />
    </section>
  );
}
