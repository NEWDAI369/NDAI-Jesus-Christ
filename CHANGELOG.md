# NDAI Update Changelog

## Staking & Yield Layer (added)
- Hard emission cap: total extra NDAI minted as yield cannot exceed +10% of NDAI created through minting.
- Users can stake NDAI for a chosen length.
- Accrued yield can be extracted at any time as NEW tokens without ending the stake.
- NEW tokens are day-specific (e.g. NEW-4000, NEW-9000) and redeemable 1:1 for NDAI on or after their maturity day.
- End-of-stake payout = principal + total yield earned − amount already extracted as NEW.
- No external protocol names appear in any contract.

## Minting
- Unchanged. Continues to use the existing multi-hop route (pDAI → PLSX → WPLS → DAI) and permanent DAI reserve from the current NDAI.sol.

## Files in this update
- NDAIStaking.sol (new/replacement staking contract)
- CHANGELOG.md (this file)

## Deployment order
1. Deploy existing NDAI.sol (minting) first.
2. Deploy NDAIStaking with the NDAI token address.
3. Deploy NEW token contracts per maturity day as needed.
