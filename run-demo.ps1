[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Endpoint,

    [Parameter()]
    [ValidateRange(0.1, 120)]
    [double] $DurationMinutes = 10,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int] $EventsPerSecond = 5,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$')]
    [string] $RunId = ('DEMO-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')),

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int] $SyslogPort = 514,

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int] $OtlpPort = 4317,

    [Parameter()]
    [ValidateRange(1, 30)]
    [int] $TimeoutSeconds = 10,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $PythonCommand = 'py',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $StopFilePath,

    [Parameter()]
    [switch] $ShowPayloadSample
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$emitter = Join-Path $PSScriptRoot 'demo\send-demo-telemetry.py'
$cacheRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'azmon-pipeline-demo'
$virtualEnvironment = Join-Path $cacheRoot 'otel-1.44.0'
$python = Join-Path $virtualEnvironment 'Scripts\python.exe'
$readyMarker = Join-Path $virtualEnvironment '.ready'

if (-not (Get-Command $PythonCommand -ErrorAction SilentlyContinue)) {
    throw "Python command '$PythonCommand' was not found. Install Python 3 or pass -PythonCommand with its executable path."
}
if (-not (Test-Path -LiteralPath $emitter -PathType Leaf)) {
    throw "Demo telemetry emitter not found: $emitter"
}

foreach ($port in @($SyslogPort, $OtlpPort)) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $client.ConnectAsync($Endpoint, $port)
        if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds)) -or -not $client.Connected) {
            throw "Timed out connecting to ${Endpoint}:$port. Confirm this client's public IP is allowed by the NSG."
        }
    }
    finally {
        $client.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $readyMarker -PathType Leaf)) {
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    if (Test-Path -LiteralPath $virtualEnvironment) {
        Remove-Item -LiteralPath $virtualEnvironment -Recurse -Force
    }

    Write-Host 'Preparing the cached OpenTelemetry sender environment (first run only)...'
    & $PythonCommand -m venv $virtualEnvironment
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the cached Python virtual environment.'
    }

    & $python -m pip install --quiet --disable-pip-version-check `
        'opentelemetry-sdk==1.44.0' `
        'opentelemetry-exporter-otlp-proto-grpc==1.44.0'
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to install the OpenTelemetry packages.'
    }
    New-Item -ItemType File -Path $readyMarker -Force | Out-Null
}

$durationSeconds = [Math]::Round($DurationMinutes * 60, 3)
Write-Host "Run ID: $RunId"
Write-Host "Sending $EventsPerSecond events/second to each protocol for $DurationMinutes minute(s)."
Write-Host 'Press Ctrl+C to stop early; the sender will flush queued OTLP records.'
Write-Host ''

$emitterArguments = @(
    '--endpoint', $Endpoint,
    '--duration-seconds', $durationSeconds,
    '--events-per-second', $EventsPerSecond,
    '--run-id', $RunId,
    '--syslog-port', $SyslogPort,
    '--otlp-port', $OtlpPort,
    '--timeout-seconds', $TimeoutSeconds
)
if ($StopFilePath) {
    $emitterArguments += @('--stop-file', $StopFilePath)
}
if ($ShowPayloadSample) {
    $emitterArguments += '--show-payload-sample'
}

& $python $emitter @emitterArguments

if ($LASTEXITCODE -ne 0) {
    throw "The demo telemetry emitter exited with code $LASTEXITCODE."
}
