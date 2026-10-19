# FURNACE v5.5 - Deployment gates

**No deployment is performed or authorized by a passing local test.** Ethereum is the selected initial chain; others remain disabled.

## Commands actually supplied

```
npm run typecheck
npm test
npm run check:config
npm run check:deploy
npm run config:hash
```

TypeScript5.8.3 is pinned. The local build uses an installed project compiler if available, otherwise `tsc` on PATH. Run with the pinned version for reproducible results. No deploy/mining command is advertised unless its implementation is actually added and tested. No network transaction is part of any supplied script.

## Gate A - Economic template

`check:config` must pass the source identity, conservation, format and derivation tests. Explicit null operational identities are allowed here only. At present the economic checks pass and operational deployment checks intentionally fail. Run mutation tests against specific diagnostic codes and paths, not only the number of errors.

## Gate B - Operational identities

Supply the actual Ethereum deployer and clear/recompute any old placeholder-sender fixtures. Mine missing salts once; preserve only entries valid for the current factory/sender/module inputs. All16 required modules must be accounted for. Verify the actual external WETH/USDC receipt contract and adapter; do not guess a pair address.

Select five real Safe owners and threshold3. Supply nonce, singleton, complete initializer and proxy init-code inputs, predicted Safe address and timelock identity. Confirm ownership with the actual operators. A valid EIP-55 spelling is not proof of control. No dummy address or invented account replaces these facts.

Require active guardians and Treasury identities by chain, not only keys already present in a map. Disabled Solana definitions impose no active deployment, but any populated Solana guardian is decoded as32-byte base58 rather than checked with EIP-55.

## Gate C - Build and contract evidence

Compile the actual custody, pool, supply, settlement, escrow and auction implementations. Pin source revision, dependencies, compiler/optimizer flags, constructor/initializer bytes, deployed runtime hashes and storage/role assertions. Keep data hash, policy hash and source/build hashes separate. The provided transcribed hash runtime is review tooling; independently reproduce against a locked production dependency.

Supply differential integer vectors, overflow/rounding proofs, split-page equivalence, maximum-catchup gas benchmarks, keeper throughput and storage-growth evidence. Port tests to Solidity/Anchor rather than reporting TypeScript reference results as contract tests.

## Gate D - Adversarial integration

Test negative/nonfinite input rejection in offchain modules; integer-overflow boundaries onchain; reentrancy, receipt replay, overlapping Claim/Cast/Stoke, public-waiver forgery; young top-ups into old positions and Seals; cancellation plus intervening cooling; plan fragmentation; emergency exit during every unrelated pause/failure.

Test Kindling cancellation until settlement, deadline admission cutoff, below-minimum failure,72h settlement timeout, fee release only on actual success, cancelled-fee refund on failure, callbacks, polluted initial pool state, malformed assets and duplicate refund attempts.

Test reservation allocation independent of keeper ordering, partial matching, seven-epoch expiry, dry Treasury seed, donated reserves, multiple vent calls per window, stale oracles, callback manipulation and72h alerts without guard relaxation. A bounded chunk per call alone is insufficient.

## Gate E - Audit and activation

Two independent audits covering the actual integrated design, with unresolved critical/high findings resolved. Publish the reports and scope, incident process and real bounty availability. The config's URL is not a published bounty. Operators approve the actual multisig and release manifest. Set a real start time only after this evidence is available.

Launch Ethereum only with100% of emissions. Keep transport channels and gauge disabled. All user exits return in-kind receipts without external conversion dependencies. Monitor liability coverage, supply reservations, settlement backlog, matching utilization, oracle deviations and auction/refund failures.

## Gate F - Satellites later

A satellite is a new release: complete its own assets/operators/audit, real bidirectional OFT settings (including libraries/DVNs/executor/confirmations/rate limits), authenticated burn accounting, funded budgets, Fissure seed and local fee program. Explicitly reassign shares so totals remain100. Adding a chain normally reuses valid CREATE3 identities; it does not require changing established addresses.

No date alone proves readiness. Solana additionally needs a distinct account/program/authority model and audited integration. No token transfer carries financial Heat, Streak or badges.
