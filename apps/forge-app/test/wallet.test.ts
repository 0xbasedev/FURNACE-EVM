import { describe, expect, it } from 'vitest';
import {
  decodeFunctionData, encodeAbiParameters, encodeEventTopics, getAddress, maxUint256, type Address, type Hex,
} from 'viem';
import { FLOW, TOKEN } from '../src/abi';
import { parseManifest } from '../src/deployment';
import { clients, connect, ensureLiteForge, zapAndStake, swap, calls, deadlineIn, type Eip1193 } from '../src/wallet';
import { MANIFEST } from './fixtures';

const ACCOUNT = getAddress('0x00000000000000000000000000000000000a11ce');

/** A wallet that records every request and answers what the flows need. */
function mockWallet(o: { chainId?: number; knowsLiteForge?: boolean; allowance?: bigint; zapped?: { liquidity: bigint; position: bigint } } = {}) {
  let chainId = o.chainId ?? 4441;
  const sent: { to: Address; data: Hex }[] = [];
  const methods: string[] = [];
  const d = parseManifest(MANIFEST);
  const receipts = new Map<string, unknown>();
  const p: Eip1193 = {
    async request({ method, params }) {
      methods.push(method);
      switch (method) {
        case 'eth_requestAccounts':
        case 'eth_accounts':
          return [ACCOUNT];
        case 'eth_chainId':
          return `0x${chainId.toString(16)}`;
        case 'wallet_switchEthereumChain':
          if (o.knowsLiteForge === false) throw Object.assign(new Error('unknown chain'), { code: 4902 });
          chainId = 4441;
          return null;
        case 'wallet_addEthereumChain':
          chainId = 4441;
          return null;
        case 'eth_blockNumber':
          return '0x10';
        case 'eth_call': {
          const { data } = (params as [{ data: Hex }])[0];
          const call = decodeFunctionData({ abi: TOKEN, data });
          if (call.functionName === 'allowance') return encodeAbiParameters([{ type: 'uint256' }], [o.allowance ?? 0n]);
          throw new Error(`unexpected eth_call ${call.functionName}`);
        }
        case 'eth_sendTransaction': {
          const tx = (params as [{ to: Address; data: Hex }])[0];
          sent.push({ to: getAddress(tx.to), data: tx.data });
          const hash = `0x${sent.length.toString(16).padStart(64, '0')}`;
          const logs = [];
          if (getAddress(tx.to) === d.flow && o.zapped) {
            const topics = encodeEventTopics({ abi: FLOW, eventName: 'Zapped', args: { user: ACCOUNT } });
            const data = encodeAbiParameters(
              [{ type: 'uint256' }, { type: 'bool' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }],
              [0n, true, 1n, 1n, o.zapped.liquidity, o.zapped.position],
            );
            logs.push({ address: d.flow, topics, data, blockNumber: '0x10', transactionHash: hash, transactionIndex: '0x0', blockHash: `0x${'b'.repeat(64)}`, logIndex: '0x0', removed: false });
          }
          receipts.set(hash, {
            transactionHash: hash, blockHash: `0x${'b'.repeat(64)}`, blockNumber: '0x10', transactionIndex: '0x0',
            from: ACCOUNT, to: tx.to, cumulativeGasUsed: '0x1', gasUsed: '0x1', effectiveGasPrice: '0x1',
            contractAddress: null, logs, logsBloom: `0x${'0'.repeat(512)}`, status: '0x1', type: '0x2',
          });
          return hash;
        }
        case 'eth_getTransactionReceipt':
          return receipts.get((params as [string])[0]) ?? null;
        default:
          throw new Error(`unexpected ${method}`);
      }
    },
  };
  return { p, sent, methods, d };
}

describe('the wallet', () => {
  it('connects and switches to LiteForge', async () => {
    const w = mockWallet({ chainId: 1 });
    expect(await connect(w.p)).toBe(ACCOUNT);
    await ensureLiteForge(w.p);
    expect(w.methods).toContain('wallet_switchEthereumChain');
    expect(w.methods).not.toContain('wallet_addEthereumChain');
  });
  it('adds LiteForge when the wallet does not know it (EIP-1193 code 4902)', async () => {
    const w = mockWallet({ chainId: 1, knowsLiteForge: false });
    await ensureLiteForge(w.p);
    expect(w.methods).toContain('wallet_addEthereumChain');
  });
});

describe('zap and stake', () => {
  it('approves exactly the amount, zaps, and reads the position from the Zapped event', async () => {
    const w = mockWallet({ zapped: { liquidity: 42n, position: 7n } });
    const c = clients(w.p, ACCOUNT);
    const r = await zapAndStake(c, w.d, { pair: 0, fromQuote: true, amountIn: 1000n, minLiquidity: 40n, position: 0n, deadline: 99n });
    expect(r.position).toBe(7n);
    expect(r.liquidity).toBe(42n);
    expect(w.sent).toHaveLength(2);
    const approve = decodeFunctionData({ abi: TOKEN, data: w.sent[0].data });
    expect(w.sent[0].to).toBe(w.d.pairs[0].quote);
    expect(approve).toMatchObject({ functionName: 'approve', args: [w.d.flow, 1000n] });
    const zap = decodeFunctionData({ abi: FLOW, data: w.sent[1].data });
    expect(w.sent[1].to).toBe(w.d.flow);
    expect(zap).toMatchObject({ functionName: 'zapAndStake', args: [0n, true, 1000n, 40n, 0n, 99n] });
  });
  it('skips the approval when the allowance covers it', async () => {
    const w = mockWallet({ allowance: maxUint256, zapped: { liquidity: 1n, position: 3n } });
    await zapAndStake(clients(w.p, ACCOUNT), w.d, { pair: 1, fromQuote: false, amountIn: 5n, minLiquidity: 0n, position: 3n, deadline: 1n });
    expect(w.sent).toHaveLength(1);
    expect(w.sent[0].to).toBe(w.d.flow);
  });
  it('a swap sends EMBER-side approvals to EMBER, with the caller as the recipient', async () => {
    const w = mockWallet();
    await swap(clients(w.p, ACCOUNT), w.d, { pair: 0, buy: false, amountIn: 9n, minOut: 1n, deadline: 2n });
    expect(w.sent[0].to).toBe(w.d.ember);
    expect(decodeFunctionData({ abi: FLOW, data: w.sent[1].data }).args).toEqual([0n, false, 9n, 1n, ACCOUNT, 2n]);
  });
});

describe('calldata', () => {
  it('matches the ABI exactly', () => {
    const data = calls.zapOut(1, 10n, true, 9n, 5n);
    expect(decodeFunctionData({ abi: FLOW, data })).toMatchObject({ functionName: 'zapOut', args: [1n, 10n, true, 9n, 5n] });
  });
  it('deadlines are seconds from now', () => {
    expect(deadlineIn(600, 1_000_000)).toBe(1600n);
  });
});
