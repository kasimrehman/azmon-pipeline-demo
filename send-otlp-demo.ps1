[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Endpoint,

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int] $Port = 4317,

    [Parameter()]
    [ValidateRange(1, 30)]
    [int] $TimeoutSeconds = 15,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $PythonCommand = 'py',

    [Parameter()]
    [string] $ConfigFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'demo\demo-config.ps1')
$configState = Get-DemoConfiguration `
    -Path $ConfigFile `
    -DefaultDirectory $PSScriptRoot `
    -ExplicitPath:($PSBoundParameters.ContainsKey('ConfigFile'))
$Endpoint = Resolve-DemoConfigurationValue -Name 'Endpoint' -BoundParameters $PSBoundParameters -CurrentValue $Endpoint -Configuration $configState.Values -ConfigurationPath $configState.Path -Required
Assert-DemoConfigurationValue -Name 'Endpoint' -Value $Endpoint

if (-not (Get-Command $PythonCommand -ErrorAction SilentlyContinue)) {
    throw "Python command '$PythonCommand' was not found. Install Python 3 or pass -PythonCommand with its executable path."
}

$client = [Net.Sockets.TcpClient]::new()
try {
    $connectTask = $client.ConnectAsync($Endpoint, $Port)
    if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds)) -or -not $client.Connected) {
        throw "Timed out connecting to ${Endpoint}:$Port. Confirm this client's public IP is allowed by the NSG."
    }
}
finally {
    $client.Dispose()
}

$marker = 'ARC-MONITOR-DEMO-OTLP-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$temporaryVenv = Join-Path (
    [IO.Path]::GetTempPath()
) ('arc-monitor-otel-' + [Guid]::NewGuid().ToString('N'))

try {
    & $PythonCommand -m venv $temporaryVenv
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the temporary Python virtual environment.'
    }

    $python = Join-Path $temporaryVenv 'Scripts\python.exe'
    & $python -m pip install --quiet --disable-pip-version-check `
        'opentelemetry-sdk==1.44.0' `
        'opentelemetry-exporter-otlp-proto-grpc==1.44.0'
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to install the OpenTelemetry packages.'
    }

    @'
import logging
import sys

from opentelemetry import _logs
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import SimpleLogRecordProcessor
from opentelemetry.sdk.resources import Resource


class CheckedOTLPLogExporter(OTLPLogExporter):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.last_result = None

    def export(self, batch):
        self.last_result = super().export(batch)
        return self.last_result


marker, endpoint, port, timeout = sys.argv[1:]
provider = LoggerProvider(
    resource=Resource.create({"service.name": "arc-monitor-external-demo"})
)
exporter = CheckedOTLPLogExporter(
    endpoint=f"{endpoint}:{port}",
    insecure=True,
    timeout=int(timeout),
)
provider.add_log_record_processor(SimpleLogRecordProcessor(exporter))
_logs.set_logger_provider(provider)

logger = logging.getLogger("arc.monitor.demo")
logger.handlers.clear()
logger.propagate = False
logger.setLevel(logging.INFO)
logger.addHandler(LoggingHandler(level=logging.INFO, logger_provider=provider))
logger.info(marker, extra={"arc.monitor.demo.marker": marker})

flushed = provider.force_flush(timeout_millis=int(timeout) * 1000)
result_name = getattr(exporter.last_result, "name", "")
provider.shutdown()

if not flushed:
    raise RuntimeError("OTLP force_flush timed out")
if result_name != "SUCCESS":
    raise RuntimeError(f"OTLP exporter returned {result_name or 'no result'}")
'@ | & $python - $marker $Endpoint $Port $TimeoutSeconds

    if ($LASTEXITCODE -ne 0) {
        throw 'The OTLP exporter did not report a successful export.'
    }

    [pscustomobject]@{
        Protocol = 'OTLP/gRPC'
        Endpoint = "${Endpoint}:$Port"
        Marker   = $marker
        SentUtc  = [DateTime]::UtcNow.ToString('o')
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryVenv) {
        Remove-Item -LiteralPath $temporaryVenv -Recurse -Force
    }
}