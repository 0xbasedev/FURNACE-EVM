// v5.3.2 decision tests: pro-rata Conviction return (Decision 1) and
// per-pool Casting (Decision 2). Run: pnpm test:config
import cfg, { castDestination, castForPool, epochAllocation, validateConfig } from '../furnace.config';

let pass = 0, fail = 0;
const t = (name: string, ok: boolean, detail = '') => { ok ? pass++ : fail++; console.log(`${ok ? '✓' : '✗'} ${name}${detail ? '   ' + detail : ''}`); };
const near = (a: number, b: number, eps = 1e-9) => Math.abs(a - b) <= eps * Math.max(1, Math.abs(b));
const sum = (xs: number[]) => xs.reduce((a, b) => a + b, 0);
const clone = () => JSON.parse(JSON.stringify(cfg));
const baseline = new Set(validateConfig(cfg));
const added = (mut: (c: any) => void) => { const c = clone(); mut(c); return validateConfig(c).filter((e) => !baseline.has(e)); };

console.log('── Decision 1: unused Conviction returns pro-rata ──');
// Nobody sealed: flat share is exactly 30% of the epoch, Heat share exactly 70%.
{
  const E = 21_600;
  const ps = [{ stake: 5, heat: 1, sealBonus: 0 }, { stake: 3, heat: 2.2, sealBonus: 0 }, { stake: 2, heat: 3, sealBonus: 0 }];
  const r = epochAllocation(E, ps);
  const S = sum(ps.map((p) => p.stake));
  const flatPart = ps.map((p) => 0.3 * E * p.stake / S);
  const heatPart = r.ordinary.map((o, i) => o - flatPart[i]);
  t('no seals: Σflat = 30% of E', near(sum(flatPart), 0.3 * E));
  t('no seals: Σheat = 70% of E', near(sum(heatPart), 0.7 * E));
  t('no seals: heat part ∝ stake·heat', ps.every((p, i) => near(heatPart[i] / (p.stake * p.heat), heatPart[0] / (ps[0].stake * ps[0].heat))));
  t('no seals: returned = whole bucket (10%)', near(r.returned, 0.1 * E));
}
// Some sealed: escrow caps unchanged from v5.3.1 (L = 0.7·0.9·E), conservation holds,
// and the returned remainder splits 30/70.
{
  const E = 10_000;
  const ps = [{ stake: 10, heat: 3.65, sealBonus: 0.5 }, { stake: 990, heat: 1, sealBonus: 0 }];
  const r = epochAllocation(E, ps);
  t('sealer escrow still = additive cap 30.6868', near(r.escrow[0], 30.686799805163172));
  t('conservation Σordinary+Σescrow = E', near(sum(r.ordinary) + sum(r.escrow), E));
  const S = 1000, W = 10 * 3.65 + 990;
  const flatPool = 0.3 * 0.9 * E + 0.3 * r.returned;
  const heatPool = 0.7 * 0.9 * E + 0.7 * r.returned;
  t('returned remainder splits 30/70', ps.every((p, i) => near(r.ordinary[i], flatPool * p.stake / S + heatPool * p.stake * p.heat / W)));
}
t('validator rejects heatPool return', added((c) => c.forge.convictionTracks.bucketCap.unallocatedFlowsTo = 'heatPool').length > 0);

console.log('\n── Decision 2: per-pool Casting ──');
const pool = (id: string) => cfg.forge.pools.find((p) => p.id === id)!;
t('Blast Furnace → source-lot LP', castDestination(pool('ember-usdc-lp')) === 'sourceLotLp');
t('Smelter → source-lot LP', castDestination(pool('ember-weth-lp')) === 'sourceLotLp');
t('Ember Vault → source-lot EMBER', castDestination(pool('ember-single')) === 'sourceLotEmber');
t('Cold Storage → liquid EMBER', castDestination(pool('usdc-single')) === 'liquidEmber');
{
  const v = castForPool(1000, 0, pool('ember-single'));
  t('Ember Vault casts 25% with a dry match reserve', near(v.cast, 250) && near(v.liquid, 750));
  const lp = castForPool(1000, 100, pool('ember-usdc-lp'));
  t('LP pool cast bounded by reserve coverage (never market-sells)', near(lp.cast, 100) && near(lp.liquid, 900));
  const cs = castForPool(1000, 1e9, pool('usdc-single'));
  t('Cold Storage pays everything liquid', cs.cast === 0 && cs.liquid === 1000);
  t('every pool conserves the emission', cfg.forge.pools.every((p) => { const x = castForPool(777, 50, p); return near(x.cast + x.liquid, 777); }));
}
t('validator rejects liquid EMBER for Ember Vault', added((c) => c.forge.casting.singleTokenCast.ember = 'liquidEmber').length > 0);
t('validator rejects missing singleTokenCast', added((c) => { delete c.forge.casting.singleTokenCast; }).length > 0);
t('copy exists for both single-token casting notes', !!cfg.copy.warnings.castingNoteSingleEmber && !!cfg.copy.warnings.castingNoteSingleOther);

console.log(`\n══ ${pass} passed, ${fail} failed ══`);
process.exit(fail ? 1 : 0);
