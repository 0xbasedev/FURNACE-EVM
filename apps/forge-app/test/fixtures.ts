// A manifest shaped as contracts/script/DeployTestnet.s.sol writes it, with placeholder addresses.
const a = (n: number) => `0x${n.toString(16).padStart(40, '0')}`;
export const MANIFEST = {
  chainId: 4441, EmberToken: a(1), Flow: a(2), ForgeLens: a(3), TestnetFeeRebate: a(4),
  BlastPool: a(5), BlastPoolQuote: a(6), SmelterPool: a(7), SmelterPoolQuote: a(8), pairsLive: true,
  ForgePool0: a(10), ForgePool1: a(11), ForgePool2: a(12), ForgePool3: a(13),
};
