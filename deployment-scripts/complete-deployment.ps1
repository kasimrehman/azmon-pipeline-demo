[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')]
    [string] $ResourceGroupName = 'rg-arc-monitor-demo',

    [Parameter()]
    [ValidatePattern('^[a-z0-9]{3,12}$')]
    [string] $NamePrefix = 'arcmon',

    [Parameter()]
    [string] $ConfigFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$configHelper = Join-Path $repositoryRoot 'script-modules\demo-config.ps1'
. $configHelper
$configState = Get-DemoConfiguration `
    -Path $ConfigFile `
    -DefaultDirectory $repositoryRoot `
    -ExplicitPath:($PSBoundParameters.ContainsKey('ConfigFile'))
$SubscriptionId = Resolve-DemoConfigurationValue -Name 'SubscriptionId' -BoundParameters $PSBoundParameters -CurrentValue $SubscriptionId -Configuration $configState.Values -ConfigurationPath $configState.Path -Required
$ResourceGroupName = Resolve-DemoConfigurationValue -Name 'ResourceGroupName' -BoundParameters $PSBoundParameters -CurrentValue $ResourceGroupName -Configuration $configState.Values -ConfigurationPath $configState.Path -Required
$NamePrefix = Resolve-DemoConfigurationValue -Name 'NamePrefix' -BoundParameters $PSBoundParameters -CurrentValue $NamePrefix -Configuration $configState.Values -ConfigurationPath $configState.Path -Required
Assert-DemoConfigurationValue -Name 'SubscriptionId' -Value $SubscriptionId
Assert-DemoConfigurationValue -Name 'ResourceGroupName' -Value $ResourceGroupName
Assert-DemoConfigurationValue -Name 'NamePrefix' -Value $NamePrefix

$gatewayScript = Join-Path $PSScriptRoot 'configure-gateway.sh'
$monitoringDeploymentName = "$NamePrefix-monitoring"
$pipelineName = "$NamePrefix-pipeline"
$vmName = "$NamePrefix-k3s"
$publicIpName = "$NamePrefix-pip"
$pipelineNamespace = 'azure-monitor-pipeline'
$traefikChartVersion = '41.6.0'

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $output = @(& az @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
    }
    return (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
}

function ConvertTo-SanitizedGuestOutput {
    param([Parameter(Mandatory)][string] $Value)

    $sanitized = $Value -replace '(?im)\b(authorization|password|passwd|token|secret|credential|client[_ -]?secret|access[_ -]?key|connection[_ -]?string)\b\s*[:=]\s*\S+', '$1=[REDACTED]'
    return $sanitized -replace '(?i)([?&](?:sig|se|sp|sv|ske|sks|skv)=)[^&\s]+', '$1[REDACTED]'
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required and was not found on PATH.'
}
if (-not (Test-Path -LiteralPath $gatewayScript -PathType Leaf)) {
    throw "Required gateway script not found: $gatewayScript"
}

Invoke-AzCli @(
    'account', 'set',
    '--subscription', $SubscriptionId,
    '--output', 'none'
) | Out-Null

$deploymentState = Invoke-AzCli @(
    'deployment', 'group', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $monitoringDeploymentName,
    '--query', 'properties.provisioningState',
    '--output', 'tsv',
    '--only-show-errors'
)
if ($deploymentState -ne 'Succeeded') {
    throw "Deployment '$monitoringDeploymentName' is '$deploymentState'. Wait until Azure Portal shows Succeeded, then run this command again."
}

Write-Host 'Configuring the Syslog and OTLP gateway...'
$guestOutput = Invoke-AzCli @(
    'vm', 'run-command', 'invoke',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $vmName,
    '--command-id', 'RunShellScript',
    '--scripts', "@$gatewayScript",
    '--parameters',
    "pipelineNamespace=$pipelineNamespace",
    "pipelineName=$pipelineName",
    "traefikChartVersion=$traefikChartVersion",
    '--query', 'value[0].message',
    '--output', 'tsv',
    '--only-show-errors'
)

if ($guestOutput -notmatch '(?m)^__ARC_MONITOR_EXIT_CODE=(\d+)\r?$') {
    throw 'Azure VM Run Command did not return the gateway script exit code.'
}
if ([int] $Matches[1] -ne 0) {
    $details = ConvertTo-SanitizedGuestOutput -Value (($guestOutput -replace '(?m)^__ARC_MONITOR_EXIT_CODE=\d+\r?$', '').Trim())
    throw "Gateway configuration failed.`n$details"
}

$publicIpAddress = Invoke-AzCli @(
    'network', 'public-ip', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $publicIpName,
    '--query', 'ipAddress',
    '--output', 'tsv',
    '--only-show-errors'
)

Write-Host ''
Write-Host 'Deployment complete.'
Write-Host "Syslog endpoint: ${publicIpAddress}:514"
Write-Host "OTLP endpoint:   ${publicIpAddress}:4317"
Write-Host ''
Write-Host 'Run the demos from this directory:'
if ($PSBoundParameters.ContainsKey('ConfigFile')) {
    Write-Host "  & .\generator-scripts\send-syslog-demo.ps1 -ConfigFile '$($configState.Path)'"
    Write-Host "  & .\generator-scripts\send-otlp-demo.ps1 -ConfigFile '$($configState.Path)'"
}
else {
    Write-Host '  & .\generator-scripts\send-syslog-demo.ps1'
    Write-Host '  & .\generator-scripts\send-otlp-demo.ps1'
}