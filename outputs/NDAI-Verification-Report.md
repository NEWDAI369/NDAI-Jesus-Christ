# NDAI verification report

**Prepared November 14, 2026.** This report documents the project-run Foundry and local-fork checks for NDAI. The project owner requested public test evidence without commissioning an independent audit. An independent security audit has not been performed. The contracts were exercised on local forks, and no transactions were broadcast to PulseChain mainnet.

## What was tested

The fork uses PulseChain chain ID **369**, block **28,055,880**, block hash `0x8ba00c1c1d5de3a22f6f3ff897c2939ef08b04bc35c114ddcbd47ca4ad60de85`. Fork tests change local state. A local account, test launch timestamp, or successful simulated transaction is not evidence of a live deployment or current trading conditions.

| Area | What a reviewer can inspect |
|---|---|
| Mint and permanent DAI reserve | Mint 1 and 100 NDAI using the deployed PulseX route. Check the 4% depth guards, signed spending and liquidity minimums, locked LP receipt, and rollback of payment, reserve, LP and supply on failed mint. Run a funded position lifecycle from an actual fork mint and check that reserve funds stay isolated after NDAI burns, retirement, and redemption. |
| Fee waiver and activation | Waive fees on first issuance at zero eligible weight and after the last eligible deposit exits. A tranche contributes at exactly 86,400 seconds. Check issuance one second before activation and at the boundary. Verify the full gross claim remains backed in each case. |
| Fee conservation | The integrated vault is compared against a scaled arithmetic reference over randomized fee amounts with coalesced deposits, withdrawals, a late-activating depositor, claims across a weight change, and repeated claims. Check retained rounding dust and fee-escrow inventory against cumulative actual fee claims. |
| Position and series accounting | Randomized issuance, retirement and both maturity payout orders exercise the actual series with a test staking asset. Check reserve versus circulating claim supply, the free position balance, and the funding-origin ledger before and after maturity. |
| Permission and ceiling checks | Reject unauthorized minting and burning of claim tokens, direct custody payout, unauthorized issuance, unacceptable buyer bounds and deployment on another chain. At an arithmetic ceiling, verify atomic rejection of the next fee-bearing issuance while withdrawal, claim, waiver, retirement and redemption still work. |
| Queue and operational checks | The implementation test verifies issuance rollback with more than 32 due keys and withdrawal during the backlog. Historical scale fixtures exercise 10,000 entries and modeled recovery. The off-chain tests verify status rules for missed or zero-progress syncs, stale data and branch replacement. Live operator inclusion remains untested. |

The test output records individual test names and fuzz-run counts. Gas displayed for Forge tests includes test code and setup. Standalone receipt gas is reported separately in the accounting amendment.

## Deployed dependency evidence

The pinned RPC checks recorded router, factory, asset and pair addresses, runtime Keccak-256 hashes, token order, reserves, and 18-decimal results. The router reported the expected factory and wrapped-native token. Both supported mint endpoints executed against those dependencies on the local fork.

