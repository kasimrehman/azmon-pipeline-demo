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
    [ValidateRange(15, 300)]
    [int] $OutageSeconds = 60,

    [Parameter()]
    [ValidateRange(1, 20)]
    [int] $EventsPerSecond = 2,

    [Parameter()]
    [ValidateSet('Syslog', 'OTLP', 'Both')]
    [string] $Protocol = 'Both',

    [Parameter()]
    [ValidateRange(1, 30)]
    [int] $MaxIngestionWaitMinutes = 15,

    [Parameter()]
    [string] $ConfigFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AZURE_CORE_COLLECT_TELEMETRY = 'no'
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

$runDemoScript = Join-Path $PSScriptRoot 'run-demo.ps1'
$outageScript = Join-Path $PSScriptRoot 'set-demo-outage.ps1'
$syslogEnabled = $Protocol -in @('Syslog', 'Both')
$otlpEnabled = $Protocol -in @('OTLP', 'Both')
$runId = 'RECOVERY-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$senderJob = $null
$blockAttempted = $false
$consecutiveQueryFailures = 0
$stopFilePath = Join-Path ([IO.Path]::GetTempPath()) "azmon-recovery-stop-$([Guid]::NewGuid().ToString('N'))"

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
        $script:consecutiveQueryFailures++
        $details = ConvertTo-DemoSanitizedOutput -Value $result.Output
        if ($script:consecutiveQueryFailures -ge 3) {
            throw "$QueryName query failed $script:consecutiveQueryFailures consecutive times: $details"
        }
        Write-Warning "$QueryName query failed (attempt $script:consecutiveQueryFailures of 3): $details"
        return @()
    }

    $script:consecutiveQueryFailures = 0
    return @($result.Output | ConvertFrom-Json)
}

