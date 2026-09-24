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
    [ValidatePattern('^[1-9][0-9]*Gi$')]
    [string] $PersistentVolumeCapacity = '8Gi',

    [Parameter()]
    [ValidateRange(1, 100)]
    [int] $MaxStorageUsageGiB = 2,

    [Parameter()]
    [ValidateRange(1, 2880)]
    [int] $RetentionPeriodMinutes = 120,

    [Parameter()]
    [string] $ConfigFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

. (Join-Path $PSScriptRoot 'demo\demo-common.ps1')
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

$showcaseTemplate = Join-Path $PSScriptRoot 'demo\showcase.bicep'
$storageScript = Join-Path $PSScriptRoot 'demo\prepare-demo-storage.sh'
$gatewayScript = Join-Path $PSScriptRoot 'configure-gateway.sh'
$pipelineNamespace = 'azure-monitor-pipeline'
$persistentVolumeName = 'azure-monitor-pipeline-demo-pv'
$vmName = "$NamePrefix-k3s"
$workspaceName = "$NamePrefix-law"
$dceName = "$NamePrefix-dce"
$customLocationName = "$NamePrefix-monitor"
$pipelineName = "$NamePrefix-pipeline"
$pipelineExtensionName = 'azure-monitor-pipeline'
$deploymentName = "$NamePrefix-demo-showcase"
$networkSecurityGroupName = "$NamePrefix-nsg"
$traefikChartVersion = '41.6.0'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required and was not found on PATH.'
}
foreach ($requiredFile in @($showcaseTemplate, $storageScript, $gatewayScript)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required demo file not found: $requiredFile"
    }
}

function Get-AzValue {
    param([Parameter(Mandatory)][string[]] $Arguments)

    return (Invoke-DemoAzCli -Arguments ($Arguments + @('--output', 'tsv', '--only-show-errors'))).Output
}

