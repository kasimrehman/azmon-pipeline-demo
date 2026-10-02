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
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')]
    [string] $ServiceAccountName = 'arc-portal-viewer',

    [Parameter()]
    [switch] $Revoke,

    [Parameter()]
    [string] $ConfigFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'script-modules\demo-common.ps1')
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

$vmName = "$NamePrefix-k3s"
$namespace = 'default'
$guestScript = Join-Path $PSScriptRoot 'manage-arc-portal-token.sh'
$action = if ($Revoke) { 'revoke' } else { 'issue' }
$guestOutput = Invoke-DemoVmShellScript `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -VmName $vmName `
    -ScriptPath $guestScript `
    -ScriptArguments @($action, $namespace, $ServiceAccountName)

if ($Revoke) {
    Write-Host $guestOutput
    return
}

$tokenMatch = [regex]::Match(
    $guestOutput,
    '(?m)__ARC_PORTAL_TOKEN_BEGIN__\r?\n(?<Token>[A-Za-z0-9._-]+)\r?\n__ARC_PORTAL_TOKEN_END__'
)
if (-not $tokenMatch.Success) {
    throw 'The cluster created the service account, but its bearer token was not returned in the expected format.'
}

Write-Warning 'The following bearer token is a credential. Do not save it in source control, documentation, screenshots, or chat.'
Write-Host 'Paste it into the Azure portal Service account bearer token prompt:'
Write-Output $tokenMatch.Groups['Token'].Value
Write-Host ''
Write-Host 'Revoke it when the portal inspection is complete:'
Write-Host '  .\operations-scripts\get-arc-portal-token.ps1 -Revoke'
