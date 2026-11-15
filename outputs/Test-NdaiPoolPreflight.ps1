param(
    [string] $Manifest = (Join-Path $PSScriptRoot 'NDAI-Official-Series.json'),
    [string] $RpcUrl = 'https://rpc.pulsechain.com',
    [string] $Cast = 'cast',
    [string] $Account,
    [string] $NdaiDesired,
    [string] $NewDesired,
    [string] $NdaiMin,
    [string] $NewMin,
    [string] $Deadline
)

$ErrorActionPreference = 'Stop'
$zero = '0x' + ('0' * 40)
$router = '0x98bf93ebf5c380c0e6ae8e192a7e2ae08edacc02'
$factory = '0x1715a3e4a142d8b698131108995174f37aeba10d'

function Read-Address([string] $Value, [string] $Label) {
    if ($Value -notmatch '^0x[0-9a-f]{40}$' -or $Value -eq $zero) {
        throw "Missing or invalid $Label."
    }
    $Value
}

function Read-Amount([string] $Value, [string] $Label) {
    if ($Value -notmatch '^[0-9]{1,78}$') { throw "$Label must be a positive integer in base units." }
    $number = [bigint]::Parse($Value)
    if ($number -le 0 -or $number -ge [bigint]::Pow(2, 256)) { throw "$Label is outside uint256 bounds." }
    $number
}

function Invoke-Cast {
    $result = & $Cast @args
    if ($LASTEXITCODE -ne 0) { throw "Cast failed during $($args[0]). No transaction was submitted." }
    $result
}

$launch = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if ($launch.chainId -ne 369) { throw 'Expected PulseChain chain ID 369 in the official manifest.' }
$series = @($launch.series | Where-Object { $_.redemptionDay -eq 3300 -and $_.symbol -ceq 'NEW' })
if ($series.Count -ne 1) { throw 'Expected exactly one official NEW series entry.' }
if (-not $launch.ndaiAddress -or -not $series[0].stakingAddress -or -not $series[0].claimTokenAddress) {
    throw 'Official NDAI, staking and NEW addresses are pending. Pool preflight is disabled.'
}
$ndai = Read-Address $launch.ndaiAddress 'NDAI address'
$staking = Read-Address $series[0].stakingAddress 'staking address'
$claim = Read-Address $series[0].claimTokenAddress 'NEW address'
if ($ndai -eq $staking -or $ndai -eq $claim -or $staking -eq $claim) { throw 'Official addresses must be distinct.' }
$sender = Read-Address $Account 'user wallet address'
$desiredA = Read-Amount $NdaiDesired 'NDAI desired'
$desiredB = Read-Amount $NewDesired 'NEW desired'
$minA = Read-Amount $NdaiMin 'NDAI minimum'
$minB = Read-Amount $NewMin 'NEW minimum'
$expires = Read-Amount $Deadline 'Deadline in Unix seconds'
if ($minA -gt $desiredA -or $minB -gt $desiredB) { throw 'A minimum cannot exceed the desired amount.' }

if ((Invoke-Cast chain-id --rpc-url $RpcUrl) -ne '369') { throw 'RPC is not PulseChain 369.' }
$block = Invoke-Cast block-number --rpc-url $RpcUrl
$header = Invoke-Cast block $block --json --rpc-url $RpcUrl | ConvertFrom-Json
$timestamp = [Convert]::ToInt64($header.timestamp.Substring(2), 16)
if ($expires -le $timestamp) { throw 'The deadline has expired at the observed block.' }
if ((Invoke-Cast call $router 'factory()(address)' --block $block --rpc-url $RpcUrl) -ne $factory) {
    throw 'The router factory does not match the release reference.'
}
foreach ($item in @(
    @{ Address = $router; Hash = '0xd43617d26bc499a7a9b60771c0ee7274e606518c32260d4998fdf66822802730' },
    @{ Address = $factory; Hash = '0xbd23f7453cee89d6d0c28753b44515d726cf13911c81da9b4311b89d2c51b979' }
)) {
    $code = Invoke-Cast code $item.Address --block $block --rpc-url $RpcUrl
    $hash = $code | & $Cast keccak
    if ($LASTEXITCODE -ne 0 -or $hash -ne $item.Hash) { throw "Runtime hash mismatch at $($item.Address)." }
}

if ((Invoke-Cast call $staking 'ndai()(address)' --block $block --rpc-url $RpcUrl) -ne $ndai -or
    (Invoke-Cast call $staking 'claimToken()(address)' --block $block --rpc-url $RpcUrl) -ne $claim -or
    (Invoke-Cast call $claim 'series()(address)' --block $block --rpc-url $RpcUrl) -ne $staking -or
    (Invoke-Cast call $staking 'REDEMPTION_DAY()(uint32)' --block $block --rpc-url $RpcUrl).Split(' ')[0] -ne '3300') {
    throw 'The token and staking contracts do not match the official series.'
}
$pair = Invoke-Cast call $factory 'getPair(address,address)(address)' $ndai $claim --block $block --rpc-url $RpcUrl
if ($pair -eq $zero) { throw 'Pair is missing. Use a separate pool initialization flow.' }
$token0 = Invoke-Cast call $pair 'token0()(address)' --block $block --rpc-url $RpcUrl
$token1 = Invoke-Cast call $pair 'token1()(address)' --block $block --rpc-url $RpcUrl
if (-not (($token0 -eq $ndai -and $token1 -eq $claim) -or ($token0 -eq $claim -and $token1 -eq $ndai))) {
    throw 'Pair token order does not match the official assets.'
}
$reserves = @(Invoke-Cast call $pair 'getReserves()(uint112,uint112,uint32)' --block $block --rpc-url $RpcUrl)
if ($reserves.Count -ne 3) { throw 'Unexpected reserve response.' }
if (($reserves[0].Split(' ')[0] -eq '0') -or ($reserves[1].Split(' ')[0] -eq '0')) {
    throw 'Pair is unseeded or has empty reserves. Review the opening ratio in the first-deposit flow.'
}
$signature = 'addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)(uint256,uint256,uint256)'
$arguments = @($ndai, $claim, $desiredA.ToString(), $desiredB.ToString(), $minA.ToString(), $minB.ToString(), $sender, $expires.ToString())
$amounts = @(Invoke-Cast call $router $signature @arguments --from $sender --block $block --rpc-url $RpcUrl)
if ($amounts.Count -ne 3) { throw 'Unexpected simulation response.' }
$usedA = Read-Amount $amounts[0].Split(' ')[0] 'Simulated NDAI used'
$usedB = Read-Amount $amounts[1].Split(' ')[0] 'Simulated NEW used'
$lp = Read-Amount $amounts[2].Split(' ')[0] 'Simulated LP receipt'
if ($usedA -lt $minA -or $usedA -gt $desiredA -or $usedB -lt $minB -or $usedB -gt $desiredB) {
    throw 'Simulated deposits are outside the requested bounds.'
}
if ((Invoke-Cast block $block --field hash --rpc-url $RpcUrl) -ne $header.hash) {
    throw 'The reference block changed during simulation.'
}
[pscustomobject]@{
    Status = 'SimulationPassed'
    ChainId = 369
    Block = $block
    BlockHash = $header.hash
    Pair = $pair
    Token0 = $token0
    Token1 = $token1
    Reserve0 = $reserves[0].Split(' ')[0]
    Reserve1 = $reserves[1].Split(' ')[0]
    NdaiUsed = $amounts[0].Split(' ')[0]
    NewUsed = $amounts[1].Split(' ')[0]
    ExpectedLp = $amounts[2].Split(' ')[0]
    LpRecipient = $sender
}

