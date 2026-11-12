# Deployments

`contracts/script/DeployTestnet.s.sol` writes `testnet-<chain id>.json` here after a broadcast. Each manifest lists the addresses, the deployer and operator, the salt version and the Mantle's start. It also lists the EMBER pairs' addresses and quote tokens, and `pairsLive`, which is false when the pairs were left for `DeployTestnetPairs`; that script sets it once they deploy. Commit it together with forge's `broadcast/` record of the same run.

Only testnet manifests exist. Every one is a testnet deployment with stand-ins for unbuilt modules; see `docs/testnet/`. None is audited, and none is canonical.

`litvm-mainnet.gate.json` is not a deployment. It is the record that `pnpm mainnet:gate` checks before any LitVM mainnet deployment could be considered, and every field in it is unset today. See `docs/mainnet/litvm-readiness.md`.
