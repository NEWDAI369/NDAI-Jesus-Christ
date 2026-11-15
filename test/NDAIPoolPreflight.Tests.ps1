$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$preflightPath = Join-Path $root 'outputs/Test-NdaiPoolPreflight.ps1'
$preflight = [scriptblock]::Create([IO.File]::ReadAllText($preflightPath))

$ndai = '0x' + ('1' * 40)
$staking = '0x' + ('2' * 40)
$claim = '0x' + ('3' * 40)
$wallet = '0x' + ('4' * 40)
$pair = '0x' + ('5' * 40)
$factory = '0x1715a3e4a142d8b698131108995174f37aeba10d'
$fixtureBlockHash = '0x' + ('6' * 64)
$fictional = Join-Path $root ('work/preflight-test-' + [guid]::NewGuid().ToString('N') + '.json')
@{chainId=369;ndaiAddress=$ndai;series=@(@{redemptionDay=3300;symbol='NEW';stakingAddress=$staking;claimTokenAddress=$claim})} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fictional

function PoolCastMock {
    $global:LASTEXITCODE = 0
    switch ($args[0]) {
        'chain-id' { if ($mode -eq 'wrong-chain') {'1'} else {'369'} }
        'block-number' {'28055880'}
        'block' {
            if ($args -contains '--json') { @{timestamp='0x100';hash=$fixtureBlockHash} | ConvertTo-Json -Compress }
            elseif ($mode -eq 'reorg') { '0x' + ('7' * 64) }
            else { $fixtureBlockHash }
        }
        'code' { if ($args[1] -eq $factory) {'factory'} else {'router'} }
        'keccak' {
            $code = $input | Select-Object -First 1
            if ($code -eq 'factory') { '0xbd23f7453cee89d6d0c28753b44515d726cf13911c81da9b4311b89d2c51b979' }
            elseif ($mode -eq 'wrong-runtime') {'0x0'}
            else { '0xd43617d26bc499a7a9b60771c0ee7274e606518c32260d4998fdf66822802730' }
        }
        'call' {
            switch -Wildcard ($args[2]) {
                'factory()*' { $factory }
                'ndai()*' { $ndai }
                'claimToken()*' { $claim }
                'series()*' { $staking }
                'REDEMPTION_DAY()*' { '3300 [3.3e3]' }
                'getPair*' { if ($mode -eq 'missing') {'0x'+('0'*40)} else {$pair} }
                'token0()*' { if ($mode -eq 'wrong-order') {$wallet} else {$claim} }
                'token1()*' { $ndai }
                'getReserves()*' { if ($mode -eq 'unseeded') {'0';'0';'256'} else {'100';'200';'256'} }
                'addLiquidity*' {
                    if (($args[3..10] -join ',') -ne (@($ndai,$claim,'20','10','19','9',$wallet,'300') -join ',') -or
                        $args[$args.IndexOf('--from')+1] -ne $wallet -or $args[$args.IndexOf('--block')+1] -ne '28055880') {
                        throw 'Wrong exact simulation arguments.'
                    }
                    if ($mode -eq 'bounds') {'18';'10';'3'}
                    elseif ($mode -eq 'revert') {$global:LASTEXITCODE=1}
                    else {'20';'10';'3'}
                }
                default { throw "Unexpected read: $($args[2])" }
            }
        }
        default { throw "Unexpected command: $($args[0])" }
    }
}

$options=@{Manifest=$fictional;Cast='PoolCastMock';Account=$wallet;NdaiDesired='20';NewDesired='10';NdaiMin='19';NewMin='9';Deadline='300'}
$mode='success'
$result=& $preflight @options
if($result.Status -ne 'SimulationPassed' -or $result.LpRecipient -ne $wallet -or $result.ExpectedLp -ne '3' -or $result.Pair -ne $pair){
    throw 'Unexpected success response.'
}
'PASS Exact read-only simulation and LP recipient'
$cases=[ordered]@{'wrong-chain'='RPC is not PulseChain';'wrong-runtime'='Runtime hash mismatch';'missing'='Pair is missing';'wrong-order'='Pair token order';'unseeded'='Pair is unseeded';'bounds'='Simulated deposits';'revert'='Cast failed during call';'reorg'='The reference block changed'}
foreach($mode in $cases.Keys){
    try { & $preflight @options | Out-Null; throw 'Expected rejection.' }
    catch { if($_.Exception.Message -notlike ($cases[$mode]+'*')){throw} }
    "PASS Rejected $mode"
}
try { & $preflight -Manifest (Join-Path $root 'outputs/NDAI-Official-Series.json') -Cast 'must-not-run'; throw 'Expected pending-address gate.' }
catch { if($_.Exception.Message -notlike 'Official NDAI,*pending*'){throw} }
'PASS Missing official addresses rejected before RPC'

