# NDAI Protocol

Pre-launch information package for NDAI and NEW on PulseChain (chain ID 369).

Minting and staking are not yet live. This repository is for review and pre-launch integration. Use only independently verified contract addresses once an official deployment is published.

**Use at your own risk.** You can lose all assets you commit. NDAI has no dollar peg and no redemption right for DAI. Staking can lock your NDAI for a chosen period, and yield may be zero once the emission cap is reached.

### Important
NDAI is not backed by the locked DAI. During minting, DAI is permanently locked in a reserve that no one can withdraw. The reserve exists only as a public display of how much NDAI has been minted. Users cannot redeem NDAI for DAI, and there is no mechanism to exchange DAI for NDAI. The reserve creates no peg and no claim.

### Documentation
- [Risk disclosure](outputs/NDAI-Risk-Disclosure.md)
- [Integration guide](outputs/NDAI-Integration-Guide.md) and [series manifest](outputs/NDAI-Official-Series.json)
- [Technical specification](outputs/NDAI-Technical-Specification.md) and [accounting amendment](outputs/NDAI-Accounting-Amendment.md)
- [Verification report](outputs/NDAI-Verification-Report.md), [fork test results](outputs/NDAI-Fork-Test-Results.txt), and [dependency evidence](outputs/NDAI-PulseChain-Dependency-Evidence.txt)

Contract source is in `outputs/`. Tests are in `test/`. ABIs are in `abi/`.

Previously recorded tests are included for reference. Match results against the source fingerprints in the verification report. These tests are not an independent audit. To build from source, install OpenZeppelin Contracts 5.0.2 at the path listed in `remappings.txt`.

### Status
No official deployment has been announced. Third-party deployments are unaffiliated with this project.

This is the current NDAI protocol (permanent DAI lock mint + capped staking with NEW time tokens). It replaces the earlier design.
