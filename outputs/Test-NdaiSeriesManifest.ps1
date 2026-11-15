param(
    [string] $Path = (Join-Path $PSScriptRoot 'NDAI-Official-Series.json')
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
if ($manifest.chainId -ne 369) { throw 'Expected PulseChain chain ID 369.' }

$series = @($manifest.series)
if ($series.Count -eq 0) { throw 'The launch series is required.' }
$days = [System.Collections.Generic.HashSet[uint32]]::new()
$addresses = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($entry in $series) {
    $day = [uint32]0
    if (-not [uint32]::TryParse([string]$entry.redemptionDay, [ref]$day) -or $day -eq 0) {
        throw 'Expected a positive redemption day.'
    }
    if (-not $days.Add($day)) { throw "Duplicate redemption day: $day." }
    $expected = if ($day -eq 3300) { "NEW" } else { "NEW-$day" }
    if ($entry.symbol -cne $expected) { throw "Expected symbol $expected." }

    if ($null -ne $entry.claimTokenAddress) {
        $address = [string]$entry.claimTokenAddress
        if ($address -notmatch '^0x[0-9a-fA-F]{40}$' -or $address -match '^0x0{40}$') {
            throw "Invalid claim-token address for $expected."
        }
        if (-not $addresses.Add($address)) { throw "Duplicate claim-token address: $address." }
    }
}

if (-not $days.Contains(3300)) { throw 'The day-3300 NEW launch series is required.' }
"Verified $($series.Count) official series with distinct redemption-day numbers."
