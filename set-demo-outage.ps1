[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Block', 'Restore', 'Status')]
    [string] $Action,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')]
    [string] $ResourceGroupName = 'rg-arc-monitor-demo',

    [Parameter()]
    [ValidatePattern('^[a-z0-9]{3,12}$')]
    [string] $NamePrefix = 'arcmon'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

. (Join-Path $PSScriptRoot 'demo\demo-common.ps1')

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required and was not found on PATH.'
}

Invoke-DemoAzCli -Arguments @(
    'account', 'set',
    '--subscription', $SubscriptionId,
    '--output', 'none'
) | Out-Null

$dceName = "$NamePrefix-dce"
$dceResourceId = (Invoke-DemoAzCli -Arguments @(
    'monitor', 'data-collection', 'endpoint', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $dceName,
    '--query', 'id',
    '--output', 'tsv',
    '--only-show-errors'
)).Output
$dceEndpoint = (Invoke-DemoAzCli -Arguments @(
    'resource', 'show',
    '--ids', $dceResourceId,
    '--query', 'properties.logsIngestion.endpoint',
    '--output', 'tsv',
    '--only-show-errors'
)).Output
$dceHostname = ([Uri]$dceEndpoint).DnsSafeHost
$controlScript = Join-Path $PSScriptRoot 'demo\control-demo-outage.sh'

$guestOutput = Invoke-DemoVmShellScript `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -VmName "$NamePrefix-k3s" `
    -ScriptPath $controlScript `
    -ScriptArguments @($Action.ToLowerInvariant(), $dceHostname)

Write-Host $guestOutput
if ($Action -eq 'Block') {
    Write-Warning 'The demo DCE path is blocked. Always run this script again with -Action Restore when the resilience segment is complete.'
}
