function Resolve-DemoConfigurationPath {
    param(
        [Parameter()][string] $Path,
        [Parameter(Mandatory)][string] $DefaultDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return Join-Path $DefaultDirectory 'demo.config.psd1'
    }
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Get-DemoConfiguration {
    param(
        [Parameter()][string] $Path,
        [Parameter(Mandatory)][string] $DefaultDirectory,
        [Parameter()][switch] $ExplicitPath
    )

    $resolvedPath = Resolve-DemoConfigurationPath -Path $Path -DefaultDirectory $DefaultDirectory
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        if ($ExplicitPath) {
            throw "Configuration file not found: $resolvedPath"
        }
        return [pscustomobject]@{
            Path   = $resolvedPath
            Values = @{}
        }
    }

    $values = Import-PowerShellDataFile -LiteralPath $resolvedPath
    if ($null -eq $values) {
        throw "Configuration file is empty or invalid: $resolvedPath"
    }

    return [pscustomobject]@{
        Path   = $resolvedPath
        Values = $values
    }
}

function Resolve-DemoConfigurationValue {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][Collections.IDictionary] $BoundParameters,
        [Parameter()] $CurrentValue,
        [Parameter(Mandatory)][Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][string] $ConfigurationPath,
        [Parameter()][switch] $Required
    )

    if ($BoundParameters.Keys -contains $Name) {
        return $CurrentValue
    }
    if ($Configuration.Keys -contains $Name) {
        return $Configuration[$Name]
    }
    if ($null -ne $CurrentValue -and -not [string]::IsNullOrWhiteSpace([string]$CurrentValue)) {
        return $CurrentValue
    }
    if ($Required) {
        throw "Missing '$Name'. Provide -$Name or create '$ConfigurationPath' from demo.config.example.psd1."
    }
    return $null
}

function Assert-DemoConfigurationValue {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Value
    )

    $pattern = switch ($Name) {
        'SubscriptionId' { '^[0-9a-fA-F-]{36}$' }
        'ResourceGroupName' { '^[A-Za-z0-9._()-]{1,90}$' }
        'NamePrefix' { '^[a-z0-9]{3,12}$' }
        default { '^.+$' }
    }
    if ($Value -notmatch $pattern) {
        throw "Configuration value '$Name' is invalid."
    }
}

function Write-DemoConfiguration {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $NamePrefix,
        [Parameter(Mandatory)][string] $Endpoint
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $escape = {
        param([string] $Value)
        return $Value.Replace("'", "''")
    }
    $content = @"
@{
    SubscriptionId   = '$(& $escape $SubscriptionId)'
    ResourceGroupName = '$(& $escape $ResourceGroupName)'
    NamePrefix        = '$(& $escape $NamePrefix)'
    Endpoint          = '$(& $escape $Endpoint)'
}
"@
    [IO.File]::WriteAllText($Path, $content, [Text.UTF8Encoding]::new($false))
}
