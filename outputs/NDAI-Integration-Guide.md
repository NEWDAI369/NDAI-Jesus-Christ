# NDAI and NEW integration guide

> **Use NDAI at your own risk. You could lose all assets you commit. NDAI has no dollar peg, and holders cannot redeem it for DAI. Staking can restrict access to your NDAI, and fee-sharing rewards may be zero.** See the [full NDAI Risk Disclosure](NDAI-Risk-Disclosure.md).

Build your own website, wallet UI, indexer or command-line client using the included ABIs. All dates and availability should come from the relevant contract and block. The launch design uses one official series, NEW.

## Resolve a series

1. Verify PulseChain chain ID 369 (0x171). Choose a series from a trusted deployment manifest. ERC-20 tickers can be copied. Match the exact official address, and verify deployed bytecode against the release record.
2. The official deployment must publish the NDAI token and NDAIStaking addresses. From NDAIStaking, read ndai(), claimToken(), feeVault(), REDEMPTION_DAY(), MATURITY_DAY(), redemptionTime(), and issuanceCutoff(). Cross-check the claim address against the manifest and confirm that claim and fee-vault series() both point to that staking contract.
3. Use REDEMPTION_DAY() to label the token and redemptionTime() to show the exact UTC maturity. The launch value of MATURITY_DAY() is 90 and is the argument to stake and redeem. Passing 3300 there reverts. NEW is the fixed ticker while the countdown changes. Future official series must have unique numbers and token addresses.
4. The included pre-deployment manifest has a null claim-token address. Leave live transactions unavailable until a verified deployment record is published. Contract test deployments are useful only on their corresponding fork.

## Read and write guide

Use integer base units throughout. NDAI and NEW both use 18 decimals. All contract timestamps and deadlines are Unix seconds. Use the latest chain block timestamp for availability, and one consistent block for preview reads.

| User action | What to call | What to display or check |
|---|---|---|
| Mint NDAI with pDAI | Approve the NDAI contract to spend bounded pDAI. Then call NDAI.mintWithPdai(params). | The amount is 1 to 100 NDAI per call. Quote the exact-output pDAI → PLSX → WPLS → DAI reserve leg and the 20% supplemental budget. Simulate the liquidity leg and full mint at a canonical block to get minimums. Tuple order is ndaiOut, maxPdaiIn, minPlsxOut, minPdaiAdded, minPlsxAdded, minLpOut, deadline. The deadline must be at most five minutes from execution time. |
| Create a time-token position | Approve NDAIStaking to spend NDAI, then call stake(amount, MATURITY_DAY()). | Minimum 1 NDAI. Show redemptionTime() and issuanceCutoff(). The Staked receipt returns the position ID in its event. |
| Mint NEW | Call extract(positionId, gross, minNet) as the position owner before issuanceCutoff(). | Free position principal equals principal minus issued, read from stakes(positionId). Simulate from the account with the intended minNet. Gross reserves the full NDAI amount. With eligible weight, fee equals ceil(gross / 100) in base units. With zero eligible weight, fee is waived. Read gross, fee and net from Extracted. |
| Deposit for fee sharing | Approve NDAIFeeVault to spend NDAI, then call deposit(amount). | Minimum 1 NDAI. Each tranche activates after 86,400 seconds. A top-up resets the vault withdrawal clock. Rewards come from actual issuance fees in that same series, allocated by eligible principal. |
| Claim fee rewards | Call NDAIFeeVault.claimFees(). | accountState(account).earnedScaled divided by SCALE(), rounded down, is the currently claimable NEW base units. Fractional entitlements stay recorded. Use the FeeClaimed event and token balance after confirmation. |
| Withdraw fee-vault NDAI | Call NDAIFeeVault.withdraw(amount). | Show the early burn and net payout from a fresh simulation. Use accountState(account).lockEnds for timing. The penalty declines from 5% to zero over 90 days. An overdue activation backlog does not block this withdrawal path. |
| Retire debt | Call NDAIStaking.retire(positionId, amount) as the current NFT owner strictly before redemptionTime(). | Burns the owner's matching NEW and frees the same NDAI inside that position. Cap by outstanding debt and wallet claim balance. The free amount is withdrawable at maturity. The series burns directly, so no NEW allowance is needed. |
| Withdraw matured position | Call NDAIStaking.withdraw(positionId) as the owner at or after redemptionTime(). | Pays free principal to the owner and closes the NFT. Outstanding claims retain their backing. |
| Redeem NEW | Call NDAIStaking.redeem(MATURITY_DAY(), amount) as the holder at or after redemptionTime(). | Burns matching NEW and pays the same amount of NDAI directly to the holder. No NFT ownership or NEW allowance is needed. |

