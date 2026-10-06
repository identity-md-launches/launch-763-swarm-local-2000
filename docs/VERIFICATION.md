# Local verification

Validated with Foundry 1.8.3 and the repository's pinned Solidity 0.8.26 configuration:

- `forge build`: exit 0.
- `forge test`: 42 passed, 0 failed; four fuzz tests, 256 cases each.
- `forge fmt --check`: exit 0.
- Deployed runtime sizes: STRIKE 14,910 bytes; TWAP adapter 5,981 bytes; union card 9,703 bytes. All are below 24,576 bytes.
- STRIKE creation code is 24,574 bytes before its nine static constructor arguments, below the EIP-3860 limit.
- The token runtime passes the opcode walk used by the supplied admission check, skipping PUSH data and rejecting DELEGATECALL, CALLCODE and SELFDESTRUCT.

The 10,000 optimizer-runs setting is intentional. At 200 runs the compiler put a Transfer event topic in a data section; the admission scanner interpreted part of that literal as CALLCODE. Keep the checked compiler configuration for reproducibility.

The DeploymentPlan helper embeds token creation code, is larger than EIP-170, and is **offline tooling only**. Its argument-based functions are tested by direct inheritance in DeploymentPlanTest; it is not an application to deploy or list in a launch manifest.

Forge's heuristic linter emits warnings. Reviewed patterns include time comparisons used for the requested locks/epochs/freshness, V2's deliberately wrapping uint32 timestamps and UQ112 division-before-time-multiplication, intentional partial tuple reads, guarded swaps followed by balance measurement/events, and NFT callbacks after one-per-wallet state is set. Distributor return words are range-checked before address conversion; external lookup return data is capped to one word. No warning suppression or FFI/filesystem permission was enabled.

The protected network harness itself requires externally generated network artifacts and was not run. Local tests reproduce the available constraints, including deployment without live external dependency code. No live fork, actual liquidity burn, production oracle connection, deployment, independent security audit, Slither or Mythril run is implied by these results. See README.md for the launch fee conflict and operational prerequisites.
