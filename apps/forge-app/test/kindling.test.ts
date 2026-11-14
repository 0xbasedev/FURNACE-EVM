import { describe, expect, it } from 'vitest';
import {
  decodeFunctionData, encodeAbiParameters, encodeFunctionResult, getAddress, type Address, type Hex,
} from 'viem';
import { KindlingModel, DURATION, SETTLE_WINDOW, MIN_RAISE, U, Status as MStatus } from '@model/kindling-model';
import { Revert } from '@model/pair-model';
import { KINDLING, TOKEN } from '../src/abi';
import { parseManifest, ManifestError } from '../src/deployment';
import {
  admit, bountyOf, cancelPreview, canFail, clock, demoState, headroom, openingPrice, phaseOf, shareOf, usd,
  Status, type KindlingState,
} from '../src/kindling';
import { calls, clients, contribute, kindlingCall, kindlingState, type Eip1193 } from '../src/wallet';
import { MANIFEST } from './fixtures';

const T0 = 1_800_000_000n;
const a = (n: number) => getAddress(`0x${n.toString(16).padStart(40, '0')}`);
const KM = { ...MANIFEST, kindlingLive: true, Kindling: a(20), GenesisFeeEscrow: a(21), PermanentLiquidity: a(22) };

/** The screen's state for wallet `i`, read off the model as the contract's views would return it. */
function stateOf(m: KindlingModel, i: number, venue = 0): KindlingState {
  const c = m.w[i];
  return {
    decimals: 6, status: m.status as unknown as Status, start: m.start, end: m.end, deadline: m.deadline,
    minContribution: 1n * U, walletCap: 25_000n * U, minRaise: MIN_RAISE, maxRaise: 5_000_000n * U,
    accepted: m.accepted, totalNet: m.totalNet, totalFees: m.totalFees, closedAt: m.closedAt,
    liquidity: m.liquidity, contributorLp: m.contributorLp,
    me: { gross: c.gross, net: c.net, fee: c.fee, done: c.done },
    entitlement: m.entitlementOf(i), refundable: m.refundableOf(i), venue,
  };
}
const reverts = (f: () => unknown) => { try { f(); return null; } catch (e) { if (e instanceof Revert) return e.message; throw e; } };

