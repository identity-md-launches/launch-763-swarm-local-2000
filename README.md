# Swarm Local 2000 — STRIKE

An immutable Solidity 0.8.26 project implementing STRIKE, locked staking, a fee-funded treasury, signed overtime, weekly bargaining and soulbound union cards. The complete dependency sources are vendored; no package install, environment variables, RPC, FFI or filesystem permissions are needed to build or test.

```sh
forge build
forge test
forge fmt --check
```

## Launch compatibility and the fee boundary

The supplied launch checks require **exact, untaxed** factory/distributor/v4 PoolManager flows, including traders buying and selling. This conflicts with charging dues on every trade in that same v4 pool. This implementation preserves those required exemptions. **Direct v4 trades are untaxed.** STRIKE charges dues on transfers involving its one immutable, separate STRIKE/IMD V2 market. Ordinary wallet sends and unregistered markets are also untaxed. This is a material economic limitation: traders can bypass dues using the required launch pool. Do not advertise a universal 2% trade tax.

The constructor computes this V2 pair address from a configured factory, pair init-code hash and the token addresses, and deploys its own immutable TWAP adapter. It calls no external dependency during construction and moves no STRIKE supply. This avoids circular CREATE2 constructor-address dependencies and works in the isolated launch harness. After launch, anyone calls `prepareMarket()` on the adapter to create or verify that already fixed pair. The V2 market initially has no liquidity; providing liquidity there is a separate, voluntary operation after launch. The launch allocation is never redirected to it by these contracts.

The requested initial distribution is **10% swarm / 88% launch pool / 2% payer**. All 1,000,000,000 × 10^18 tokens are first minted once to the constructor caller, which must equal the configured launch factory. The network factory, not the token constructor, performs that distribution. Use `poolBps = 8800` and the actual payer as `remainderTo`; no opening market cap or chain was supplied. The network's own launch tooling must derive its price and seed its v4 pool. No manifest with invented chain addresses or prices is provided.

**LP destruction is an external launch responsibility.** These contracts neither custody nor issue launch LP positions and cannot burn positions held by the network factory. The launcher must make v4 liquidity permanently inaccessible under its supported launch mechanism and record evidence. Any separately provided V2 liquidity must mint/transfer its LP tokens to an irrecoverable sink. No liquidity has been provisioned or burned by this local assignment.

## Contracts

| Contract | Purpose |
| --- | --- |
| `src/Strike.sol:Strike` | ERC-20, fee accounting, IMD fund, locked positions, rewards, oracle answers and voting |
| `src/V2TwapSwap.sol:V2TwapSwap` | Constructor-created, fixed-pair 0.30% V2 swaps with cumulative TWAP minimum output |
| `src/UnionCard.sol:UnionCard` | Separately deployed free ERC-721/EIP-5192 soulbound membership card; live onchain JSON and SVG gremlin art |
| `script/DeploymentPlan.sol:DeploymentPlan` | Read-only constructor-bytecode and CREATE2 prediction helpers; accepts explicit arguments, never broadcasts |

There are no ownership grants: `owner()` always returns zero. There is no mint entrypoint, pause, upgrade, blacklist, seizure, transfer limit, configurable fee, rescue function or arbitrary call facility. A holder may burn their own tokens. The constructor-created adapter and precomputed pair addresses are exposed by getters. The adapter needs no privileged approval/init call from the token deployer. `prepareMarket()` cannot change the market address or settings. `updateOracle()` is permissionless observation maintenance, not privileged initialization.

## Dues and treasury

Taxed buys/sells debit the sender's gross amount and deliver the remainder:

- `floor(amount / 200)` STRIKE is destroyed, reducing total supply.
- `floor(amount / 200)` STRIKE accrues for buying IMD and sending it to `0x...dEaD`.
- `floor(amount / 100)` STRIKE accrues for the Strike Fund.

Integer rounding can make the fee slightly less than 2%, including zero for dust. Liquidity adds/removals through the V2 market also appear as taxable transfers unless a launch exemption applies; they cannot be reliably distinguished from swaps in an ERC-20. Token-owned treasury transfers are exempt to prevent recursive dues. Factory and PoolManager operators/endpoints, plus the dynamically resolved `factory.distributorOf(uint64)` operator/endpoints, are exempt. A failed distributor lookup is treated as no distributor, never as a reason to block a sale.

`processFees(maxImdBurnInput, maxFundInput)` is permissionless and bounded by actual accrued dues. It swaps only those tracked STRIKE amounts, divides measured IMD proceeds proportionally, sends the burn portion to the dead address, and records the remainder as spendable `fund`. IMD burn means permanent sink transfer, not an assumed reduction of IMD's reported `totalSupply`. No swaps, oracle checks or fund callbacks execute inside transfers. A stale oracle, empty fund or failed keeper transaction cannot freeze STRIKE trading.