function Set-LogAnalyticsTable {
    param(
        [Parameter(Mandatory)][string] $WorkspaceResourceId,
        [Parameter(Mandatory)][string] $TableName,
        [Parameter(Mandatory)][object[]] $Columns
    )

    $resourceUri = "https://management.azure.com$WorkspaceResourceId/tables/${TableName}?api-version=2022-10-01"
    $body = @{
        properties = @{
            schema = @{
                name = $TableName
                columns = $Columns
            }
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $bodyPath = Join-Path ([IO.Path]::GetTempPath()) "azmon-demo-table-$([Guid]::NewGuid().ToString('N')).json"

    try {
        [IO.File]::WriteAllText($bodyPath, $body, [Text.UTF8Encoding]::new($false))
        Invoke-DemoAzCli -Arguments @(
            'rest',
            '--method', 'put',
            '--uri', $resourceUri,
            '--headers', 'Content-Type=application/json',
            '--body', "@$bodyPath",
            '--output', 'none',
            '--only-show-errors'
        ) | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
    }

    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    do {
        $stateResult = Invoke-DemoAzCli -Arguments @(
            'rest',
            '--method', 'get',
            '--uri', $resourceUri,
            '--query', 'properties.provisioningState',
            '--output', 'tsv',
            '--only-show-errors'
        ) -AllowFailure
        if ($stateResult.ExitCode -eq 0 -and $stateResult.Output -eq 'Succeeded') {
            Write-Host "Log Analytics table '$TableName' is ready."
            return
        }
        if ($stateResult.Output -in @('Failed', 'Canceled', 'Deleting')) {
            throw "Table '$TableName' entered provisioning state '$($stateResult.Output)'."
        }
        Start-Sleep -Seconds 10
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for table '$TableName'. Last state: '$($stateResult.Output)'."
}

Invoke-DemoAzCli -Arguments @(
    'account', 'set',
    '--subscription', $SubscriptionId,
    '--output', 'none'
) | Out-Null

$location = Get-AzValue @(
    'group', 'show',
    '--subscription', $SubscriptionId,
    '--name', $ResourceGroupName,
    '--query', 'location'
)
$workspaceResourceId = Get-AzValue @(
    'monitor', 'log-analytics', 'workspace', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--workspace-name', $workspaceName,
    '--query', 'id'
)
$commonSecurityLogResult = Invoke-DemoAzCli -Arguments @(
    'rest',
    '--method', 'get',
    '--uri', "https://management.azure.com$workspaceResourceId/tables/CommonSecurityLog?api-version=2022-10-01",
    '--query', 'properties.provisioningState',
    '--output', 'tsv',
    '--only-show-errors'
) -AllowFailure
if ($commonSecurityLogResult.ExitCode -ne 0 -or $commonSecurityLogResult.Output -ne 'Succeeded') {
    throw "The built-in CommonSecurityLog table is not ready in '$workspaceName'. Enable Microsoft Sentinel on the workspace, wait for the table provisioning state to become Succeeded, and run setup-demo.ps1 again."
}
$dataCollectionEndpointResourceId = Get-AzValue @(
    'monitor', 'data-collection', 'endpoint', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $dceName,
    '--query', 'id'
)
$dataCollectionEndpointLogsIngestionUrl = Get-AzValue @(
    'resource', 'show',
    '--ids', $dataCollectionEndpointResourceId,
    '--query', 'properties.logsIngestion.endpoint'
)
$customLocationResourceId = Get-AzValue @(
    'customlocation', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $customLocationName,
    '--query', 'id'
)
$pipelineExtensionPrincipalId = Get-AzValue @(
    'k8s-extension', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--cluster-type', 'connectedClusters',
    '--cluster-name', $vmName,
    '--name', $pipelineExtensionName,
    '--query', 'identity.principalId'
)
$allowedSourceCidr = Get-AzValue @(
    'network', 'nsg', 'rule', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--nsg-name', $networkSecurityGroupName,
    '--name', 'Allow-Syslog-Demo-Source',
    '--query', 'sourceAddressPrefix'
)

Get-AzValue @(
    'resource', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--resource-type', 'Microsoft.Monitor/pipelineGroups',
    '--name', $pipelineName,
    '--api-version', '2026-04-01',
    '--query', 'name'
) | Out-Null

$volumeCapacityGiB = [int]($PersistentVolumeCapacity -replace 'Gi$', '')
$persistentExporterCount = 2
$aggregateExporterCapacityGiB = $MaxStorageUsageGiB * $persistentExporterCount
if ($aggregateExporterCapacityGiB -ge $volumeCapacityGiB) {
    throw "$persistentExporterCount persistent exporter queues can use $aggregateExporterCapacityGiB GiB in total. PersistentVolumeCapacity must be larger to leave filesystem headroom."
}

Write-Host 'Preparing demo-only persistent storage on the single K3s node...'
$storageOutput = Invoke-DemoVmShellScript `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -VmName $vmName `
    -ScriptPath $storageScript `
    -ScriptArguments @($pipelineNamespace, $persistentVolumeName, $PersistentVolumeCapacity)
Write-Host $storageOutput

Set-LogAnalyticsTable -WorkspaceResourceId $workspaceResourceId -TableName 'OTelLogs_CL' -Columns @(
    @{ name = 'TimeGenerated'; type = 'datetime' }
    @{ name = 'Body'; type = 'string' }
    @{ name = 'SeverityText'; type = 'string' }
    @{ name = 'DemoRunId'; type = 'string' }
    @{ name = 'SequenceNumber'; type = 'long' }
    @{ name = 'ServiceName'; type = 'string' }
    @{ name = 'DeploymentEnvironment'; type = 'string' }
    @{ name = 'Site'; type = 'string' }
    @{ name = 'TraceId'; type = 'string' }
    @{ name = 'DurationMs'; type = 'real' }
    @{ name = 'EventClass'; type = 'string' }
)
Set-LogAnalyticsTable -WorkspaceResourceId $workspaceResourceId -TableName 'EdgeLogSummary_CL' -Columns @(
    @{ name = 'TimeGenerated'; type = 'datetime' }
    @{ name = 'DemoRunId'; type = 'string' }
    @{ name = 'Site'; type = 'string' }
    @{ name = 'SeverityLevel'; type = 'string' }
    @{ name = 'EventCount'; type = 'long' }
)

Write-Host "Deploying showcase overlay '$deploymentName'..."
Invoke-DemoAzCli -Arguments @(
    'deployment', 'group', 'create',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $deploymentName,
    '--template-file', $showcaseTemplate,
    '--parameters',
    "pipelineName=$pipelineName",
    "location=$location",
    "customLocationResourceId=$customLocationResourceId",
    "workspaceResourceId=$workspaceResourceId",
    "dataCollectionEndpointResourceId=$dataCollectionEndpointResourceId",
    "dataCollectionEndpointLogsIngestionUrl=$dataCollectionEndpointLogsIngestionUrl",
    "pipelineExtensionPrincipalId=$pipelineExtensionPrincipalId",
    "networkSecurityGroupName=$networkSecurityGroupName",
    "allowedSourceCidr=$allowedSourceCidr",
    "persistentVolumeName=$persistentVolumeName",
    "maxStorageUsage=$MaxStorageUsageGiB",
    "retentionPeriod=$RetentionPeriodMinutes",
    '--output', 'none',
    '--only-show-errors'
) | Out-Null

Write-Host 'Configuring the gateway with the CEF TCP/515 route...'
$gatewayOutput = Invoke-DemoVmShellScript `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -VmName $vmName `
    -ScriptPath $gatewayScript `
    -ScriptArguments @($pipelineNamespace, $pipelineName, $traefikChartVersion, 'true')
Write-Host $gatewayOutput

$endpoint = Get-AzValue @(
    'network', 'public-ip', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', "$NamePrefix-pip",
    '--query', 'ipAddress'
)

Write-Host ''
Write-Host 'Full showcase configuration deployed.'
Write-Host 'The pipeline controller may need several minutes to reconcile the update.'
Write-Host "CEF endpoint: ${endpoint}:515"
if ($PSBoundParameters.ContainsKey('ConfigFile')) {
    Write-Host "Run readiness: & .\test-demo-readiness.ps1 -ConfigFile '$($configState.Path)'"
    Write-Host "Start traffic:  & .\run-demo.ps1 -ConfigFile '$($configState.Path)' -DurationMinutes 2 -EventsPerSecond 5 -RunId 'DEMO-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))'"
    Write-Host "Send CEF:       & .\send-cef-demo.ps1 -ConfigFile '$($configState.Path)'"
}
else {
    Write-Host 'Run readiness: & .\test-demo-readiness.ps1'
    Write-Host "Start traffic:  & .\run-demo.ps1 -DurationMinutes 2 -EventsPerSecond 5 -RunId 'DEMO-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))'"
    Write-Host 'Send CEF:       & .\send-cef-demo.ps1'
}
