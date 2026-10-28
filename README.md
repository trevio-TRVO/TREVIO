# TREVIO

Official Trevio (TRVO) smart contracts, tokenomics, documentation, and deployment pipeline on Base.

> Status: foundation only. Contracts are not written yet. Nothing here is an offer, a promise of returns, or legal advice.

## Layout

```
src/      Solidity contracts (0.8.24, OpenZeppelin 5.x)
test/     Foundry tests
script/   Deployment scripts (Base Sepolia / Base)
docs/     Policy, parameters, whitepaper (EN/FR), litepaper
```

## Quick start

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-git
forge build
forge test
```

Copy `.env.example` to `.env`. Never commit secrets.

## Design principles

- Immutable parameters, no owner, no post-deploy mint.
- Deterministic integer pricing: 10,000 USDC / 4,200,000 TRVO = 420 TRVO per USDC.
- Permissionless refunds if the soft cap is not reached.

See [docs/POLICY.md](docs/POLICY.md) and [docs/PARAMETERS.md](docs/PARAMETERS.md).

## License

MIT
