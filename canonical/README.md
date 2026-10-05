# FURNACE v5.5 canonical design package

The user delegated the outstanding design decisions. This package makes and applies them rather than offering another set of competing alternatives.

## Start here

- `DECISIONS.md`: retained v5.4 economics versus new selected policies.
- `FURNACE-v5.5-SPEC.md`: consolidated specification superseding contradictory prior passages.
- `furnace.config.ts`: full typed configuration with an Ethereum-only initial profile and explicit operational placeholders.
- `accounting.ts`: integer reference for integrated ordinary/Heat-squared measures, capped Conviction, exact vesting, matching reservations and escrow bookkeeping.
- `validation.ts` and `identity-rules.ts`: independent economic expectations, VM-aware address checks, exact CREATE3 derivation and explicit deployment diagnostics.
- `CONTRACTS.md` / `DEPLOYMENT.md`: selected contract boundaries, test conditions and actual remaining implementation work.

This is a canonical DESIGN/configuration revision, not a mainnet release or audit. No wallet keys, signatures, real operators, fabricated contract addresses or deployment transactions are supplied. Existing v5.4 input files are preserved unchanged in `source-v5.4/`.

## Reproduce locally

Use Node 22 and TypeScript 5.8.3. `npm install` installs the pinned compiler when network access is available. The build can use an already installed matching `tsc` offline.

```
npm run typecheck
npm test
npm run check:config
npm run check:deploy
npm run config:hash
```

`check:config` is the pre-mining economic/template check. It passes explicit missing operational identities but rejects changed economic rules or invalid populated identities. `check:deploy` fails until actual operational prerequisites are supplied and is never an audit or onchain release approval. A passing test run must not be mistaken for passing deployment validation.

The test suite contains 75 named tests, including a 1,000-scenario seeded budget-conservation test and independent numerical-quadrature checks of both Heat integrals. The cohort allocator is a test oracle. Production settlement requires the bounded onchain checkpoint/page design described in the specification; no production Solidity or Anchor contracts are included.

`results/manifest.json` contains config/policy commitments and separate source-file SHA-256 hashes. `results/verification.json` records what was executed. Use exact diagnostic codes and paths rather than an expected error count. The unchanged original configuration hash is not the hash of v5.5.

## Dependency provenance

The hashing runtime in `vendor/js-sha3` was carried from the previous review package, where it was transcribed from upstream js-sha3 0.9.3. Its MIT license is included. It is not represented as a fresh npm download or a byte-identical checked-out upstream source. Known vectors and a separate pure-Python Keccak check (PyCryptodome was not installed) are included in the executed verification.

For deployment tooling, use an independently locked, verified production dependency and reproducible compiler build. Neither checksum spelling nor valid base58 identifies the actual deployed code or proves control of an operator key.

## What remains external

Real deployer/Safe/guardian identities, ownership confirmation, start time, the selected external LP receipt, actual custody and settlement implementations, onchain configuration/runtime evidence, independent audits and explicit launch authorization. Those are operational facts and implementation deliverables; they are not choices returned to the user for another tokenomics debate.
