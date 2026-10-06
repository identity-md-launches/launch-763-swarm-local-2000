# Additional STRIKE tests

`StrikeAdversarial.t.sol` adds constructor rejection, failed-call atomicity,
allowance exhaustion, one-wei and whole-supply staking, exact maturity and rank
boundaries, typed oracle messages, malformed signatures, failed bargaining,
malicious adapter input accounting, and ERC-721 callback/soulbound checks.
Unsupported lock durations are fuzzed with 1,000 runs.

`StrikeInvariant.t.sol` runs 256 sequences of 64 calls with four wallets and
the production STRIKE and TWAP adapter. It reuses the existing IMD mock and
constant-product pair model. Only the handler's 12 action selectors are targeted;
unexpected reverts fail the campaign. Setup creates stakes, dues and a reward
stream so the accounting properties start with nonzero obligations.

The four invariant properties cover:

- Exact treasury backing, including separately tracked unsolicited donations,
  cumulative fee income/payouts, and a bound on earned rewards using vested funds.
- Aggregate positions, independent deposit/return/penalty accounting, and cleared
  treasury swap allowances.
- Sum of all reachable STRIKE balances and independently tracked burns against
  the constructor supply; neither adapter asset balance may retain funds.
- Union cards remaining owned by the wallet that minted them.

Every sequence ends by advancing past all locks and withdrawing every position.
A deterministic handler test also exercises claims, early exits, voting,
bargaining and fallback overtime, with counters to verify those paths were reached.

Run `forge build` and `forge test`. No network, FFI, environment changes, additional
dependencies, or configuration edits are needed. Build/cache paths can be redirected
with `--out /tmp/strike-forge-out --cache-path /tmp/strike-forge-cache`.

These are local contract tests. The supplied protected launch harness depends on
external launch artifacts and contracts absent from this repository; it is not
represented as having run. The pair model has no LP shares, so these tests do not
establish a live launch's liquidity burn or distribution.
