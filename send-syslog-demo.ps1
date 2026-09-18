[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Endpoint,

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int] $Port = 514,

    [Parameter()]
    [ValidateRange(1, 30)]
    [int] $TimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$marker = 'ARC-MONITOR-DEMO-SYSLOG-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$timestamp = [DateTime]::UtcNow.ToString(
    'yyyy-MM-ddTHH:mm:ss.fffZ',
    [Globalization.CultureInfo]::InvariantCulture
)
$hostname = [Environment]::MachineName
$message = "<14>1 $timestamp $hostname arc-monitor-demo - - - $marker`n"
$client = [Net.Sockets.TcpClient]::new()

try {
    $connectTask = $client.ConnectAsync($Endpoint, $Port)
    if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds)) -or -not $client.Connected) {
        throw "Timed out connecting to ${Endpoint}:$Port. Confirm this client's public IP is allowed by the NSG."
    }

    $stream = $client.GetStream()
    $bytes = [Text.Encoding]::UTF8.GetBytes($message)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()

    [pscustomobject]@{
        Protocol = 'Syslog/TCP'
        Endpoint = "${Endpoint}:$Port"
        Marker   = $marker
        SentUtc  = $timestamp
    }
}
finally {
    $client.Dispose()
}