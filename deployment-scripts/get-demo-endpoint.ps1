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
. (Join-Path $repositoryRoot 'script-modules\demo-config.ps1')

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

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required and was not found on PATH.'
}

$output = @(& az network public-ip show `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --name "$NamePrefix-pip" `
    --query ipAddress `
    --output tsv `
    --only-show-errors 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
}

$endpoint = (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
if ([string]::IsNullOrWhiteSpace($endpoint)) {
    throw "Public IP '$NamePrefix-pip' did not return an IP address."
}

Write-Output $endpoint
