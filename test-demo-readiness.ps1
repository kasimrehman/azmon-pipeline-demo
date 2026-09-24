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
    [ValidateRange(1, 30)]
    [int] $MaxIngestionWaitMinutes = 15,

    [Parameter()]
    [ValidateSet('Syslog', 'OTLP', 'CEF', 'Both', 'All')]
    [string] $Protocol = 'Both',

    [Parameter()]
    [switch] $SkipIngestionTest,

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

$failures = [Collections.Generic.List[string]]::new()
$pipelineName = "$NamePrefix-pipeline"
$workspaceName = "$NamePrefix-law"
$vmName = "$NamePrefix-k3s"
$persistentVolumeName = 'azure-monitor-pipeline-demo-pv'
$syslogEnabled = $Protocol -in @('Syslog', 'Both', 'All')
$otlpEnabled = $Protocol -in @('OTLP', 'Both', 'All')
$cefEnabled = $Protocol -in @('CEF', 'All')

function Add-CheckResult {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][bool] $Passed,
        [Parameter(Mandatory)][string] $Details
    )

    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1}: {2}" -f $status, $Name, $Details)
    if (-not $Passed) {
        $failures.Add("${Name}: $Details")
    }
}

function Get-TableColumns {
    param(
        [Parameter(Mandatory)][string] $WorkspaceResourceId,
        [Parameter(Mandatory)][string] $TableName
    )

    $uri = "https://management.azure.com$WorkspaceResourceId/tables/${TableName}?api-version=2022-10-01"
    $json = (Invoke-DemoAzCli -Arguments @(
        'rest', '--method', 'get', '--uri', $uri,
        '--output', 'json', '--only-show-errors'
    )).Output | ConvertFrom-Json
    $schema = $json.properties.schema
    $columnProperty = @('columns', 'standardColumns') |
        Where-Object { $null -ne $schema.PSObject.Properties[$_] } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($columnProperty)) {
        throw "Table '$TableName' metadata did not include a supported column collection."
    }
    return @($schema.$columnProperty | ForEach-Object { $_.name })
}

function Get-QueryRows {
    param(
        [Parameter(Mandatory)][string] $WorkspaceCustomerId,
        [Parameter(Mandatory)][string] $Query,
        [Parameter(Mandatory)][string] $QueryName
    )

    $singleLineQuery = ($Query -replace '\r?\n', ' ').Trim()
    $result = Invoke-DemoAzCli -Arguments @(
        'monitor', 'log-analytics', 'query',
        '--workspace', $WorkspaceCustomerId,
        '--analytics-query', $singleLineQuery,
        '--timespan', 'PT30M',
        '--output', 'json',
        '--only-show-errors'
    ) -AllowFailure
    if ($result.ExitCode -ne 0) {
        $details = ConvertTo-DemoSanitizedOutput -Value $result.Output
        Write-Warning "$QueryName query failed: $details"
        return @()
    }
    return @($result.Output | ConvertFrom-Json)
}

function Get-QueryValue {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]] $Rows,
        [Parameter(Mandatory)][string] $Name
    )

    if ($null -eq $Rows -or $Rows.Count -eq 0) {
        return 0L
    }
    $property = $Rows[0].PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return 0L
    }
    return [long] $property.Value
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required and was not found on PATH.'
}

Invoke-DemoAzCli -Arguments @(
    'account', 'set', '--subscription', $SubscriptionId, '--output', 'none'
) | Out-Null

$deploymentState = (Invoke-DemoAzCli -Arguments @(
    'deployment', 'group', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', "$NamePrefix-demo-showcase",
    '--query', 'properties.provisioningState',
    '--output', 'tsv',
    '--only-show-errors'
) -AllowFailure).Output
$deploymentDetails = if ([string]::IsNullOrWhiteSpace($deploymentState)) { 'not found' } else { $deploymentState }
Add-CheckResult 'Showcase deployment' ($deploymentState -eq 'Succeeded') $deploymentDetails

