# Liquidity Locks (draft ERC)

One interface for any contract that locks pool liquidity, whether pool tokens of a v2-style pair or a v3- or v4-style
position NFT: which pool, how much, until when, for whom, and who is paid the fees meanwhile. Locks are listed and
summed per pool, so a scanner, a launchpad or a lender reads every conforming locker with one integration instead of one
per locker. Which lockers to trust stays the reader's choice; the interface makes it checkable against what each locker
holds.

**Status: draft, not submitted.** The text is in
[`ERCS/erc-draft_liquidity_locks.md`](ERCS/erc-draft_liquidity_locks.md). Its `eip: 99905` is a placeholder: the ERC
editors assign the real number when the pull request is opened on ethereum/ERCs. Discussion will open on Ethereum
Magicians first.

## Why

Nearly every token launch says "the liquidity is locked", and no two lockers say it the same way. Lockers for v2 pool
tokens and v3 and v4 positions already exist (UNCX, and Titan Locker on Robinhood Chain, among others), each with its
own functions and events, and launchpads hold positions in lockers of their own. Scanners therefore report locks only
for the lockers they have integrated. ERC-8376 (Token Launch Abuse Detection) scores the share of a pool held in locks
and takes the lock contracts as input; for position NFTs, the locked liquidity reaches its detector as a supplied
figure. With one interface, those figures are read from the lockers, and a lender or a launch declaration can point at
a lock by locker and lock id. Lockable-token proposals (ERC-5058, ERC-6982, ERC-7066, and the open
[Permanent Locks for Lockable Tokens](https://github.com/ethereum/ERCs/pull/2084) extension of ERC-6982) lock tokens,
permanently or for a time, but none names a pool, an amount of liquidity, an unlock time or a beneficiary.

## What is here

| Path | What |
|---|---|
| `ERCS/erc-draft_liquidity_locks.md` | The ERC text, in the ethereum/ERCs template |
| `src/ILiquidityLocks.sol` | The interface |
| `src/LiquidityLocker.sol` | A reference locker for v2-style pool tokens and v3-style position NFTs (not audited) |
| `test/LiquidityLocker.t.sol` | Foundry tests, including per-pool sums that stay cheap however many locks a pool has |
| `test/mocks/Mocks.sol` | v2-style pairs (fee-taking, calling back), a v3-style position manager, a locker that lies |
| `scripts/lint-erc.sh` | Lints the ERC text with eipw the way the ethereum/ERCs CI does |
| `eipw.toml` | The ethereum/ERCs repository's eipw configuration, copied as is |

## Checks

```bash
forge build
forge test
scripts/lint-erc.sh   # needs eipw: cargo install eipw --version 0.11.0 --locked
```

CI runs all three on every push (`.github/workflows/ci.yml`).

## Related drafts

- Launch Declarations: the typed facts a launchpad declares at launch (to be published as
  github.com/priors-agents/erc-launch-declarations). A launch declares its liquidity lock by locker and lock id.
- Credit-Matched Liquidity: loans that fund the quote side of a pool position held in escrow
  (github.com/priors-agents/erc-credit-matched-liquidity). A lender-held position is a lock until the loan's due date.

## Licence

CC0 1.0 ([LICENSE.md](LICENSE.md)), as the ERC process requires.
