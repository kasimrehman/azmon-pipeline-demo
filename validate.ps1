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
    [ValidatePattern('^v1\.[0-9]+\.[0-9]+\+k3s[0-9]+$')]
    [string] $ExpectedK3sVersion = 'v1.33.3+k3s1',

    [Parameter()]
    [ValidateRange(1, 60)]
    [int] $TcpTimeoutSeconds = 10,

    [Parameter()]
    [string] $ConfigFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

. (Join-Path $PSScriptRoot 'demo\demo-config.ps1')
$configState = Get-DemoConfiguration `
    -Path $ConfigFile `
    -DefaultDirectory $PSScriptRoot `
    -ExplicitPath:($PSBoundParameters.ContainsKey('ConfigFile'))
$SubscriptionId = Resolve-DemoConfigurationValue -Name 'SubscriptionId' -BoundParameters $PSBoundParameters -CurrentValue $SubscriptionId -Configuration $configState.Values -ConfigurationPath $configState.Path -Required
$ResourceGroupName = Resolve-DemoConfigurationValue -Name 'ResourceGroupName' -BoundParameters $PSBoundParameters -CurrentValue $ResourceGroupName -Configuration $configState.Values -ConfigurationPath $configState.Path -Required
$NamePrefix = Resolve-DemoConfigurationValue -Name 'NamePrefix' -BoundParameters $PSBoundParameters -CurrentValue $NamePrefix -Configuration $configState.Values -ConfigurationPath $configState.Path -Required
Assert-DemoConfigurationValue -Name 'SubscriptionId' -Value $SubscriptionId
Assert-DemoConfigurationValue -Name 'ResourceGroupName' -Value $ResourceGroupName
Assert-DemoConfigurationValue -Name 'NamePrefix' -Value $NamePrefix

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $output = @(& az @Arguments --output json --only-show-errors 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
    }
    return (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine) | ConvertFrom-Json
}

function Test-TcpEndpoint {
    param(
        [Parameter(Mandatory)][string] $Endpoint,
        [Parameter(Mandatory)][int] $Port
    )

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($Endpoint, $Port)
        return $task.Wait([TimeSpan]::FromSeconds($TcpTimeoutSeconds)) -and $client.Connected
    }
    finally {
        $client.Dispose()
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required and was not found on PATH.'
}

& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select subscription '$SubscriptionId'."
}

$clusterName = "$NamePrefix-k3s"
$workspaceName = "$NamePrefix-law"
$pipelineName = "$NamePrefix-pipeline"
$resourceGroup = Invoke-AzJson @(
    'group', 'show',
    '--subscription', $SubscriptionId,
    '--name', $ResourceGroupName
)
$infraDeployment = Invoke-AzJson @(
    'deployment', 'group', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', "$NamePrefix-infra"
)
$monitoringDeployment = Invoke-AzJson @(
    'deployment', 'group', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', "$NamePrefix-monitoring"
)
$workspace = Invoke-AzJson @(
    'monitor', 'log-analytics', 'workspace', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--workspace-name', $workspaceName
)
$cluster = Invoke-AzJson @(
    'connectedk8s', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $clusterName
)
$certificateExtension = Invoke-AzJson @(
    'k8s-extension', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--cluster-type', 'connectedClusters',
    '--cluster-name', $clusterName,
    '--name', 'azure-cert-management'
)
$pipelineExtension = Invoke-AzJson @(
    'k8s-extension', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--cluster-type', 'connectedClusters',
    '--cluster-name', $clusterName,
    '--name', 'azure-monitor-pipeline'
)
$customLocation = Invoke-AzJson @(
    'customlocation', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', "$NamePrefix-monitor"
)
$pipelineGroup = Invoke-AzJson @(
    'resource', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--resource-type', 'Microsoft.Monitor/pipelineGroups',
    '--name', $pipelineName,
    '--api-version', '2026-04-01'
)
$dataCollectionRule = Invoke-AzJson @(
    'resource', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--resource-type', 'Microsoft.Insights/dataCollectionRules',
    '--name', "$pipelineName-dcr",
    '--api-version', '2024-03-11'
)
$table = Invoke-AzJson @(
    'rest',
    '--method', 'get',
    '--uri', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/tables/OTelLogs_CL?api-version=2022-10-01"
)
$publicIp = Invoke-AzJson @(
    'network', 'public-ip', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', "$NamePrefix-pip"
)

$checks = @(
    [pscustomobject]@{ Check = 'Resource group'; Passed = $resourceGroup.properties.provisioningState -eq 'Succeeded'; Detail = $resourceGroup.properties.provisioningState }
    [pscustomobject]@{ Check = 'Infrastructure deployment'; Passed = $infraDeployment.properties.provisioningState -eq 'Succeeded'; Detail = $infraDeployment.properties.provisioningState }
    [pscustomobject]@{ Check = 'Monitoring deployment'; Passed = $monitoringDeployment.properties.provisioningState -eq 'Succeeded'; Detail = $monitoringDeployment.properties.provisioningState }
    [pscustomobject]@{ Check = 'Log Analytics workspace'; Passed = $workspace.provisioningState -eq 'Succeeded'; Detail = $workspace.provisioningState }
    [pscustomobject]@{ Check = 'Arc connectivity'; Passed = $cluster.connectivityStatus -eq 'Connected'; Detail = $cluster.connectivityStatus }
    [pscustomobject]@{ Check = 'Kubernetes version'; Passed = $cluster.kubernetesVersion -eq $ExpectedK3sVersion.TrimStart('v'); Detail = $cluster.kubernetesVersion }
    [pscustomobject]@{ Check = 'Certificate extension'; Passed = $certificateExtension.provisioningState -eq 'Succeeded'; Detail = $certificateExtension.provisioningState }
    [pscustomobject]@{ Check = 'Pipeline extension'; Passed = $pipelineExtension.provisioningState -eq 'Succeeded'; Detail = $pipelineExtension.provisioningState }
    [pscustomobject]@{ Check = 'Custom location'; Passed = $customLocation.provisioningState -eq 'Succeeded'; Detail = $customLocation.provisioningState }
    [pscustomobject]@{ Check = 'Data collection rule'; Passed = $dataCollectionRule.properties.provisioningState -eq 'Succeeded'; Detail = $dataCollectionRule.properties.provisioningState }
    [pscustomobject]@{ Check = 'Pipeline group'; Passed = $pipelineGroup.properties.provisioningState -eq 'Succeeded'; Detail = $pipelineGroup.properties.provisioningState }
    [pscustomobject]@{ Check = 'OTelLogs_CL table'; Passed = $table.properties.schema.name -eq 'OTelLogs_CL'; Detail = $table.properties.schema.name }
    [pscustomobject]@{ Check = 'Syslog TCP/514'; Passed = Test-TcpEndpoint -Endpoint $publicIp.ipAddress -Port 514; Detail = "$($publicIp.ipAddress):514" }
    [pscustomobject]@{ Check = 'OTLP TCP/4317'; Passed = Test-TcpEndpoint -Endpoint $publicIp.ipAddress -Port 4317; Detail = "$($publicIp.ipAddress):4317" }
)

$checks | Format-Table -AutoSize
if ($checks.Passed -contains $false) {
    throw 'One or more standalone demo validation checks failed.'
}

Write-Host "All checks passed. Endpoint: $($publicIp.ipAddress)"