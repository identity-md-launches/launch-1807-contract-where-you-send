# ETH refund in the same transaction

`src/EthRefund.sol` contains the single application contract, `EthRefund`. Send it a positive
amount of native ETH and it immediately sends exactly that amount back to `msg.sender`, during
the same call. If the refund fails, the payment reverts. There is no deposit balance to claim
later, fee, interest, owner, or administrator. Transaction gas remains the sender's expense.

## Behavior and assumptions

| Entry point | Behavior |
| --- | --- |
| Ordinary ETH transfer with empty calldata | Refunds all `msg.value` to the caller. |
| `refund()` payable | Same behavior, with an explicit ABI function for integrations. |
| Other calldata | Payable fallback ignores the calldata and refunds all `msg.value`. |
| Any entry point with zero ETH | Reverts with `ZeroAmount()`. Minimum payment is 1 wei. |
| Call made during a refund callback | Reverts with `ReentrantCall()`. |
| Sender rejects the refund or exhausts its callback gas | Reverts with `RefundFailed()` if enough gas remains to encode it; otherwise an out-of-gas revert. The payment rolls back either way. |

Successful payments emit `Refunded(address indexed sender, uint256 amount)`. A reverted payment
leaves no event or retained payment. If the enclosing transaction later reverts, its payment,
refund, and event all revert together.

“Sender” means the immediate caller, not `tx.origin`. A wallet contract, router, or exchange that
sends the ETH receives the refund itself and is responsible for crediting its users. A contract
caller must have a payable `receive()` or fallback that accepts an empty-calldata call. Refund
callbacks may use more than 2,300 gas; this contract uses a checked low-level `call` and forwards
available gas subject to EVM rules. Callers must supply sufficient execution gas. A 21,000-gas
transaction or a Solidity `transfer`/`send` stipend is insufficient.

The reentrancy guard covers all three entry points. A sender may catch a rejected reentrant call
and allow its original refund to complete. If it propagates the error, the original payment
reverts. Failures do not affect other senders or later attempts.

Each call refunds only its own `msg.value`, never the contract's full balance. ETH credited
without executing the contract (for example, a forced ETH transfer or validator payment) cannot
be automatically returned and remains inaccessible. There is deliberately no sweep function or
privileged recipient. Tokens and NFTs are unsupported and cannot be recovered if sent here.

## Deployment parameters

| Item | Value |
| --- | --- |
| Network | Ethereum mainnet, chain ID 1 |
| Application artifact | `src/EthRefund.sol:EthRefund` |
| Constructor arguments | None (empty argument list) |
| Deployment ETH value | 0; construction is nonpayable |
| Owner/admin argument | None; the application has no privileged role |
| External contracts, oracles, keys, or services | None |
| Post-deployment initialization | None |
| Upgrade, pause, fee, or withdrawal powers | None |

The constructor works on an empty chain and does not inspect or call any other address. Factory
deployment does not confer privileges on the factory or transaction origin. Deploy only the
application under `src/`; contracts under `test/` are test fixtures. The deployment service
supplies the manifest and confirmed address separately; this project includes neither a manifest
nor a broadcast script, and no deployment transaction was sent by this task.

Build settings are pinned in `foundry.toml`: Solidity **0.8.26**, Cancun EVM, optimizer enabled
with 200 runs, and `bytecode_hash = "none"`. The application has no linked libraries. No FFI,
filesystem permissions, external library paths, or runtime dependencies are required.

## After launch

There are no settings to populate and no operator or keeper duties. The deployment operator is
responsible for publishing the confirmed address and verifying the source with the exact build
settings. Integrators must confirm the network/address, provide adequate gas, and accept refunds
in the sending account. An immutable deployed instance cannot be repaired or paused; a change
requires a new deployment and updated integrations.

For an integration already holding the confirmed address in `deployedAddress`:

```solidity
EthRefund(payable(deployedAddress)).refund{value: amount}();
```

The calling contract must accept the refund and must already have enough ETH for `amount`.
Wallet users can send native ETH directly with empty calldata and a contract-aware gas estimate.

## Local checks

Foundry and Solidity 0.8.26 must be installed. All Solidity test dependencies are included as
ordinary files in `lib/forge-std`; its version, upstream commit, and licenses are included there.
With the pinned compiler installed, building and testing require no network, RPC, keys, or
environment configuration. Use the assignment's reproducible fuzz seed when checking:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x4c80e18cef5ece0e8d57f277530b59b9b67141ada83db36c0327e056317ed48a forge test
forge fmt --check
```

Tests cover exact refunds and events, 1 wei, arbitrary calldata, immediate-caller routing,
callbacks before return, zero value, rejecting/nonpayable/gas-exhausting receivers, stipend
failure, caught and uncaught reentrancy, recovery after failure, pre-existing balances,
nonpayable/factory deployment, runtime size, and forbidden runtime opcodes. Fuzz tests use
1,024 cases each. Two stateful invariants check 128 sequences of up to 32 mixed
successful, rejected, zero-value, and reentrant payments, checking conservation and exactly one
refund per successful payment. An end-of-sequence check verifies the guard remains usable.

The tests deliberately exclude transaction gas from principal-balance assertions; gas is still
paid on-chain even when a transaction reverts. Forced balances are modeled with `vm.deal`.
The supplied protected deployment checks depend on deployment-service inputs; local tests
separately exercise their constructor, runtime-size, and opcode requirements.

Foundry's heuristic linter reports `reentrancy-eth` for the refund call and `reentrancy-events`
for the success event. These sites were reviewed: the shared `nonReentrant` modifier acquires
the lock before the external call and holds it through the event, and every entry point uses
that modifier through `_refund()`. Cross-entry reentrancy tests verify rejection and rollback.
The warnings are left visible rather than disabling the checks.

Security review should focus on the checked refund call, rollback, the guard on all entry
points, and the absence of any path that pays out pre-existing funds. The supplied security
reference informed the implementation. Local tests and this implementation review are not an
independent audit. Independent adversarial review remains a release responsibility; Slither
and Mythril were not run.
