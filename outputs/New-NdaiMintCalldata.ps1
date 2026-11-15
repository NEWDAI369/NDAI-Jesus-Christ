param(
    [Parameter(Mandatory)][string]$NdaiAmount,
    [Parameter(Mandatory)][string]$QuotedPdaiCost,
    [Parameter(Mandatory)][string]$ExpectedPlsxOut,
    [Parameter(Mandatory)][string]$ExpectedPdaiAdded,
    [Parameter(Mandatory)][string]$ExpectedPlsxAdded,
    [Parameter(Mandatory)][string]$ExpectedLpOut,
    [Parameter(Mandatory)][string]$Deadline
)

$ErrorActionPreference = 'Stop'

function Read-BaseUnits([string]$Value) {
    if ($Value -notmatch '\A[0-9]+\z') { throw 'Use integer base units.' }
    return [bigint]::Parse($Value)
}

function Get-Minimum([string]$Expected) {
    $minimum = [bigint]::Divide((Read-BaseUnits $Expected) * 99, 100)
    if ($minimum -eq 0) { throw 'Liquidity quote is too small for a nonzero minimum.' }
    return $minimum
}

$cost = Read-BaseUnits $QuotedPdaiCost
$maxPayment = $cost + [bigint]::Divide($cost, 5)
$values = @(
    (Read-BaseUnits $NdaiAmount)
    $maxPayment
    (Get-Minimum $ExpectedPlsxOut)
    (Get-Minimum $ExpectedPdaiAdded)
    (Get-Minimum $ExpectedPlsxAdded)
    (Get-Minimum $ExpectedLpOut)
    (Read-BaseUnits $Deadline)
)
if ($values[0] -eq 0 -or $cost -lt 10) { throw 'Mint amount or quote is too small.' }
if ($values[6] -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { throw 'Deadline has passed.' }

$cast = Join-Path $PSScriptRoot '../work/foundry/cast.exe'
$signature = 'mintWithPdai((uint256,uint256,uint256,uint256,uint256,uint256,uint256))'
$calldata = & $cast calldata $signature ('(' + ($values -join ',') + ')')
if ($LASTEXITCODE -ne 0) { throw 'Could not encode mint calldata.' }

[pscustomobject]@{
    MaxPdaiIn = $maxPayment.ToString()
    MinPlsxOut = $values[2].ToString()
    MinPdaiAdded = $values[3].ToString()
    MinPlsxAdded = $values[4].ToString()
    MinLpOut = $values[5].ToString()
    Calldata = $calldata
}
