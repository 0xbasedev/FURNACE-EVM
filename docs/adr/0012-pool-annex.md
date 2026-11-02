# ADR 0012: ForgePool's cold paths run in an annex it deploys and delegatecalls

Status: accepted for this repository. Not audited, not deployed.

## Context

- **The pool was running out of room.** After the Deed hook (ADR 0011), ForgePool was 22,398 bytes, 2,178 under EIP-170.
  - Four hooks still need room in the pool: Taps, source-lot additions, Kindling positions and the First Flame setter.
  - ADR 0010 estimated 2–2.5 KB for six hooks, and Deeds alone took 1.7 KB.
  - By ADR 0010's rule, the next lever comes before the next hook.
- **Where the bytes were** (measured by removing each path):

| Path | Bytes |
|---|---:|
| `requestCooling`, with the plan, freeze and pro-rata logic only it uses | 3,349 |
| `list`, `unlist` and `settle` | 1,533 |
| `seal` | 957 |
| `epochMeasure` | 383 |
| `collectFees` | 344 |

## Decision

**1. An annex built from the same source as the pool.**
- `ForgePoolBase` (abstract) holds the storage, the immutables and the configuration checks, the events and errors, and every internal function.
- `ForgePool` and `ForgePoolAnnex` both inherit it. Neither declares a state variable of its own, so the storage layout exists in one place.
- Each pool deploys its own annex in its constructor with the same five arguments and stores the address as the immutable `ANNEX`.
- **What moves to the annex:** `seal`, `setOrdinaryBonus`, `list`, `unlist`, `settle` and `collectFees`.
  - The pool keeps a stub with each signature, so the pool's ABI and every call site are unchanged.
  - The stub delegatecalls its calldata to the annex. It returns exactly what the annex returned, or reverts with exactly the annex's revert data.

**2. Why an annex and not a library.** ADR 0010's lever was "an external library called by delegatecall". A library would need its own copy of the record helpers (`_setHead`, `_tag`, `_retag`, `_rewriteActive`, `_endSeal`), written twice by hand. The annex compiles the same internal functions from one source. Run by delegatecall:
- its code acts on the pool's storage;
- `msg.sender` is the pool's caller;
- its events come from the pool's address.

**3. What stays in the pool.**
- **Principal paths and exits:** `open`, `deposit`, `requestCooling`, `executeWithdrawal`, `cancelCooling` and `emergencyExit`.
  - Every exit still makes exactly one external call, the token transfer, and `requestCooling` still makes none (ADR 0004).
  - The plan logic therefore stays too, unlike ADR 0010's suggestion: it is part of `requestCooling`, a principal path.
- **Views:** `epochMeasure`, `measureSlot`, `occupiedSecondsAt` and `extsload`. A view cannot delegatecall.
- **`poke`.**

**4. Rules that keep this sound.**
- **One reentrancy guard.** The annex's functions carry `nonReentrant` and the stubs do not. The guard's transient slot belongs to the pool, so a guard on both sides would make every delegated call revert.
- **One storage layout, checked on every build.** `pnpm check:layout` diffs the pool's and the annex's storage layouts and ForgeView's slots. A state variable declared in either contract fails the build. This was verified by planting one.
- **The same immutables.** The pool constructs the annex with its own arguments, and a test pins the annex's immutables to the pool's. The annex never reads `ANNEX`.
- **Direct calls are harmless.** Called directly, the annex acts on its own storage, which holds no positions, no fees and no tokens. A test shows that nothing in the pool changes.
- **Rule for later hooks:**
  - Kindling positions and source-lot additions may go in the annex: they add principal but are not exits, and no exit depends on them.
  - Taps is an exit, so it stays in the pool.

## Result

| | Runtime bytes | Initcode bytes |
|---|---:|---:|
| ForgePool before | 22,398 | 22,873 |
| ForgePool after | **19,825 (4,751 under EIP-170)** | 33,070 (16,082 under the 49,152 limit) |
| ForgePoolAnnex | 12,226 | 12,670 |

## Gas (`pnpm gas`, isolated)

- **Delegated paths** each cost about 3.0–3.3k more: the annex account's cold access plus the delegatecall.

| Path | Before | After |
|---|---:|---:|
| `seal`, 32 lots | 1,215,403 | 1,218,662 |
| `setOrdinaryBonus`, 32 lots | 1,132,397 | 1,135,423 |
| `list`, 32 lots | 42,785 | 45,833 |
| `settle`, 32 lots | 1,186,548 | 1,189,614 |
| Capstone deposit, raising 32 lots | 1,308,285 | 1,311,377 |

- **Every other path moves by at most ±52 gas**, from the dispatcher's new order. Settlement pages over many positions add up to 22 gas per call, for example +2,816 on the 32-position page (+0.07%).

## Verification

- **Behaviour is unchanged.** Every differential replay passes against the same vectors, with the same state hash after every step. All 215 tests pass.
- **New tests:**
  - the annex's immutables equal the pool's;
  - a delegated call returns the annex's values (the Seal index, the listing nonce, all three fee figures), reverts with the annex's exact error data, and emits from the pool;
  - direct calls to the annex change nothing in the pool.
- **Mutations:**
  - the 24 earlier mutants whose code moved into the annex (Seals, the bonus authority, ceiling and sync, every Deed path) re-run against `ForgePoolAnnex.sol`;
  - two new mutants plant a stub that reports success on failure and a stub that drops the return data.
  - Results: see the PR.

## Consequences

- **The deployment-verification list gains each pool's annex.** Verify its runtime hash, and that its immutables equal its pool's.
- **Headroom for the remaining hooks is 4.7 KB.** Each hook PR still records what it used.
- **Not audited or deployed.**
