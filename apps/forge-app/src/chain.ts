import { defineChain } from 'viem';

/** LitVM LiteForge, the testnet this dApp serves (docs/testnet/litvm-liteforge.md). */
export const LITEFORGE = defineChain({
  id: 4441,
  name: 'LitVM LiteForge',
  nativeCurrency: { name: 'zkLTC', symbol: 'zkLTC', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.liteforge.zeeve.net/'] } },
  blockExplorers: { default: { name: 'Blockscout', url: 'https://explorer.testnet.liteforge.zeeve.net' } },
  testnet: true,
});

export const CHAIN_ID_HEX = `0x${LITEFORGE.id.toString(16)}`;

/** The parameters `wallet_addEthereumChain` takes for LiteForge. */
export const ADD_CHAIN_PARAMS = {
  chainId: CHAIN_ID_HEX,
  chainName: LITEFORGE.name,
  nativeCurrency: LITEFORGE.nativeCurrency,
  rpcUrls: [...LITEFORGE.rpcUrls.default.http],
  blockExplorerUrls: [LITEFORGE.blockExplorers.default.url],
};

export const explorerTx = (hash: string) => `${LITEFORGE.blockExplorers.default.url}/tx/${hash}`;
