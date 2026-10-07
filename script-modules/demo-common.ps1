# Shared Azure CLI and VM Run Command helpers.
function Invoke-DemoAzCli {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter()]
        [switch] $AllowFailure
    )

    $output = @(& az @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw $text
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $text
    }
}

function ConvertTo-DemoShellLiteral {
    param([Parameter(Mandatory)][string] $Value)

    if ($Value.Contains("'")) {
        throw 'Shell arguments cannot contain a single quote.'
    }
    return "'$Value'"
}

function ConvertTo-DemoSanitizedOutput {
    param([Parameter(Mandatory)][string] $Value)

    $sanitized = $Value -replace '(?im)\b(authorization|password|passwd|token|secret|credential|client[_ -]?secret|access[_ -]?key|connection[_ -]?string)\b\s*[:=]\s*\S+', '$1=[REDACTED]'
    $sanitized = $sanitized -replace '(?i)([?&](?:sig|se|sp|sv|ske|sks|skv)=)[^&\s]+', '$1[REDACTED]'
    return ($sanitized -replace '(?m)^__AZMON_DEMO_EXIT_CODE=\d+\r?$', '').Trim()
}

function Invoke-DemoVmShellScript {
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter()][string[]] $ScriptArguments = @()
    )

    $remotePath = "/tmp/azmon-demo-$([Guid]::NewGuid().ToString('N')).sh"
    $argumentText = ($ScriptArguments | ForEach-Object { ConvertTo-DemoShellLiteral $_ }) -join ' '
    $delimiter = "AZMON_DEMO_SCRIPT_$([Guid]::NewGuid().ToString('N'))"
    $wrapperPath = Join-Path ([IO.Path]::GetTempPath()) "azmon-demo-$([Guid]::NewGuid().ToString('N')).sh"
    $scriptContent = Get-Content -LiteralPath $ScriptPath -Raw
    $wrapperContent = @"
#!/usr/bin/env bash
cat > '$remotePath' <<'$delimiter'
$scriptContent
$delimiter
chmod 700 '$remotePath'
'$remotePath' $argumentText
status=`$?
rm -f '$remotePath'
echo __AZMON_DEMO_EXIT_CODE=`$status
exit 0
"@

    try {
        [IO.File]::WriteAllText($wrapperPath, $wrapperContent, [Text.UTF8Encoding]::new($false))
        $result = Invoke-DemoAzCli -Arguments @(
            'vm', 'run-command', 'invoke',
            '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroupName,
            '--name', $VmName,
            '--command-id', 'RunShellScript',
            '--scripts', "@$wrapperPath",
            '--query', 'value[0].message',
            '--output', 'tsv',
            '--only-show-errors'
        )
    }
    finally {
        Remove-Item -LiteralPath $wrapperPath -Force -ErrorAction SilentlyContinue
    }

    if ($result.Output -notmatch '(?m)^__AZMON_DEMO_EXIT_CODE=(\d+)\r?$') {
        throw "Azure VM Run Command did not return a guest exit code for '$([IO.Path]::GetFileName($ScriptPath))'."
    }
    if ([int] $Matches[1] -ne 0) {
        $details = ConvertTo-DemoSanitizedOutput -Value $result.Output
        throw "Guest script '$([IO.Path]::GetFileName($ScriptPath))' failed with exit code $($Matches[1]).`n$details"
    }

    return ConvertTo-DemoSanitizedOutput -Value $result.Output
}