The permanent DAI reserve has no holder redemption flow. NEW holders redeem for NDAI. Secondary transfers or swaps of NEW use separate token or market interfaces.

## Transaction behavior

- Re-read chain, account, contract addresses, balances, ownership, and timestamps before signing. Simulate exact calldata from the connected account. Show the amount in, net amount out, asset, custody destination and timing. Refresh quotes and balances on a revert.
- For issuance, dueKeyCount() can return up to 33. If it returns 33, more than 32 keys are due and issuance can revert with CatchUpRequired. Any caller can call sync(). Re-read before trying issuance again. Keep fee-vault withdrawal available.
- accountState().settledWeight can lag the series. The returned pending list can include already globally processed tranches awaiting account settlement. Avoid estimating the issuance fee solely from settledWeight or cached eligiblePrincipal. Use an issuance simulation and confirm the Extracted receipt.
- Decode logs only from the verified emitting contract. Store chain ID, contract, transaction hash and log index for indexed actions. Read state again after receipt confirmation and handle replaced transactions and reorganizations.
- Test first issuance with zero eligible weight, issuance after the last eligible deposit exits, exact activation, exact maturity, owner changes before confirmation, invalid amounts, backlog and wrong network. Use the existing pinned-fork evidence as a starting point for your own client tests.

## Time-Token Pools

The approved first option is a standard, user-funded PulseX pool for the official NEW/NDAI pair. Resolve both tokens by their official PulseChain addresses. Read the pair from the verified factory, verify token order and reserves, and preview the user's two deposits, expected LP receipt, minimums and deadline. LP tokens go to the connected user's wallet. This feature uses no protocol funds and offers no farming incentives.

If the pair is missing, present initialization as a separate action. Preview the opening price in NDAI per NEW and check pair existence again before signing. Treat an existing pair with zero reserves as unseeded and show the opening ratio before the first liquidity deposit. Keep direct pool transactions unavailable until the official addresses are published and the factory pair and exact transaction are verified. See the pool verification status below. Concentrated liquidity is outside this first option.

## Included files

- abi/NDAI.json, abi/NDAIStaking.json, abi/NDAIFeeVault.json and abi/NDAITimeClaim.json contain ABI arrays from the verified local build.
- NDAI-Official-Series.json is the pre-deployment series list. Test-NdaiSeriesManifest.ps1 validates unique official day numbers, matching tickers and distinct recorded token addresses.

### Time-Token Pools verification status

The router comparison accounts for the observed bytecode mismatch with immutable addresses and a different metadata digest. See the companion NDAI Verification Package for the full report and dependency evidence. The launch token addresses and official NEW/NDAI pair are still pending. Keep pool transaction controls disabled until the official addresses, factory pair, reserves, and exact transaction simulation have been verified.

### Read-only pool preflight

Test-NdaiPoolPreflight.ps1 uses Cast and a trusted release manifest. The manifest must include ndaiAddress at the root, and stakingAddress and claimTokenAddress in the NEW entry. The current manifest intentionally has no official deployment addresses. The script checks chain ID and pinned router and factory runtime hashes, verifies official series wiring, resolves both token addresses and reserves for the pool, and simulates the populated pool's exact Add Liquidity call with the user's wallet as sender and LP recipient. Supply desired and minimum amounts as integer base units and the deadline as Unix seconds. The user needs the relevant token balances and existing allowances for the simulation to succeed. Missing and unseeded pairs use the separate opening-ratio flow.

The script returns simulation amounts and the observed block hash. It does not submit approvals, create pairs, request signatures, or broadcast transactions. Re-simulate after a state or parameter change. Until official addresses exist, the only live preflight outcome is the pending-address gate. The companion verification package contains the separate successful fork rehearsal.
