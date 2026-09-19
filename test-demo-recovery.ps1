[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')]
    [string] $ResourceGroupName = 'rg-arc-monitor-demo',

    [Parameter()]
    [ValidatePattern('^[a-z0-9]{3,12}$')]
    [string] $NamePrefix = 'arcmon',

    [Parameter()]
    [ValidateRange(15, 300)]
    [int] $OutageSeconds = 60,

    [Parameter()]
    [ValidateRange(1, 20)]
    [int] $EventsPerSecond = 2,

    [Parameter()]
    [ValidateRange(1, 30)]
    [int] $MaxIngestionWaitMinutes = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

. (Join-Path $PSScriptRoot 'demo\demo-common.ps1')

$runDemoScript = Join-Path $PSScriptRoot 'run-demo.ps1'
$outageScript = Join-Path $PSScriptRoot 'set-demo-outage.ps1'
$runId = 'RECOVERY-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$senderJob = $null
$blockAttempted = $false

function Get-QueryRows {
    param(
        [Parameter(Mandatory)][string] $WorkspaceCustomerId,
        [Parameter(Mandatory)][string] $Query
    )

    $result = Invoke-DemoAzCli -Arguments @(
        'monitor', 'log-analytics', 'query',
        '--workspace', $WorkspaceCustomerId,
        '--analytics-query', $Query,
        '--timespan', 'PT30M',
        '--output', 'json',
        '--only-show-errors'
    ) -AllowFailure
    if ($result.ExitCode -ne 0) {
        return @()
    }
    return @($result.Output | ConvertFrom-Json)
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required and was not found on PATH.'
}
foreach ($requiredFile in @($runDemoScript, $outageScript)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required demo file not found: $requiredFile"
    }
}

Invoke-DemoAzCli -Arguments @(
    'account', 'set', '--subscription', $SubscriptionId, '--output', 'none'
) | Out-Null

$endpoint = (Invoke-DemoAzCli -Arguments @(
    'network', 'public-ip', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', "$NamePrefix-pip",
    '--query', 'ipAddress',
    '--output', 'tsv',
    '--only-show-errors'
)).Output
$workspaceCustomerId = (Invoke-DemoAzCli -Arguments @(
    'monitor', 'log-analytics', 'workspace', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--workspace-name', "$NamePrefix-law",
    '--query', 'customerId',
    '--output', 'tsv',
    '--only-show-errors'
)).Output

$durationSeconds = 15 + $OutageSeconds + 30
$durationMinutes = $durationSeconds / 60.0
Write-Host "Recovery run ID: $runId"
Write-Host "Traffic will run for $durationSeconds seconds with a $OutageSeconds-second DCE-path interruption."

try {
    $senderJob = Start-Job -ScriptBlock {
        param($ScriptPath, $Endpoint, $DurationMinutes, $EventsPerSecond, $RunId)
        & $ScriptPath `
            -Endpoint $Endpoint `
            -DurationMinutes $DurationMinutes `
            -EventsPerSecond $EventsPerSecond `
            -RunId $RunId
    } -ArgumentList $runDemoScript, $endpoint, $durationMinutes, $EventsPerSecond, $runId

    Start-Sleep -Seconds 15
    if ($senderJob.State -in @('Failed', 'Stopped', 'Completed')) {
        Receive-Job -Job $senderJob
        throw "The telemetry sender stopped before the outage could be applied. Job state: $($senderJob.State)."
    }

    Write-Host 'Applying the DCE-path interruption...'
    $blockAttempted = $true
    & $outageScript `
        -Action Block `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -NamePrefix $NamePrefix
    $blockedAt = [DateTime]::UtcNow

    Start-Sleep -Seconds $OutageSeconds

    Write-Host 'Restoring the DCE path...'
    & $outageScript `
        -Action Restore `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -NamePrefix $NamePrefix
    $blockAttempted = $false
    $restoredAt = [DateTime]::UtcNow

    Wait-Job -Job $senderJob | Out-Null
    Receive-Job -Job $senderJob
    if ($senderJob.State -ne 'Completed') {
        throw "The telemetry sender did not complete successfully. Job state: $($senderJob.State)."
    }
}
finally {
    if ($blockAttempted) {
        Write-Warning 'Recovery test was interrupted; restoring the DCE path.'
        & $outageScript `
            -Action Restore `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -NamePrefix $NamePrefix
    }
    if ($null -ne $senderJob) {
        if ($senderJob.State -eq 'Running') {
            Stop-Job -Job $senderJob
        }
        Remove-Job -Job $senderJob -Force
    }
}

$escapedRunId = $runId.Replace("'", "''")
$blockedLiteral = $blockedAt.ToUniversalTime().ToString('o')
$restoredLiteral = $restoredAt.ToUniversalTime().ToString('o')
$deadline = [DateTime]::UtcNow.AddMinutes($MaxIngestionWaitMinutes)
$recoveryPassed = $false

do {
    $syslogRows = @(Get-QueryRows -WorkspaceCustomerId $workspaceCustomerId -Query @"
let BlockedAt=datetime($blockedLiteral);
let RestoredAt=datetime($restoredLiteral);
Syslog
| where TimeGenerated > ago(30m) and SyslogMessage contains '$escapedRunId'
| summarize Before=countif(TimeGenerated < BlockedAt), During=countif(TimeGenerated between (BlockedAt .. RestoredAt)), After=countif(TimeGenerated > RestoredAt)
"@)
    $otlpRows = @(Get-QueryRows -WorkspaceCustomerId $workspaceCustomerId -Query @"
let BlockedAt=datetime($blockedLiteral);
let RestoredAt=datetime($restoredLiteral);
OTelLogs_CL
| where TimeGenerated > ago(30m) and DemoRunId == '$escapedRunId'
| summarize Before=countif(TimeGenerated < BlockedAt), During=countif(TimeGenerated between (BlockedAt .. RestoredAt)), After=countif(TimeGenerated > RestoredAt), DistinctSequences=dcount(SequenceNumber)
"@)

    if ($syslogRows.Count -gt 0 -and $otlpRows.Count -gt 0) {
        $syslog = $syslogRows[0]
        $otlp = $otlpRows[0]
        $recoveryPassed = (
            [long]$syslog.Before -gt 0 -and [long]$syslog.During -gt 0 -and [long]$syslog.After -gt 0 -and
            [long]$otlp.Before -gt 0 -and [long]$otlp.During -gt 0 -and [long]$otlp.After -gt 0 -and
            [long]$otlp.DistinctSequences -gt 0
        )
        if ($recoveryPassed) {
            Write-Host "[PASS] Persistent recovery: Syslog and OTLP records generated before, during, and after the outage arrived for $runId."
            break
        }
    }

    Write-Host 'Waiting for buffered records to drain into Log Analytics...'
    Start-Sleep -Seconds 20
} while ([DateTime]::UtcNow -lt $deadline)

if (-not $recoveryPassed) {
    throw "Recovery run $runId did not show Syslog and OTLP records from all three phases within $MaxIngestionWaitMinutes minute(s)."
}