[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Endpoint,

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int] $Port = 515,

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int] $Count = 10,

    [Parameter()]
    [ValidateRange(0, 60000)]
    [int] $DelayMilliseconds = 100,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$')]
    [string] $RunId = ('CEF-DEMO-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')),

    [Parameter()]
    [ValidateRange(1, 30)]
    [int] $TimeoutSeconds = 10,

    [Parameter()]
    [switch] $ShowPayloadSample = $true,

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

$client = [Net.Sockets.TcpClient]::new()
$sent = 0
$firstMessage = $null

try {
    $connectTask = $client.ConnectAsync($Endpoint, $Port)
    if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds)) -or -not $client.Connected) {
        throw "Timed out connecting to ${Endpoint}:$Port. Confirm this client's public IP is allowed by the NSG and run setup-demo.ps1 to configure the CEF route."
    }

    $client.SendTimeout = $TimeoutSeconds * 1000
    $stream = $client.GetStream()
    for ($sequence = 1; $sequence -le $Count; $sequence++) {
        $timestamp = [DateTime]::UtcNow.ToString(
            'yyyy-MM-ddTHH:mm:ss.fffZ',
            [Globalization.CultureInfo]::InvariantCulture
        )
        $sourcePort = 50000 + $sequence
        $cef = "CEF:0|Contoso|Demo Firewall|1.0|100|Allowed HTTPS connection|5|src=192.0.2.10 dst=198.51.100.20 spt=$sourcePort dpt=443 act=allow proto=TCP cs1Label=DemoRunId cs1=$RunId msg=Synthetic CEF ingestion event $sequence"
        $message = "<134>1 $timestamp demo-cef-sender cef-demo $sequence CEF - $cef`n"
        if ($null -eq $firstMessage) {
            $firstMessage = $message.TrimEnd()
        }

        $bytes = [Text.Encoding]::UTF8.GetBytes($message)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $sent++

        if ($DelayMilliseconds -gt 0 -and $sequence -lt $Count) {
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
}
finally {
    $client.Dispose()
}

if ($ShowPayloadSample) {
    Write-Host 'Source payload sample:'
    Write-Host $firstMessage
    Write-Host ''
}

[pscustomobject]@{
    Protocol = 'CEF over Syslog/TCP'
    Endpoint = "${Endpoint}:$Port"
    RunId    = $RunId
    Sent     = $sent
    SentUtc  = [DateTime]::UtcNow.ToString('o')
}