All fund/reward amounts are in **IMD minor units**, independently of IMD's decimals. Direct donations are unaccounted surplus; they cannot become emissions, voting budget or rewards. There is no recovery authority. Staked STRIKE, pending STRIKE dues, free IMD fund, IMD reward liabilities and remaining IMD stream budget are tracked separately.

## Seniority and staking

Hold age begins when a wallet first obtains a nonzero liquid or staked position. Any nonzero outgoing wallet transfer or voluntary burn resets its rank; exhausting both balances clears it. Receiving more tokens or a zero-value send does not reset rank. Staking and exiting use internal, fee-free transfers and preserve the wallet's age. Seniority is wallet-based, not a per-token age measure.

| Hold age | Vote bonus |
| --- | --- |
| <1 day | 1× |
| 1–7 days | 1.1× |
| 7–30 days | 1.25× |
| ≥30 days | 1.5× |

One active position per wallet, with no top-ups or position transfers:

| Lock | Reward weight |
| --- | --- |
| 7 days | 1× stake |
| 30 days | 1.5× stake |
| 90 days | 2.5× stake |
| 180 days | 4× stake |

Call `stake(amount, lockDays)` directly; no approval to the token itself is required. Streaming rewards accrue pro-rata using a global reward-per-weight accumulator and per-position checkpoints. **Rewards can only be claimed after maturity.** Allowing earlier claims would make total early-exit reward forfeiture unenforceable. Maturity does not automatically unstake or stop earning.

`exit()` removes the whole position. Before maturity, 20% of principal (rounded down) burns and all accrued rewards are redistributed to remaining weights; when no stakers remain, forfeiture returns to the free fund. At/after maturity it returns all principal and pays accrued rewards. Voting may additionally hold the position through that voting week. Liquid wallet tokens remain transferable throughout.

Streams release linearly over seven days. Adding a stream checkpoints the old one, then re-streams its unvested remainder plus the new budget over the next seven days. This rolls the end date forward rather than creating unbounded per-day stream storage. Time with no stakers returns vested rewards to the fund on the next checkpoint; the first new depositor cannot capture them retroactively. Integer reward dust remains reserved and cannot be double-spent.

## Overtime

The oracle EOA is fixed at construction and has no control of balances or protocol settings. The expected signed question is exactly:

```text
jobs the IMD swarm accepted in the last 24h
```

Use EIP-712:

```text
Domain: name="Swarm Local 2000 Overtime", version="1",
        chainId=<deployment chain>, verifyingContract=<STRIKE address>
Type:   Overtime(bytes32 questionHash,uint256 jobs,uint256 observedAt,uint256 day)
Values: questionHash=keccak256(bytes(exact question above)),
        jobs=<unsigned count>, observedAt=<Unix seconds>,
        day=floor(observedAt / 86400)
```

`answerDigest(jobs, observedAt, day)` exposes the digest for tooling. `submitOvertime` accepts a canonical 65-byte ECDSA signature from the configured signer. It checks domain, payload hash, signer, low-s signature form, timestamp not in the future, freshness ≤1 hour, current UTC day, unused day and ≥24-hour cadence. The signature proves attribution, **not that the reported job count is true**; the operator must derive that number from the IMD job system.

Spend is `min(jobs × jobsRate, floor(fund / 50))`, with overflow-safe capping. Half (rounded down) buys and burns STRIKE; the remainder becomes a seven-day IMD reward stream. A zero-job answer is accepted, spends nothing, and refreshes oracle liveness. If no valid answer has been observed in 48 hours (measured from deployment initially), anyone may call `fallbackOvertime()` once per day at the same cadence, spending `min(fallbackDaily, fund / 50)` with the same split. Fallback does not pretend that the oracle answered. Failed swaps revert spending, cadence and replay markers atomically, so the same valid answer can be retried.

## Weekly bargaining

Weeks are seven-day intervals from token deployment. A voting position must have been opened **before** that week's start, preventing same-week borrowed/recycled stake voting. The first week therefore has no eligible positions. Each wallet votes once per week with `stake × current rank bonus`; the staking lock multiplier applies to rewards, not votes. Voting locks the position until that week's end; outgoing liquid transfers can reset future rank but do not alter an already cast vote.

Options: `0` = A, buy/burn STRIKE with 1% of free IMD fund; `1` = B, send 1% as IMD to the dead address; `2` = C, stream an extra 1% as IMD to stakers. Anyone executes the immediately preceding week's winner once with `executeBargain(week)`. Any highest-score tie, including a B/C tie or no votes, selects A. Spending is based on the free fund at execution. Missed weeks expire: a caller cannot batch years of unattended votes to drain the fund. There is no quorum or arbitrary governance execution.

## Union cards

Deploy `UnionCard($token)` after STRIKE. Anyone holding liquid or staked STRIKE may mint once, for no payment. The token ID is the wallet address interpreted as a uint256. Transfers, burns and approvals are unavailable. The card persists after a wallet leaves; metadata marks it inactive and updates its rank/stake live. `tokenURI` returns embedded JSON and SVG with a grumpy gremlin, orange vest, coffee and ON $STRIKE sign. Gold status is dynamically read from the requested Identity MD NFT address `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d`; absent/reverting code gives non-gold status. That chain-specific NFT address has **not been verified on a live network**.

