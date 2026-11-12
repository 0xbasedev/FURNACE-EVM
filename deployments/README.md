# Deployments

`contracts/script/DeployTestnet.s.sol` writes `testnet-<chain id>.json` here after a broadcast. Each manifest lists the addresses, the deployer and operator, the salt version and the Mantle's start. Commit it together with forge's `broadcast/` record of the same run.

Only testnet manifests exist. Every one is a testnet deployment with stand-ins for unbuilt modules; see `docs/testnet/`. None is audited, and none is canonical.
