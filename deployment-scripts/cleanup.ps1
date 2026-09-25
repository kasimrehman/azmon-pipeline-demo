[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')]
    [string] $ResourceGroupName = 'rg-arc-monitor-demo',

    [Parameter()]
    [switch] $Force,

    [Parameter()]
    [string] $ConfigFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'script-modules\demo-config.ps1')
$configState = Get-DemoConfiguration `
    -Path $ConfigFile `
    -DefaultDirectory $repositoryRoot `
    -ExplicitPath:($PSBoundParameters.ContainsKey('ConfigFile'))
$SubscriptionId = Resolve-DemoConfigurationValue -Name 'SubscriptionId' -BoundParameters $PSBoundParameters -CurrentValue $SubscriptionId -Configuration $configState.Values -ConfigurationPath $configState.Path -Required
$ResourceGroupName = Resolve-DemoConfigurationValue -Name 'ResourceGroupName' -BoundParameters $PSBoundParameters -CurrentValue $ResourceGroupName -Configuration $configState.Values -ConfigurationPath $configState.Path -Required
Assert-DemoConfigurationValue -Name 'SubscriptionId' -Value $SubscriptionId
Assert-DemoConfigurationValue -Name 'ResourceGroupName' -Value $ResourceGroupName

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required and was not found on PATH.'
}

$workloadTag = @(& az group show `
    --subscription $SubscriptionId `
    --name $ResourceGroupName `
    --query 'tags.workload' `
    --output tsv `
    --only-show-errors 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Resource group '$ResourceGroupName' was not found or could not be read."
}
if (($workloadTag -join [Environment]::NewLine).Trim() -ne 'azure-monitor-pipeline-demo') {
    throw "Refusing to delete '$ResourceGroupName' because it is not marked as a standalone monitor demo."
}

if (-not $Force -and -not $WhatIfPreference) {
    $caption = 'Delete standalone Azure Monitor demo'
    $question = "Delete resource group '$ResourceGroupName' and every resource in it?"
    if (-not $PSCmdlet.ShouldContinue($question, $caption)) {
        return
    }
}

if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Delete the resource group and every resource in it')) {
    & az group delete `
        --subscription $SubscriptionId `
        --name $ResourceGroupName `
        --yes `
        --no-wait `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start deletion of resource group '$ResourceGroupName'."
    }

    Write-Host "Deletion started for resource group '$ResourceGroupName'."
}