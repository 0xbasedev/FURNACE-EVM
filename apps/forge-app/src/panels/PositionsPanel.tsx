import { useEffect, useState } from 'react';
import type { Address } from 'viem';
import type { Deployment } from '../deployment';
import { LENS } from '../abi';
import { heatAt } from '@sim/engine/heat';
import { planExit } from '@sim/engine/exit';
import { amount } from '../format';
import { clients, positionsOf, type Eip1193 } from '../wallet';

interface Row { pool: number; id: bigint; custody: bigint; ageDays: number; streakDays: number; heat: number }

/** The wallet's Forge positions in the two LP pools: custody, Heat, and what leaving would cost. */
export function PositionsPanel({ d, provider, account, onLiteForge, onAdd, tick }: {
  d: Deployment | null; provider: Eip1193 | null; account: Address | null; onLiteForge: boolean;
  onAdd: (pool: number, id: bigint) => void; tick: number;
}) {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!d || !account) return;
    let stop = false;
    const { read } = clients(onLiteForge ? provider : null, account);
    (async () => {
      const out: Row[] = [];
      const now = Math.floor(Date.now() / 1000);
      for (const pool of [0, 1]) {
        const address = d.pools[pool];
        for (const id of await positionsOf(read, address, account)) {
          const p = (await read.readContract({ address: d.lens, abi: LENS, functionName: 'positionOf', args: [address, id] })) as {
            owner: Address; streakStart: number; usedMask: number; closedAt: number;
          };
          if (p.owner.toLowerCase() !== account.toLowerCase() || p.closedAt !== 0) continue;
          const custody = (await read.readContract({ address: d.lens, abi: LENS, functionName: 'custodyOf', args: [address, id] })) as bigint;
          // Amount-weighted financial age over the position's lots.
          let weighted = 0, total = 0;
          for (let slot = 0; slot < 32; slot++) {
            if ((p.usedMask & (1 << slot)) === 0) continue;
            const lot = (await read.readContract({ address: d.lens, abi: LENS, functionName: 'lotOf', args: [address, id, BigInt(slot)] })) as {
              since: number; amount: bigint; age: number;
            };
            const w = Number(lot.amount) / 1e18;
            weighted += w * (lot.age + Math.max(0, now - Number(lot.since)));
            total += w;
          }
          const ageDays = total > 0 ? weighted / total / 86_400 : 0;
          out.push({ pool, id, custody, ageDays, streakDays: (now - Number(p.streakStart)) / 86_400, heat: heatAt(ageDays) });
        }
      }
      if (!stop) { setRows(out); setError(null); }
    })().catch((e) => !stop && setError((e as Error).message));
    return () => { stop = true; };
  }, [d, provider, account, onLiteForge, tick]);

  return (
    <section className="panel wide" aria-labelledby="pos-h">
      <header>
        <span className="eyebrow">The Forge</span>
        <h2 id="pos-h">Your positions</h2>
        <p className="lede">Heat grows with financial age. Adding through a zap keeps every receipt; leaving starts a cooling timer and costs Heat.</p>
      </header>
      {!d && <p className="lede">Nothing is deployed yet, so there is nothing to show.</p>}
      {d && !account && <p className="lede">Connect a wallet to see your positions.</p>}
      {error && <div className="nudge bad"><span className="ico" aria-hidden="true">!</span><span>{error}</span></div>}
      {rows && rows.length === 0 && <p className="lede">No open positions in the LP pools yet. Zap &amp; stake opens one.</p>}
      {rows && rows.length > 0 && (
        <div className="positions">
          {rows.map((r) => {
            const exit = planExit({ stake: r.custody, ageDays: r.ageDays, pct: 10, planUsedPct: 0 });
            return (
              <article key={`${r.pool}-${r.id}`} className="position">
                <div className="row between">
                  <b>{r.pool === 0 ? 'Blast Furnace' : 'Smelter'} · #{r.id.toString()}</b>
                  <span className="pill good">{r.heat.toFixed(3)}× Heat</span>
                </div>
                <div className="figures">
                  <div className="figure"><span className="k">Staked</span><span className="v">{amount(r.custody, 18)}</span><span className="s">{r.pool === 0 ? 'tBLAST-LP' : 'tSMELT-LP'}</span></div>
                  <div className="figure"><span className="k">Financial age</span><span className="v">{r.ageDays.toFixed(1)}d</span><span className="s">Streak {r.streakDays.toFixed(1)}d</span></div>
                  <div className="figure"><span className="k">Taking 10% out</span><span className="v">{exit.tierHours}h</span><span className="s">cooling, 1% fee, Heat {exit.heatBefore.toFixed(3)}→{exit.heatAfter.toFixed(3)}</span></div>
                </div>
                <div className="row">
                  <button type="button" className="btn primary" onClick={() => onAdd(r.pool, r.id)}>Add fee-free</button>
                  <span className="unit">Cooling and withdrawals run from the pool itself; the Forge Simulator prices them in full.</span>
                </div>
              </article>
            );
          })}
        </div>
      )}
    </section>
  );
}