describe('Kindling arithmetic, against the model', () => {
  it('admits and refuses exactly as contribute does, with the same fee and net', () => {
    const m = new KindlingModel(T0);
    m.setNow(T0);
    const tries: [number, bigint][] = [[0, 25_000n * U], [0, 1n], [1, U - 1n], [1, U], [1, 24_999n * U], [1, 2n * U], [2, 33_333_333n], [3, 10_000n * U]];
    for (const [i, gross] of tries) {
      const want = admit(stateOf(m, i), gross, m.now);
      const why = reverts(() => m.contribute(i, gross));
      expect(want.ok, `wallet ${i} gross ${gross}`).toBe(why === null);
      if (why === null) {
        const c = m.w[i];
        expect(c.fee > 0n || gross < 34n).toBe(true);
        expect(want.fee).toBe((gross * 300n) / 10_000n);
        expect(want.net).toBe(gross - want.fee);
      }
    }
    m.setNow(m.end);
    expect(admit(stateOf(m, 4), 100n * U, m.now).ok).toBe(false);
    expect(reverts(() => m.contribute(4, 100n * U))).toBe('NotOpen');
  });

  it('previews a cancellation’s base exactly, rounded up', () => {
    const m = new KindlingModel(T0);
    m.setNow(T0);
    m.contribute(0, 25_000n * U);
    for (const amount of [1n, 7n, 3_333n * U + 1n, 1_000n * U]) {
      const p = cancelPreview(stateOf(m, 0), amount);
      const [grossOut] = m.cancel(0, amount);
      expect(p.ok).toBe(true);
      expect(p.grossOut).toBe(grossOut);
      expect(p.back).toBe(amount);
    }
    expect(cancelPreview(stateOf(m, 0), m.w[0].net + 1n).ok).toBe(false);
    expect(cancelPreview(stateOf(m, 1), 1n).ok).toBe(false);
  });

  it('estimates each wallet’s LP as settlement will pay it, and the settler’s bounty', () => {
    const m = new KindlingModel(T0);
    m.setNow(T0);
    const grosses = [25_000n * U, 25_000n * U, 24_123n * U, 25_000n * U, 7_777n * U, 100n * U];
    grosses.forEach((g, i) => m.contribute(i, g));
    m.cancel(4, 500n * U);
    const before = grosses.map((_, i) => shareOf(m.totalNet, m.w[i].net, 6));
    const bounty = bountyOf(stateOf(m, 0));
    m.setNow(m.end);
    m.settle();
    expect(m.keeper).toBe(bounty);
    grosses.forEach((_, i) => {
      expect(before[i].lp, `wallet ${i}`).toBe(m.entitlementOf(i));
      expect(stateOf(m, i).entitlement).toBe(before[i].lp);
    });
    // The spec's $100 example: $97 net, about $87.30 of quote-side reserves, and as much in EMBER at the opening price.
    const hundred = before[5];
    expect(Number(hundred.quoteSide) / 1e6).toBeCloseTo(87.3, 4);
    expect(Number(hundred.emberAtOpen) / 1e6).toBeCloseTo(87.3, 4);
    expect(hundred.staked).toBe(hundred.lp - hundred.lp / 100n);
    expect(openingPrice(m.totalNet)).toBe((m.totalNet * 10n ** 18n) / (420_000n * 10n ** 18n));
  });

  it('reads the phase at every edge, as settle and fail decide it', () => {
    const m = new KindlingModel(T0);
    m.setNow(T0);
    for (let i = 0; i < 4; i++) m.contribute(i, 25_000n * U);
    const s = stateOf(m, 0);
    expect(phaseOf(s, T0 - 1n)).toBe('pending');
    expect(phaseOf(s, T0)).toBe('open');
    expect(phaseOf(s, m.end - 1n)).toBe('open');
    expect(phaseOf(s, m.end)).toBe('settleable');
    expect(phaseOf(stateOf(m, 0, 1), m.end)).toBe('waiting');
    expect(phaseOf(s, m.deadline - 1n)).toBe('settleable');
    expect(phaseOf(s, m.deadline)).toBe('expired');
    expect(canFail(s, m.end)).toBe(false);
    expect(canFail(s, m.deadline)).toBe(true);
    m.setNow(m.end);
    expect(reverts(() => m.fail())).toBe('StillSettleable');
    m.cancel(0, 1n);
    const short = stateOf(m, 0);
    expect(phaseOf(short, m.end)).toBe('short');
    expect(canFail(short, m.end)).toBe(true);
    expect(reverts(() => m.fail())).toBeNull();
    expect(m.status).toBe(MStatus.Failed);
    expect(phaseOf(stateOf(m, 0), m.end)).toBe('failed');
    expect(stateOf(m, 0).refundable).toBe(m.w[0].net + m.w[0].fee);
  });

  it('formats dollars, clocks and the demo event plainly', () => {
    expect(usd(1_234_567_891n, 6)).toBe('$1,234.56');
    expect(usd(25_000n * U, 6, 0)).toBe('$25,000');
    expect(clock(3_725n)).toBe('01:02:05');
    expect(clock(DURATION + SETTLE_WINDOW)).toBe('4d 00h 00m');
    expect(clock(-5n)).toBe('00:00:00');
    const d = demoState(T0);
    expect(phaseOf(d, T0)).toBe('open');
    expect(headroom(d)).toBe(25_000n * U);
    expect(admit(d, 100n * U, T0).ok).toBe(true);
  });
});

describe('Kindling in the manifest', () => {
  it('reads the real Kindling when it is live, and none otherwise', () => {
    expect(parseManifest(KM).kindling).toEqual({ address: a(20), escrow: a(21), sink: a(22) });
    expect(parseManifest(MANIFEST).kindling).toBeNull();
    expect(parseManifest({ ...KM, kindlingLive: false }).kindling).toBeNull();
  });
  it('refuses a live Kindling without its addresses', () => {
    expect(() => parseManifest({ ...KM, Kindling: undefined })).toThrow(/Kindling/);
    expect(() => parseManifest({ ...KM, GenesisFeeEscrow: 'nope' })).toThrow(ManifestError);
  });
});

const ACCOUNT = getAddress('0x00000000000000000000000000000000000a11ce');

