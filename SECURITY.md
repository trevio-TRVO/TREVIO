# Security notes (preliminary self-review, NOT an audit)

Author's own review. An independent audit is required before mainnet. CI runs the format check, build, tests and Slither (fails on high severity) on every push and pull request. This is automated checking, not an audit.

| ID | Severity | Finding | Fix |
|---|---|---|---|
| F1 | High (policy) | Liquidity is not provisioned on-chain; the 24-month LP lock is not enforced by code. | Provisioner contract with verified DEX/locker addresses. |
| F2 | Medium | FIXED. The sale used to be funded after construction; if the soft cap was met but it held fewer than TOKENS_FOR_SALE, finalize() reverted and refunds were unavailable: funds locked. | The constructor now pulls TOKENS_FOR_SALE from the deployer with transferFrom and checks the balance, so a sale cannot exist unfunded. Deploy.s.sol approves the precomputed sale address first. Covered by tests. |
| F3 | Medium | USDC issuer can blacklist addresses; a blacklisted recipient makes finalize() revert, a blacklisted buyer cannot be refunded. | Pull-based payouts, non-blacklistable recipients. |
| F4 | Medium | Team/Treasury/Rewards vesting starts at SALE_END, buyers at finalize(); they vest even if the sale fails. | Define failed-sale policy. |
| F5 | Low | OZ VestingWallet is Ownable; beneficiary can transfer ownership. | Multisig beneficiaries. |
| F6 | Low | Hard-cap dust: a buy above remaining capacity reverts. | Partial fill or accept. |
| F7 | Info | Timestamp dependence is seconds-level. | None. |
| F8 | Info | Months approximated as 365-day years; rounding by wei. | Documented. |
| F9 | Info | Per-wallet cap bypassable with many wallets; not an AML control. | Documented. |

Tests now include malicious-token reentrancy (buy / refund / finalize / claim) and the F2 scenario. Coverage is measured with `forge coverage` but not gated in CI. Do not call the project audited before an independent audit.