$pipelineJson = (Invoke-DemoAzCli -Arguments @(
    'resource', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--resource-type', 'Microsoft.Monitor/pipelineGroups',
    '--name', $pipelineName,
    '--api-version', '2026-04-01',
    '--output', 'json',
    '--only-show-errors'
)).Output | ConvertFrom-Json
$pipelineState = $pipelineJson.properties.provisioningState
Add-CheckResult 'Pipeline resource' ($pipelineState -eq 'Succeeded') $pipelineState

$workspaceJson = (Invoke-DemoAzCli -Arguments @(
    'monitor', 'log-analytics', 'workspace', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--workspace-name', $workspaceName,
    '--output', 'json',
    '--only-show-errors'
)).Output | ConvertFrom-Json
$workspaceResourceId = $workspaceJson.id
$workspaceCustomerId = $workspaceJson.customerId

if ($syslogEnabled) {
    $rawSyslogRequired = @(
        'TimeGenerated', 'CollectorHostName', 'Computer', 'EventTime', 'Facility', 'HostIP',
        'HostName', 'ProcessID', 'ProcessName', 'SeverityLevel', 'SourceSystem', 'SyslogMessage'
    )
    $rawSyslogColumns = Get-TableColumns -WorkspaceResourceId $workspaceResourceId -TableName 'Syslog'
    $rawSyslogMissing = @($rawSyslogRequired | Where-Object { $_ -notin $rawSyslogColumns })
    Add-CheckResult 'Syslog table schema' ($rawSyslogMissing.Count -eq 0) $(
        if ($rawSyslogMissing.Count -eq 0) { 'all showcase columns present' } else { "missing $($rawSyslogMissing -join ', ')" }
    )

    $summaryRequired = @('TimeGenerated', 'DemoRunId', 'Site', 'SeverityLevel', 'EventCount')
    $summaryColumns = Get-TableColumns -WorkspaceResourceId $workspaceResourceId -TableName 'EdgeLogSummary_CL'
    $summaryMissing = @($summaryRequired | Where-Object { $_ -notin $summaryColumns })
    Add-CheckResult 'Summary table schema' ($summaryMissing.Count -eq 0) $(
        if ($summaryMissing.Count -eq 0) { 'all showcase columns present' } else { "missing $($summaryMissing -join ', ')" }
    )
}

if ($otlpEnabled) {
    $otlpRequired = @(
        'TimeGenerated', 'Body', 'SeverityText', 'DemoRunId', 'SequenceNumber',
        'ServiceName', 'DeploymentEnvironment', 'Site', 'TraceId', 'DurationMs', 'EventClass'
    )
    $otlpColumns = Get-TableColumns -WorkspaceResourceId $workspaceResourceId -TableName 'OTelLogs_CL'
    $otlpMissing = @($otlpRequired | Where-Object { $_ -notin $otlpColumns })
    Add-CheckResult 'OTLP table schema' ($otlpMissing.Count -eq 0) $(
        if ($otlpMissing.Count -eq 0) { 'all showcase columns present' } else { "missing $($otlpMissing -join ', ')" }
    )
}

if ($cefEnabled) {
    $cefRequired = @(
        'TimeGenerated', 'DeviceVendor', 'DeviceProduct', 'DeviceVersion',
        'DeviceEventClassID', 'Activity', 'LogSeverity', 'SourceIP',
        'DestinationIP', 'DestinationPort', 'DeviceCustomString1',
        'DeviceCustomString1Label'
    )
    $cefColumns = Get-TableColumns -WorkspaceResourceId $workspaceResourceId -TableName 'CommonSecurityLog'
    $cefMissing = @($cefRequired | Where-Object { $_ -notin $cefColumns })
    Add-CheckResult 'CommonSecurityLog table schema' ($cefMissing.Count -eq 0) $(
        if ($cefMissing.Count -eq 0) { 'all CEF demo columns present' } else { "missing $($cefMissing -join ', ')" }
    )
}