/** A wallet that answers Kindling's views and USDC's allowance, and records every transaction. */
function mockWallet(o: { allowance?: bigint } = {}) {
  const sent: { to: Address; data: Hex }[] = [];
  const d = parseManifest(KM);
  const receipts = new Map<string, unknown>();
  const views: Record<string, unknown> = {
    status: 0, START: T0, END: T0 + DURATION, SETTLE_DEADLINE: T0 + DURATION + SETTLE_WINDOW,
    MIN_CONTRIBUTION: U, WALLET_CAP: 25_000n * U, MIN_RAISE, MAX_RAISE: 5_000_000n * U,
    accepted: 120_000n * U, totalNet: 116_400n * U, totalFees: 3_600n * U, closedAt: 0n, liquidity: 0n, contributorLp: 0n,
    contributions: [1_000n * U, 970n * U, 30n * U, false], entitlementOf: 0n, refundableOf: 1_000n * U, venueCheck: 1,
  };
  const p: Eip1193 = {
    async request({ method, params }) {
      switch (method) {
        case 'eth_chainId': return '0x1159';
        case 'eth_blockNumber': return '0x10';
        case 'eth_call': {
          const { to, data } = (params as [{ to: Address; data: Hex }])[0];
          if (getAddress(to) === d.kindling!.address) {
            const call = decodeFunctionData({ abi: KINDLING, data });
            const v = views[call.functionName];
            return encodeFunctionResult({ abi: KINDLING, functionName: call.functionName, result: v as never });
          }
          const call = decodeFunctionData({ abi: TOKEN, data });
          if (call.functionName === 'allowance') return encodeAbiParameters([{ type: 'uint256' }], [o.allowance ?? 0n]);
          throw new Error(`unexpected eth_call ${call.functionName}`);
        }
        case 'eth_sendTransaction': {
          const tx = (params as [{ to: Address; data: Hex }])[0];
          sent.push({ to: getAddress(tx.to), data: tx.data });
          const hash = `0x${sent.length.toString(16).padStart(64, '0')}`;
          receipts.set(hash, {
            transactionHash: hash, blockHash: `0x${'b'.repeat(64)}`, blockNumber: '0x10', transactionIndex: '0x0',
            from: ACCOUNT, to: tx.to, cumulativeGasUsed: '0x1', gasUsed: '0x1', effectiveGasPrice: '0x1',
            contractAddress: null, logs: [], logsBloom: `0x${'0'.repeat(512)}`, status: '0x1', type: '0x2',
          });
          return hash;
        }
        case 'eth_getTransactionReceipt': return receipts.get((params as [string])[0]) ?? null;
        default: throw new Error(`unexpected ${method}`);
      }
    },
  };
  return { p, sent, d };
}

describe('Kindling through the wallet', () => {
  it('reads the whole event for one wallet', async () => {
    const w = mockWallet();
    const s = await kindlingState(clients(w.p, ACCOUNT).read, w.d, ACCOUNT);
    expect(s.accepted).toBe(120_000n * U);
    expect(s.me).toEqual({ gross: 1_000n * U, net: 970n * U, fee: 30n * U, done: false });
    expect(s.venue).toBe(1);
    expect(s.decimals).toBe(6);
    expect(phaseOf(s, T0 + DURATION)).toBe('waiting');
  });

  it('approves exactly the contribution, then contributes', async () => {
    const w = mockWallet();
    await contribute(clients(w.p, ACCOUNT), w.d, 250n * U);
    expect(w.sent).toHaveLength(2);
    expect(w.sent[0].to).toBe(w.d.pairs[0].quote);
    const approve = decodeFunctionData({ abi: TOKEN, data: w.sent[0].data });
    expect(approve.functionName).toBe('approve');
    expect(approve.args).toEqual([w.d.kindling!.address, 250n * U]);
    expect(w.sent[1]).toEqual({ to: w.d.kindling!.address, data: calls.contribute(250n * U) });
  });

  it('skips the approval when the allowance already covers it', async () => {
    const w = mockWallet({ allowance: 10_000n * U });
    const r = await contribute(clients(w.p, ACCOUNT), w.d, 250n * U);
    expect(r.hashes).toHaveLength(1);
    expect(w.sent).toHaveLength(1);
  });

  it('sends cancel, settle, fail, refund and materialize to Kindling, claims for the caller only', async () => {
    const w = mockWallet();
    const c = clients(w.p, ACCOUNT);
    await kindlingCall(c, w.d, { kind: 'cancel', amount: 5n * U });
    await kindlingCall(c, w.d, { kind: 'settle' });
    await kindlingCall(c, w.d, { kind: 'fail' });
    await kindlingCall(c, w.d, { kind: 'refund' });
    await kindlingCall(c, w.d, { kind: 'materialize' });
    const decoded = w.sent.map((t) => { expect(t.to).toBe(w.d.kindling!.address); return decodeFunctionData({ abi: KINDLING, data: t.data }); });
    expect(decoded.map((x) => x.functionName)).toEqual(['cancel', 'settle', 'fail', 'refund', 'materialize']);
    expect(decoded[0].args).toEqual([5n * U]);
    expect(decoded[3].args).toEqual([ACCOUNT]);
    expect(decoded[4].args).toEqual([ACCOUNT]);
  });

  it('refuses to act on a deployment without Kindling', async () => {
    const w = mockWallet();
    const plain = parseManifest(MANIFEST);
    await expect(contribute(clients(w.p, ACCOUNT), plain, U)).rejects.toThrow(/no Kindling/);
    await expect(kindlingState(clients(w.p, ACCOUNT).read, plain, ACCOUNT)).rejects.toThrow(/no Kindling/);
  });
});