The PulseChain explorer reports partial verification for the router and displays a bytecode mismatch warning. A fingerprint identifies the bytes observed at the pinned block. It does not establish that published source reproduces those bytes. Exact source-to-runtime provenance, token and bridge privileges, and fresh liquidity checks remain unresolved for release. [PulseChain explorer router record](https://api.scan.pulsechain.com/address/0x98bf93ebf5c380C0e6Ae8e192A7e2AE08edAcc02/contracts)

## Reproduce the checks

Run from the project root with Foundry, Solidity 0.8.24, and OpenZeppelin Contracts 5.0.2 at the path mapped by `remappings.txt`. Keep the tested Solidity sources and configuration together. Use an RPC that serves historical PulseChain state.

```powershell
$rpc = 'https://rpc.pulsechain.com'
$block = 28055880
cast chain-id --rpc-url $rpc
cast block $block --field hash --rpc-url $rpc
forge build --skip script --skip test --sizes
forge test --fork-url $rpc --fork-block-number $block --no-storage-caching --gas-limit 2000000000 --fuzz-runs 2048 --fuzz-seed 0x4e444149 -vv
node --test test/NDAIQueueStatus.test.cjs
```

The 2-billion gas setting is a Forge harness budget for tests that construct many synthetic entries and make many bounded calls. It is not a transaction gas limit or a capacity claim for PulseChain. The pinned block gas limit was 45 million. Review the standalone receipts when assessing individual operations.

- [Raw Foundry output](NDAI-Fork-Test-Results.txt)
- [Pinned dependency evidence](NDAI-PulseChain-Dependency-Evidence.txt)
- [Accounting amendment, permission matrix and standalone receipts](NDAI-Accounting-Amendment.md)
- [Technical specification and approved settings](NDAI-Technical-Specification.md)

## Scope limits

These results are reproducible evidence for the revision identified below. They do not prove that every possible state or dependency behavior is safe. The 10,000-entry stress cases use synthetic setup. The backlog recovery objective depends on submitters, RPC availability and transaction inclusion. Pre-maturity claims can be illiquid. The permanent DAI reserve conveys no redemption rights for NDAI holders. Current market depth may differ from the historical snapshot.

No live launch date, official deployment address, or finding of audit completion is established by this report.

## Recorded results and fingerprints

**59 Solidity tests passed across seven suites.** The three fuzz tests ran 2,048 cases each. The seven queue-status model tests passed. Foundry 1.9.0 build commit 6056c5845d34205a83cf7108042adb137325c9df was used. Foundry reported a cache write permission warning after testing. The suite exited successfully.

Two RPCs returned the same pinned block hash and router runtime hash. The earlier standalone mint and custody receipts are recorded in the accounting amendment, including 743,572 gas for a 1-NDAI mint, 743,584 for 100 NDAI, and 752,600 for issuance with 32 due timestamps. The custody receipt used a test NDAI asset. The full funded lifecycle test separately exercises the actual NDAI contract.

| File | SHA-256 |
|---|---|
| outputs/NDAI.sol | 1fb2ed8695f90bc147750bb9ec755f19cab9f8fc89ceba01df1544462401f0f4 |
| outputs/NDAICustody.sol | 94d9010d56c6376164c7455b5d6668fd60d41a2016c0fd65d58c46bf514358c6 |
| outputs/NDAIFeeVault.sol | 54da8f7e97b842468adb3d602e2103a09b5a39462e06bd65c64e573e3249813a |
| outputs/NDAIStaking.sol | 3ae69358701ec88dfcdb2f175417a64f2c582f2608e87af09accdee02d8c9f1a |
| test/NDAIAccountingValidation.t.sol | 00e7e62de7923d712f12808e60b1cb9a8f40ef07aeed8aa2399156890fbef893 |
| test/NDAIActivationBenchmark.t.sol | 2423e4225016b881acfb8b186afc8ecab6df8ffc479a4bfd599f4e8db61db2af |
| test/NDAIActivationFlow.t.sol | b1d6b3852712938cc58f8056463fe3cbb1147a6aecdf2c22cc556b7c07ea77be |
| test/NDAICatchUpAndRetirement.t.sol | f53ba3671c4031697d38ba4c52c52d65d49821faf0383da0fbdad47de0e2958e |
| test/NDAIIntegrated.t.sol | 43341849523368445a574997821775e4936091e3ef95885f802b588b5ff9d9fa |
| test/NDAIQueueScale.t.sol | 10b83a3264f13fdf2fb743ceb195616001abc0d87313f7f4e931d80a654c1e96 |
| test/NDAIQueueStatus.test.cjs | 09860edd1487370628b2e7b37b0608d8f0778e262d19743f77993f68d4b8da27 |
| test/NDAIV2.t.sol | 2d8250bdc08ee396c85456d6fa246948c221eba3d44c7ea7291a72f3211a56fe |
| foundry.toml | 5ee4f81d5ffc4a70bd269e772a86594edf9d002c0039ee7c2538055478ae5cdb |
| remappings.txt | 24017c73b093dc9fdcde92ecbe8b7c2fe89c3278481e9180eadb40b016b46f6d |
| script/DeployNDAI.s.sol | daa9558d2213ea5a95114bb675810cb0f982f44d3b9103bbe08fc3bb436d89aa |
| outputs/NDAI-Fork-Test-Results.txt | 9d5b12473b0dee5d2dd95a1e609fffe804c1b65c3cba3f9b0b2f7ae3cc77f477 |
| outputs/NDAI-PulseChain-Dependency-Evidence.txt | 2cf3db5114c5149a7e9d30ecc32b0d636c66bb6af95c18fb835a11318e499917 |

The NEW-3300 naming revision passed the full pinned-fork regression. Tests verified the ticker and the mapping of protocol day 3300 to the existing 90-day maturity. Standalone gas receipts above predate the naming revision.

### PulseX router bytecode comparison

At PulseChain block 28060050, hash 0xfd869ee3a34ebac121e614e23798d58f48c48fc1e5f05f24885aafef5867fee6, two RPCs agreed on the router and factory runtime hashes. Both match the pinned values in the dependency evidence. The router returned the configured factory and WPLS addresses. The explorer contract page displays a mismatch warning and partial verification. Its API separately reported changed bytecode as false and partial verification as true.

Sourcify returned the deployed runtime and recompiled runtime for the router. The deployed bytes matched the RPC Keccak-256 hash. Substituting the verified factory and WPLS address words into all 54 immutable slots made the first 21,908 bytes match exactly. All 32 remaining differing bytes were the IPFS metadata digest, at offsets 21,918 through 21,949 within the 53-byte compiler trailer. This explains the full-byte mismatch for the compared artifacts. The comparison uses Sourcify's recompiled artifact. An independent source rebuild was not performed.

The official NEW-3300 and NDAI deployment addresses are still pending. The existing three mint-route pairs do not establish the NEW-3300/NDAI liquidity pair. Keep signed pool transactions unavailable until the official token addresses are published, the pair is resolved through the verified factory, its token order and reserves are checked, and add-liquidity simulation passes.

Sources: [PulseChain explorer router record](https://api.scan.pulsechain.com/address/0x98bf93ebf5c380C0e6Ae8e192A7e2AE08edAcc02/contracts), [Sourcify runtime comparison inputs](https://sourcify.dev/server/v2/contract/369/0x98bf93ebf5c380c0e6ae8e192a7e2ae08edacc02?fields=runtimeBytecode).

### NEW-3300 liquidity fork rehearsal

At PulseChain block 28055880, the separate pool test passed with real local-fork deployments of the NDAI and NEW-3300 contract sources. The user minted NDAI, issued backed NEW-3300, created the missing factory pair, verified both token addresses and empty reserves, and supplied 20 NDAI and 10 NEW-3300 at an illustrative opening ratio of 2 NDAI per NEW-3300. LP tokens went to the test user's wallet. A second deposit with an incompatible minimum reverted without moving user balances, LP balances or reserves. The DAI reserve, time-token backing and fee-vault principal remained separate.

Reproduce with forge test --match-contract NDAIPoolForkTest --fork-url https://rpc.pulsechain.com --fork-block-number 28055880 --no-storage-caching -vv. The result supplements the 59-test regression above. Its gas value includes setup and assertions. Fork state sets no official pool address, price or liquidity target.

[Raw pool fork output](NDAI-Pool-Fork-Results.txt)
- SHA-256 test/NDAIPoolFork.t.sol 1b30a3a3407336c7d6bf583945269842c7c6e7e40f19ec42fb69cd76034763ba
- SHA-256 outputs/NDAI-Pool-Fork-Results.txt 8366c231f85f2c2c168f74104895d8583acb1b04d8668c939f331de25eeec9f5

### Pool preflight checks

The PowerShell preflight test passed ten cases with a mocked Cast RPC adapter. The success case asserted the exact Add Liquidity call, sender, LP recipient and block. The failure cases covered absent official addresses, wrong chain, wrong runtime hash, missing pair, wrong token order, unseeded reserves, out-of-bounds simulation amounts, simulation revert and changed block hash. Run test/NDAIPoolPreflight.Tests.ps1 from the package root. The official manifest still has no live deployment addresses. The separate fork rehearsal above provides real execution evidence for the router flow.
