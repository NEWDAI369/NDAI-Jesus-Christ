# NDAI Protocol

NDAI is a PulseChain token (chain ID 369). Users mint NDAI by paying pDAI. The protocol permanently locks a matching amount of bridged DAI in a non-withdrawable reserve and adds pDAI/PLSX liquidity that is also locked forever. NDAI cannot be redeemed for DAI and has no dollar peg.

Staking lets users lock NDAI and extract accrued yield as transferable NEW time tokens without ending the stake. Longer stakes earn a higher multiplier (up to 3×). NEW tokens redeem 1:1 for NDAI on or after their maturity day.

**Use at your own risk.** You can lose all assets you commit. There is no peg, no DAI redemption right, and yield is not guaranteed.

### Important
The DAI locked during minting cannot be withdrawn by anyone. It serves only as a public display of mint volume. NDAI has no claim on the reserve.

### Contracts
- `src/NDAI.sol` — minting
- `src/NDAIStaking.sol` — staking and NEW tokens

### Documentation
- [Risk disclosure](outputs/NDAI-Risk-Disclosure.md)
- [Integration guide](outputs/NDAI-Integration-Guide.md)

### Build and test
```bash
forge build
forge test
```

No official deployment has been announced. Third-party deployments are unaffiliated with this project.