## Deployment parameters and operations

The `Strike` constructor takes these static arguments in this exact order:

| Parameter | Required value/responsibility |
| --- | --- |
| `address factory` | Actual constructor caller; network `$factory` |
| `address poolManager` | Network `$poolManager`; exempt v4 settlement endpoint |
| `uint64 launchNumber` | Network `$launchNumber`, also used for distributor lookup |
| `address imd` | Verified, non-rebasing, non-taxed IMD ERC-20; not a proxy dependency with changing semantics |
| `address v2Factory` | Verified genuine factory for constant-product pairs with fixed 0.30% LP fee; `getPair/createPair` interface |
| `bytes32 pairInitCodeHash` | Verified init-code hash used by that V2 factory's CREATE2 pair deployment; a wrong hash permanently disables fee processing |
| `address oracleSigner` | Verified IMD oracle EOA capable of signing the exact typed message above; immutable, no rotation |
| `uint256 jobsRate` | IMD **minor units per accepted job**, positive |
| `uint256 fallbackDaily` | Minimum daily fallback IMD **minor units**, positive; still capped at 2% of the fund |

No chain, IMD contract, V2 factory, pair init-code hash, oracle signer, rate, fallback amount, paired launch currency, or opening market cap was supplied. These remain deployment decisions; the tests use clearly named local models. Do not copy test addresses into production configuration. Constructor bytecode plus the nine static ABI words can be obtained from `DeploymentPlan.tokenCode(config)`; `tokenAddress(config)` follows the network factory's CREATE2 launch-number salt. The helper is tooling, not a contract to include in the launch manifest. The only separate application needed in `contracts` is `UnionCard($token)`; the adapter is already created inside STRIKE's constructor.

Operational checklist:

1. Independently review contracts and verify all chain dependencies and immutable values before deployment. Confirm the fee-boundary limitation is acceptable to the launch operator.
2. Have the network launch factory deploy STRIKE, route 10% to its distributor, allocate 88% to launch liquidity and 2% to the payer, and permanently burn/lock its LP rights. Record actual distribution and LP evidence.
3. If dues-funded features are to operate, call the adapter's permissionless `prepareMarket()` and provide separate STRIKE/IMD V2 liquidity and destroy those LP rights. The adapter rejects an empty pool. No contract here promises liquidity or bridges v4 liquidity to V2.
4. Call `updateOracle()` once after liquidity exists, wait ≥30 minutes, call again. Maintain observations at 30–120 minute intervals. Quotes expire two hours after the last observation; an outage beyond that requires a new observation plus another 30-minute warm-up.
5. Permissionless keepers process bounded fee batches, relay daily signed answers or fallback, and execute each weekly vote before its execution window expires. There is no keeper subsidy; rewards are funded only by collected dues. Observe balances/events rather than assuming swaps succeed.
6. Publish signer service uptime, provenance of job counts, verified addresses and deployment metadata. No keys, broadcasts, transactions or funded-wallet access are part of this assignment.

The adapter enforces at least 97% of its observed cumulative TWAP as actual received output, accounting for both fee-on-transfer amounts and LP fees. It does not substitute the instantaneous spot reserve ratio for its oracle. Its cumulative arithmetic follows the [Uniswap V2 oracle design](https://developers.uniswap.org/docs/protocols/v2/guides/building-an-oracle). A TWAP limits single-block price manipulation; prolonged manipulation in a shallow pool remains possible. Execution can fail when the spot price diverges by more than 3% or a batch has excessive price impact. The oracle and market cannot be replaced, so liquidity quality and the lack of signer rotation are enduring deployment risks.

## Verification and scope

Tests cover fixed issuance, exact launch transfers, absence of common administrative powers, fee conservation, broken swap isolation, rank reset/grief resistance, all lock weights, early exits and reward solvency, signature freshness/replay/domain isolation, daily fallback, vote eligibility/locking/ties/execution, soulbound metadata, CREATE2 construction without external dependency code, correct pair predictions, forbidden token opcodes, TWAP warm-up/staleness/recovery/wrapping, spot manipulation and real adjusted-K swap accounting in a local V2 model. Fuzz tests vary trade size, direction, stake sizes, lock terms and withdrawal timing.

The supplied protected test requires a network factory/PoolManager harness, generated manifest and environment values that this empty repository does not contain. It was read and its relevant constraints are reproduced in local tests; this project does not claim to have run that external admission harness. The local V2 model is not a deployed-pool integration test. No live fork, explorer verification, Slither or Mythril result is claimed. Passing local tests is not a security audit; an independent adversarial review is still required before release with other people's funds.

Vendored dependencies: OpenZeppelin Contracts v5.1.0 (MIT), forge-std v1.9.7 (MIT/Apache-2.0). Their licenses are included under `lib/`. New project code is MIT licensed.