$pipelineResourceId = $pipelineJson.id
$metricNamesOutput = (Invoke-DemoAzCli -Arguments @(
    'monitor', 'metrics', 'list-definitions',
    '--resource', $pipelineResourceId,
    '--query', '[].name.value',
    '--output', 'tsv',
    '--only-show-errors'
) -AllowFailure).Output
$metricNames = @($metricNamesOutput -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$requiredMetrics = @(
    'process_cpu_utilization', 'process_memory_usage', 'process_uptime',
    'exported_log_records', 'log_records_failed_to_export'
)
$missingMetrics = @($requiredMetrics | Where-Object { $_ -notin $metricNames })
Add-CheckResult 'Pipeline metrics' ($missingMetrics.Count -eq 0) $(
    if ($missingMetrics.Count -eq 0) { 'built-in health metrics available' } else { "missing $($missingMetrics -join ', ')" }
)

$vmStateResult = Invoke-DemoAzCli -Arguments @(
    'vm', 'get-instance-view',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $vmName,
    '--query', "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]",
    '--output', 'tsv',
    '--only-show-errors'
) -AllowFailure
$vmPowerState = $vmStateResult.Output.Trim()
$vmRunning = $vmStateResult.ExitCode -eq 0 -and $vmPowerState -eq 'PowerState/running'
if ($vmRunning) {
    Add-CheckResult 'VM power state' $true $vmPowerState
}
else {
    $vmStateDetails = if ($vmStateResult.ExitCode -ne 0) {
        ConvertTo-DemoSanitizedOutput -Value $vmStateResult.Output
    } elseif ([string]::IsNullOrWhiteSpace($vmPowerState)) {
        'unknown'
    } else {
        $vmPowerState
    }
    $startCommand = "az vm start --subscription '$SubscriptionId' --resource-group '$ResourceGroupName' --name '$vmName'"
    Add-CheckResult 'VM power state' $false "$vmStateDetails. Start it with: $startCommand"
}

if ($vmRunning) {
    $clusterScript = Join-Path $PSScriptRoot 'demo\check-demo-cluster.sh'
    $clusterResult = $null
    try {
        $clusterResult = Invoke-DemoVmShellScript `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -VmName $vmName `
            -ScriptPath $clusterScript `
            -ScriptArguments @('azure-monitor-pipeline', $pipelineName, $persistentVolumeName, $Protocol)
        Add-CheckResult 'Cluster runtime' $true ($clusterResult -replace "`r?`n", '; ')
    }
    catch {
        Add-CheckResult 'Cluster runtime' $false $_.Exception.Message
    }

    $endpoint = (Invoke-DemoAzCli -Arguments @(
        'network', 'public-ip', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', "$NamePrefix-pip",
        '--query', 'ipAddress',
        '--output', 'tsv',
        '--only-show-errors'
    )).Output
    $ports = switch ($Protocol) {
        'Syslog' { @(514) }
        'OTLP' { @(4317) }
        'CEF' { @(515) }
        'All' { @(514, 4317, 515) }
        default { @(514, 4317) }
    }
    foreach ($port in $ports) {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $connected = $client.ConnectAsync($endpoint, $port).Wait([TimeSpan]::FromSeconds(10)) -and $client.Connected
            Add-CheckResult "TCP $port" $connected "${endpoint}:$port"
        }
        catch {
            Add-CheckResult "TCP $port" $false $_.Exception.Message
        }
        finally {
            $client.Dispose()
        }
    }
}
else {
    Write-Host '[SKIP] Cluster runtime and receiver ports: VM is not running.'
}

if (-not $SkipIngestionTest -and $failures.Count -eq 0) {
    $preflightDurationMinutes = 0.2
    $preflightEventsPerSecond = 2
    $expectedSentCount = [int]($preflightDurationMinutes * 60 * $preflightEventsPerSecond)
    $retainedPatternIndexes = @(2, 4, 6, 8, 9)
    $expectedRetainedCount = @(0..($expectedSentCount - 1) | Where-Object {
        ($_ % 10) -in $retainedPatternIndexes
    }).Count
    $runId = 'PREFLIGHT-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    Write-Host ''
    Write-Host "Sending a short preflight run: $runId"
    $senderFailed = $false
    if ($syslogEnabled -or $otlpEnabled) {
        $telemetryProtocol = if ($syslogEnabled -and $otlpEnabled) {
            'Both'
        }
        elseif ($syslogEnabled) {
            'Syslog'
        }
        else {
            'OTLP'
        }
        & (Join-Path $PSScriptRoot 'run-demo.ps1') `
            -Endpoint $endpoint `
            -DurationMinutes $preflightDurationMinutes `
            -EventsPerSecond $preflightEventsPerSecond `
            -RunId $runId `
            -Protocol $telemetryProtocol
        $senderFailed = $LASTEXITCODE -ne 0
    }
    $expectedCefCount = 10
    if ($cefEnabled -and -not $senderFailed) {
        & (Join-Path $PSScriptRoot 'send-cef-demo.ps1') `
            -Endpoint $endpoint `
            -RunId $runId `
            -Count $expectedCefCount `
            -ShowPayloadSample:$false
        $senderFailed = $LASTEXITCODE -ne 0
    }
    if ($senderFailed) {
        $failures.Add('Ingestion sender failed.')
    }
    else {
        $escapedRunId = $runId.Replace("'", "''")
        $deadline = [DateTime]::UtcNow.AddMinutes($MaxIngestionWaitMinutes)
        $ingestionPassed = $false
        do {
            $syslogRows = if ($syslogEnabled) { @(Get-QueryRows -WorkspaceCustomerId $workspaceCustomerId -QueryName 'Syslog' -Query @"
Syslog
| where TimeGenerated > ago(30m) and SyslogMessage contains '$escapedRunId'
| summarize Count=count(), Leaks=countif(SyslogMessage contains 'demo.user@example.com' or SyslogMessage contains 'demo-token-123'), Health=countif(SyslogMessage contains 'event_class=health'), Redacted=countif(SyslogMessage contains '[REDACTED_')
"@) } else { @() }
            $otlpRows = if ($otlpEnabled) { @(Get-QueryRows -WorkspaceCustomerId $workspaceCustomerId -QueryName 'OTelLogs_CL' -Query @"
OTelLogs_CL
| where TimeGenerated > ago(30m) and DemoRunId == '$escapedRunId'
| summarize Count=count(), Leaks=countif(Body contains 'demo.user@example.com' or Body contains 'demo-token-123'), Health=countif(EventClass == 'health'), Redacted=countif(Body contains '[REDACTED_')
"@) } else { @() }
            $summaryRows = if ($syslogEnabled) { @(Get-QueryRows -WorkspaceCustomerId $workspaceCustomerId -QueryName 'EdgeLogSummary_CL' -Query @"
EdgeLogSummary_CL
| where TimeGenerated > ago(30m) and DemoRunId == '$escapedRunId'
| summarize Rows=count(), Events=sum(EventCount)
"@) } else { @() }
            $cefRows = if ($cefEnabled) { @(Get-QueryRows -WorkspaceCustomerId $workspaceCustomerId -QueryName 'CommonSecurityLog' -Query @"
CommonSecurityLog
| where TimeGenerated > ago(30m) and DeviceCustomString1 == '$escapedRunId'
| summarize Count=count(), VendorMatches=countif(DeviceVendor == 'Contoso'), ProductMatches=countif(DeviceProduct == 'Demo Firewall')
"@) } else { @() }

            $syslogCount = Get-QueryValue -Rows $syslogRows -Name 'Count'
            $syslogLeaks = Get-QueryValue -Rows $syslogRows -Name 'Leaks'
            $syslogHealth = Get-QueryValue -Rows $syslogRows -Name 'Health'
            $syslogRedacted = Get-QueryValue -Rows $syslogRows -Name 'Redacted'
            $otlpCount = Get-QueryValue -Rows $otlpRows -Name 'Count'
            $otlpLeaks = Get-QueryValue -Rows $otlpRows -Name 'Leaks'
            $otlpHealth = Get-QueryValue -Rows $otlpRows -Name 'Health'
            $otlpRedacted = Get-QueryValue -Rows $otlpRows -Name 'Redacted'
            $summaryRowCount = Get-QueryValue -Rows $summaryRows -Name 'Rows'
            $summaryEventCount = Get-QueryValue -Rows $summaryRows -Name 'Events'
            $cefCount = Get-QueryValue -Rows $cefRows -Name 'Count'
            $cefVendorMatches = Get-QueryValue -Rows $cefRows -Name 'VendorMatches'
            $cefProductMatches = Get-QueryValue -Rows $cefRows -Name 'ProductMatches'

            $syslogPassed = -not $syslogEnabled -or (
                $syslogCount -eq $expectedRetainedCount -and $syslogLeaks -eq 0 -and
                $syslogHealth -eq 0 -and $syslogRedacted -eq $expectedRetainedCount -and
                $summaryRowCount -gt 0 -and $summaryEventCount -eq $expectedSentCount
            )
            $otlpPassed = -not $otlpEnabled -or (
                $otlpCount -eq $expectedRetainedCount -and $otlpLeaks -eq 0 -and
                $otlpHealth -eq 0 -and $otlpRedacted -eq $expectedRetainedCount
            )
            $cefPassed = -not $cefEnabled -or (
                $cefCount -eq $expectedCefCount -and
                $cefVendorMatches -eq $expectedCefCount -and
                $cefProductMatches -eq $expectedCefCount
            )
            $ingestionPassed = $syslogPassed -and $otlpPassed -and $cefPassed
            if ($ingestionPassed) {
                Add-CheckResult 'End-to-end ingestion' $true "$Protocol run $runId arrived with the expected processing"
                break
            }

            $progress = @()
            if ($syslogEnabled) {
                $progress += "Syslog $syslogCount/$expectedRetainedCount (redacted=$syslogRedacted, leaks=$syslogLeaks, health=$syslogHealth)"
                $progress += "Summary $summaryEventCount/$expectedSentCount events in $summaryRowCount row(s)"
            }
            if ($otlpEnabled) {
                $progress += "OTLP $otlpCount/$expectedRetainedCount (redacted=$otlpRedacted, leaks=$otlpLeaks, health=$otlpHealth)"
            }
            if ($cefEnabled) {
                $progress += "CEF $cefCount/$expectedCefCount (vendor=$cefVendorMatches, product=$cefProductMatches)"
            }
            Write-Host "Waiting for ingestion: $($progress -join '; ')."
            if ([DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Seconds 20
            }
        } while ([DateTime]::UtcNow -lt $deadline)

        if (-not $ingestionPassed) {
            Add-CheckResult 'End-to-end ingestion' $false "run $runId did not satisfy all checks within $MaxIngestionWaitMinutes minute(s)"
        }
    }
}
elseif ($SkipIngestionTest) {
    Write-Host '[SKIP] End-to-end ingestion: -SkipIngestionTest was specified.'
}
else {
    Write-Host '[SKIP] End-to-end ingestion: structural checks failed.'
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host 'Demo readiness: FAILED'
    $failures | ForEach-Object { Write-Host " - $_" }
    exit 1
}

Write-Host 'Demo readiness: PASSED'
Write-Host 'Open the pipeline Metrics blade before presenting; no custom workbook is required.'