function Wait-SenderSequence {
    param(
        [Parameter(Mandatory)][System.Management.Automation.Job] $Job,
        [Parameter(Mandatory)][int] $MinimumSequence,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if ($Job.State -in @('Failed', 'Stopped', 'Completed')) {
            Receive-Job -Job $Job -Keep
            throw "The telemetry sender stopped before sequence $MinimumSequence. Job state: $($Job.State)."
        }

        $senderOutput = @(Receive-Job -Job $Job -Keep -ErrorAction SilentlyContinue 6>&1) -join "`n"
        $sequences = @([regex]::Matches($senderOutput, '"sequence"\s*:\s*([0-9]+)') | ForEach-Object {
            [int] $_.Groups[1].Value
        })
        if ($sequences.Count -gt 0 -and ($sequences | Measure-Object -Maximum).Maximum -ge $MinimumSequence) {
            return
        }

        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for the telemetry sender to reach sequence $MinimumSequence."
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

$durationSeconds = 15 + $OutageSeconds + 300
$durationMinutes = $durationSeconds / 60.0
Write-Host "Recovery run ID: $runId"
Write-Host "Protocol: $Protocol"
Write-Host "Traffic will continue until 30 seconds after the $OutageSeconds-second DCE-path interruption is restored."

try {
    $senderJob = Start-Job -ScriptBlock {
        param($ScriptPath, $Endpoint, $DurationMinutes, $EventsPerSecond, $RunId, $StopFilePath, $Protocol)
        & $ScriptPath `
            -Endpoint $Endpoint `
            -DurationMinutes $DurationMinutes `
            -EventsPerSecond $EventsPerSecond `
            -RunId $RunId `
            -StopFilePath $StopFilePath `
            -Protocol $Protocol
    } -ArgumentList $runDemoScript, $endpoint, $durationMinutes, $EventsPerSecond, $runId, $stopFilePath, $Protocol

    Wait-SenderSequence -Job $senderJob -MinimumSequence ($EventsPerSecond * 10) -TimeoutSeconds 90

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

    Write-Host 'Sending for 30 seconds after restoration...'
    Start-Sleep -Seconds 30
    New-Item -ItemType File -Path $stopFilePath -Force | Out-Null

    Wait-Job -Job $senderJob | Out-Null
    $senderOutput = @(Receive-Job -Job $senderJob 6>&1)
    $senderOutput | ForEach-Object { Write-Host $_.ToString() }
    if ($senderJob.State -ne 'Completed') {
        throw "The telemetry sender did not complete successfully. Job state: $($senderJob.State)."
    }

    $completionLine = $senderOutput | ForEach-Object { $_.ToString() } |
        Where-Object { $_ -match '"status":\s*"(?:completed|stopped)"' } |
        Select-Object -Last 1
    if (-not $completionLine) {
        throw 'The telemetry sender did not return its final event counts.'
    }
    $completion = $completionLine | ConvertFrom-Json
    $syslogSentCount = [int]$completion.counts.syslog
    $otlpSentCount = [int]$completion.counts.otlp
    $expectedSentCount = if ($syslogEnabled) { $syslogSentCount } else { $otlpSentCount }
    if (
        $expectedSentCount -le 0 -or
        ($syslogEnabled -and $syslogSentCount -ne $expectedSentCount) -or
        ($otlpEnabled -and $otlpSentCount -ne $expectedSentCount) -or
        (-not $syslogEnabled -and $syslogSentCount -ne 0) -or
        (-not $otlpEnabled -and $otlpSentCount -ne 0)
    ) {
        throw "The telemetry sender reported invalid $Protocol counts: Syslog=$syslogSentCount, OTLP=$otlpSentCount."
    }
    $retainedPatternIndexes = @(2, 4, 6, 8, 9)
    $expectedRetainedCount = @(0..($expectedSentCount - 1) | Where-Object {
        ($_ % 10) -in $retainedPatternIndexes
    }).Count
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
    Remove-Item -LiteralPath $stopFilePath -Force -ErrorAction SilentlyContinue
}

$escapedRunId = $runId.Replace("'", "''")
$blockedLiteral = $blockedAt.ToUniversalTime().ToString('o')
$restoredLiteral = $restoredAt.ToUniversalTime().ToString('o')
$deadline = [DateTime]::UtcNow.AddMinutes($MaxIngestionWaitMinutes)
$recoveryPassed = $false

do {
    $syslogRows = if ($syslogEnabled) { @(Get-QueryRows -WorkspaceCustomerId $workspaceCustomerId -QueryName 'Syslog' -Query @"
let BlockedAt=datetime($blockedLiteral);
let RestoredAt=datetime($restoredLiteral);
Syslog
| where TimeGenerated > ago(30m) and SyslogMessage contains '$escapedRunId'
| summarize Count=count(), Before=countif(TimeGenerated < BlockedAt), During=countif(TimeGenerated between (BlockedAt .. RestoredAt)), After=countif(TimeGenerated > RestoredAt), Leaks=countif(SyslogMessage contains 'demo.user@example.com' or SyslogMessage contains 'demo-token-123'), Health=countif(SyslogMessage contains 'event_class=health'), Redacted=countif(SyslogMessage contains '[REDACTED_')
"@) } else { @() }
    $otlpRows = if ($otlpEnabled) { @(Get-QueryRows -WorkspaceCustomerId $workspaceCustomerId -QueryName 'OTelLogs_CL' -Query @"
let BlockedAt=datetime($blockedLiteral);
let RestoredAt=datetime($restoredLiteral);
OTelLogs_CL
| where TimeGenerated > ago(30m) and DemoRunId == '$escapedRunId'
| summarize Count=count(), Before=countif(TimeGenerated < BlockedAt), During=countif(TimeGenerated between (BlockedAt .. RestoredAt)), After=countif(TimeGenerated > RestoredAt), DistinctSequences=dcount(SequenceNumber), Leaks=countif(Body contains 'demo.user@example.com' or Body contains 'demo-token-123'), Health=countif(EventClass == 'health'), Redacted=countif(Body contains '[REDACTED_')
"@) } else { @() }
    $summaryRows = if ($syslogEnabled) { @(Get-QueryRows -WorkspaceCustomerId $workspaceCustomerId -QueryName 'EdgeLogSummary_CL' -Query @"
EdgeLogSummary_CL
| where TimeGenerated > ago(30m) and DemoRunId == '$escapedRunId'
| summarize Rows=count(), Events=sum(EventCount)
"@) } else { @() }

    $requiredRowsPresent = (
        (-not $syslogEnabled -or ($syslogRows.Count -gt 0 -and $summaryRows.Count -gt 0)) -and
        (-not $otlpEnabled -or $otlpRows.Count -gt 0)
    )
    if ($requiredRowsPresent) {
        $syslogPassed = $true
        $otlpPassed = $true
        $observations = @()
        if ($syslogEnabled) {
            $syslog = $syslogRows[0]
            $summary = $summaryRows[0]
            $syslogPassed = (
                [long]$syslog.Before -gt 0 -and [long]$syslog.After -gt 0 -and
                [long]$syslog.Leaks -eq 0 -and [long]$syslog.Health -eq 0 -and
                [long]$summary.Rows -gt 0 -and [long]$summary.Events -eq $expectedSentCount
            )
            $observations += "Raw before/during/after=$($syslog.Before)/$($syslog.During)/$($syslog.After)"
            $observations += "Summary events=$($summary.Events)/$expectedSentCount"
        }
        if ($otlpEnabled) {
            $otlp = $otlpRows[0]
            $otlpPassed = (
                [long]$otlp.Before -gt 0 -and [long]$otlp.During -gt 0 -and [long]$otlp.After -gt 0 -and
                [long]$otlp.Count -eq $expectedRetainedCount -and [long]$otlp.DistinctSequences -eq $expectedRetainedCount -and
                [long]$otlp.Leaks -eq 0 -and [long]$otlp.Health -eq 0 -and
                [long]$otlp.Redacted -eq $expectedRetainedCount
            )
            $observations += "OTLP before/during/after=$($otlp.Before)/$($otlp.During)/$($otlp.After), distinct=$($otlp.DistinctSequences)/$expectedRetainedCount"
        }
        $recoveryPassed = $syslogPassed -and $otlpPassed
        if ($recoveryPassed) {
            Write-Host "[PASS] $Protocol recovery completed for $runId. $($observations -join '; ')."
            break
        }

        Write-Host "Observed recovery: $($observations -join '; ')."
    }

    Write-Host 'Waiting for buffered records to drain into Log Analytics...'
    Start-Sleep -Seconds 20
} while ([DateTime]::UtcNow -lt $deadline)

if (-not $recoveryPassed) {
    throw "Recovery run $runId did not prove the expected $Protocol recovery behavior within $MaxIngestionWaitMinutes minute(s)."
}