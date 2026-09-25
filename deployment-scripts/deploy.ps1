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
    [ValidatePattern('^[a-z0-9]+$')]
    [string] $Location = 'eastus2',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $AllowedSourceCidr,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $SshPublicKeyPath,

    [Parameter()]
    [ValidatePattern('^[a-z_][a-z0-9_-]{0,31}$')]
    [string] $AdminUsername = 'azureuser',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $VmSize = 'Standard_D4as_v5',

    [Parameter()]
    [ValidatePattern('^v1\.[0-9]+\.[0-9]+\+k3s[0-9]+$')]
    [string] $K3sVersion = 'v1.33.3+k3s1',

    [Parameter()]
    [string] $ConfigFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$configHelper = Join-Path $repositoryRoot 'script-modules\demo-config.ps1'
. $configHelper
$configPath = Resolve-DemoConfigurationPath `
    -Path $ConfigFile `
    -DefaultDirectory $repositoryRoot
$infraTemplate = Join-Path $repositoryRoot 'infra.bicep'
$monitoringTemplate = Join-Path $repositoryRoot 'monitoring.bicep'
$bootstrapScript = Join-Path $PSScriptRoot 'bootstrap-k3s.sh'
$pipelinePreparationScript = Join-Path $PSScriptRoot 'prepare-pipeline.sh'
$pipelineNamespace = 'azure-monitor-pipeline'
$certificateExtensionName = 'azure-cert-management'
$pipelineExtensionName = 'azure-monitor-pipeline'
$workloadTagValue = 'azure-monitor-pipeline-demo'
$onboardingRoleDefinitionId = '34e09817-6cbe-4d01-b1a2-e0eac5743d41'
$customLocationsServiceAppId = 'bc313c14-388c-4e7d-a58e-70017303ee3b'
$requiredProviders = @(
    'Microsoft.Authorization',
    'Microsoft.Compute',
    'Microsoft.ExtendedLocation',
    'Microsoft.Insights',
    'Microsoft.Kubernetes',
    'Microsoft.KubernetesConfiguration',
    'Microsoft.Monitor',
    'Microsoft.Network',
    'Microsoft.OperationalInsights'
)

function Write-DeploymentStatus {
    param([Parameter(Mandatory)][string] $Message)

    Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $Message"
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter()]
        [switch] $AllowFailure
    )

    $commandPath = ($Arguments | Select-Object -First 3 | Where-Object { -not $_.StartsWith('--') }) -join ' '
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    Write-DeploymentStatus "Starting: az $commandPath"
    $output = @(& az @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $stopwatch.Stop()
    Write-DeploymentStatus "Finished: az $commandPath (exit $exitCode, $([Math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s)"
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $message = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "Azure CLI command failed (exit $exitCode): az $($Arguments[0]) $($Arguments[1])`n$message"
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output = (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
    }
}

function ConvertFrom-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $result = Invoke-AzCli -Arguments ($Arguments + @('--output', 'json', '--only-show-errors'))
    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return $null
    }

    return $result.Output | ConvertFrom-Json
}

function Assert-Cidr {
    param([Parameter(Mandatory)][string] $Value)

    $parts = $Value.Split('/')
    $address = $null
    $prefix = 0
    if (
        $parts.Count -ne 2 -or
        -not [Net.IPAddress]::TryParse($parts[0], [ref] $address) -or
        -not [int]::TryParse($parts[1], [ref] $prefix)
    ) {
        throw "AllowedSourceCidr must be valid CIDR notation, for example 203.0.113.10/32."
    }

    if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'AllowedSourceCidr must be an IPv4 CIDR because the demo public IP is IPv4-only.'
    }
    if ($prefix -lt 0 -or $prefix -gt 32) {
        throw "AllowedSourceCidr has an invalid prefix length."
    }
}

function ConvertTo-ShellLiteral {
    param([Parameter(Mandatory)][string] $Value)

    if ($Value.Contains("'")) {
        throw 'Shell arguments cannot contain a single quote.'
    }

    return "'$Value'"
}

function ConvertTo-SanitizedGuestOutput {
    param([Parameter(Mandatory)][string] $Value)

    $sanitized = $Value -replace '(?im)\b(authorization|password|passwd|token|secret|credential|client[_ -]?secret|access[_ -]?key|connection[_ -]?string)\b\s*[:=]\s*\S+', '$1=[REDACTED]'
    $sanitized = $sanitized -replace '(?i)([?&](?:sig|se|sp|sv|ske|sks|skv)=)[^&\s]+', '$1[REDACTED]'
    return ($sanitized -replace '(?m)^__ARC_MONITOR_EXIT_CODE=\d+\r?$', '').Trim()
}

function Invoke-VmShellScript {
    param(
        [Parameter(Mandatory)][string] $VmName,
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter()][string[]] $ScriptArguments = @()
    )

    $remotePath = "/tmp/arc-monitor-$([Guid]::NewGuid().ToString('N')).sh"
    $argumentText = ($ScriptArguments | ForEach-Object { ConvertTo-ShellLiteral $_ }) -join ' '
    $delimiter = "ARC_MONITOR_SCRIPT_$([Guid]::NewGuid().ToString('N'))"
    $wrapperPath = Join-Path ([IO.Path]::GetTempPath()) "arc-monitor-$([Guid]::NewGuid().ToString('N')).sh"
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
echo __ARC_MONITOR_EXIT_CODE=`$status
exit 0
"@

    try {
        Write-DeploymentStatus "Running guest script '$([IO.Path]::GetFileName($ScriptPath))' on VM '$VmName'. This can take several minutes."
        [IO.File]::WriteAllText($wrapperPath, $wrapperContent, [Text.UTF8Encoding]::new($false))
        $result = Invoke-AzCli -Arguments @(
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

    if ($result.Output -notmatch '(?m)^__ARC_MONITOR_EXIT_CODE=(\d+)\r?$') {
        throw "Azure VM Run Command did not return the guest exit code for '$([IO.Path]::GetFileName($ScriptPath))'."
    }
    if ([int] $Matches[1] -ne 0) {
        $guestOutput = ConvertTo-SanitizedGuestOutput -Value $result.Output
        if ([string]::IsNullOrWhiteSpace($guestOutput)) {
            $guestOutput = '[No guest output was returned.]'
        }
        throw "Guest script '$([IO.Path]::GetFileName($ScriptPath))' failed with exit code $($Matches[1]).`nGuest output:`n$guestOutput"
    }

    Write-DeploymentStatus "Guest script '$([IO.Path]::GetFileName($ScriptPath))' completed successfully."
}

function Wait-KubernetesExtension {
    param(
        [Parameter(Mandatory)][string] $ClusterName,
        [Parameter(Mandatory)][string] $ExtensionName,
        [Parameter()][int] $TimeoutMinutes = 30
    )

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    do {
        $state = (Invoke-AzCli -Arguments @(
            'k8s-extension', 'show',
            '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroupName,
            '--cluster-type', 'connectedClusters',
            '--cluster-name', $ClusterName,
            '--name', $ExtensionName,
            '--query', 'provisioningState',
            '--output', 'tsv',
            '--only-show-errors'
        )).Output
        Write-DeploymentStatus "Extension '$ExtensionName' state: $state"

        if ($state -eq 'Succeeded') {
            return
        }
        if ($state -in @('Failed', 'Canceled')) {
            throw "Extension '$ExtensionName' entered provisioning state '$state'."
        }

        Start-Sleep -Seconds 15
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for extension '$ExtensionName'. Last state: '$state'."
}

function Ensure-KubernetesExtension {
    param(
        [Parameter(Mandatory)][string] $ClusterName,
        [Parameter(Mandatory)][string] $ExtensionName,
        [Parameter(Mandatory)][string] $ExtensionType,
        [Parameter()][string] $ReleaseNamespace
    )

    $showArguments = @(
        'k8s-extension', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--cluster-type', 'connectedClusters',
        '--cluster-name', $ClusterName,
        '--name', $ExtensionName,
        '--output', 'json',
        '--only-show-errors'
    )
    $existingResult = Invoke-AzCli -Arguments $showArguments -AllowFailure

    if ($existingResult.ExitCode -eq 0) {
        $existing = $existingResult.Output | ConvertFrom-Json
        if ($existing.extensionType -ne $ExtensionType) {
            throw "Extension '$ExtensionName' exists with type '$($existing.extensionType)', expected '$ExtensionType'."
        }
    }
    else {
        $createArguments = @(
            'k8s-extension', 'create',
            '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroupName,
            '--cluster-type', 'connectedClusters',
            '--cluster-name', $ClusterName,
            '--name', $ExtensionName,
            '--extension-type', $ExtensionType,
            '--scope', 'cluster',
            '--auto-upgrade-minor-version', 'true',
            '--output', 'none',
            '--only-show-errors'
        )
        if (-not [string]::IsNullOrWhiteSpace($ReleaseNamespace)) {
            $createArguments += @('--release-namespace', $ReleaseNamespace)
        }
        Invoke-AzCli -Arguments $createArguments | Out-Null
    }

    Wait-KubernetesExtension -ClusterName $ClusterName -ExtensionName $ExtensionName
}

foreach ($path in @($infraTemplate, $monitoringTemplate, $bootstrapScript, $pipelinePreparationScript)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required deployment file not found: $path"
    }
}

Assert-Cidr -Value $AllowedSourceCidr
Write-DeploymentStatus "Starting phase 1 deployment for resource group '$ResourceGroupName' in '$Location'."

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required and was not found on PATH.'
}

$sshPublicKey = (Get-Content -LiteralPath $SshPublicKeyPath -Raw).Trim()
if ($sshPublicKey -notmatch '^ssh-(rsa|ed25519)|^ecdsa-sha2-') {
    throw 'SshPublicKeyPath must contain an OpenSSH public key.'
}
if ($sshPublicKey.Contains("`n") -or $sshPublicKey.Contains("`r")) {
    throw 'SshPublicKeyPath must contain exactly one public key.'
}

$account = ConvertFrom-AzJson -Arguments @('account', 'show')
if ($null -eq $account) {
    throw 'Azure CLI is not signed in. Run az login first.'
}

Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
Invoke-AzCli -Arguments @('account', 'show', '--subscription', $SubscriptionId, '--output', 'none') | Out-Null

$bicepCheck = Invoke-AzCli -Arguments @('bicep', 'version') -AllowFailure
if ($bicepCheck.ExitCode -ne 0) {
    Invoke-AzCli -Arguments @('bicep', 'install') | Out-Null
}

foreach ($extension in @('connectedk8s', 'k8s-extension', 'customlocation')) {
    Invoke-AzCli -Arguments @('extension', 'add', '--name', $extension, '--upgrade', '--only-show-errors') | Out-Null
}

foreach ($provider in $requiredProviders) {
    $registrationState = (Invoke-AzCli -Arguments @(
        'provider', 'show',
        '--subscription', $SubscriptionId,
        '--namespace', $provider,
        '--query', 'registrationState',
        '--output', 'tsv',
        '--only-show-errors'
    )).Output
    if ($registrationState -ne 'Registered') {
        Invoke-AzCli -Arguments @(
            'provider', 'register',
            '--subscription', $SubscriptionId,
            '--namespace', $provider,
            '--wait',
            '--output', 'none',
            '--only-show-errors'
        ) | Out-Null
    }
}

$existingGroupResult = Invoke-AzCli -Arguments @(
    'group', 'show',
    '--subscription', $SubscriptionId,
    '--name', $ResourceGroupName,
    '--output', 'json',
    '--only-show-errors'
) -AllowFailure
if ($existingGroupResult.ExitCode -eq 0) {
    $existingGroup = $existingGroupResult.Output | ConvertFrom-Json
    $workloadTagProperty = if ($null -ne $existingGroup.tags) {
        $existingGroup.tags.PSObject.Properties['workload']
    }
    else {
        $null
    }
    if ($null -eq $workloadTagProperty -or $workloadTagProperty.Value -ne $workloadTagValue) {
        throw "Resource group '$ResourceGroupName' already exists and is not marked as a standalone monitor demo. Choose a new resource group."
    }
}
else {
    Invoke-AzCli -Arguments @(
        'group', 'create',
        '--subscription', $SubscriptionId,
        '--name', $ResourceGroupName,
        '--location', $Location,
        '--tags', "workload=$workloadTagValue", 'environment=demo',
        '--output', 'none',
        '--only-show-errors'
    ) | Out-Null
}

$infraDeploymentName = "$NamePrefix-infra"
Invoke-AzCli -Arguments @(
    'deployment', 'group', 'create',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $infraDeploymentName,
    '--template-file', $infraTemplate,
    '--parameters',
    "namePrefix=$NamePrefix",
    "location=$Location",
    "allowedSourceCidr=$AllowedSourceCidr",
    "sshPublicKey=$sshPublicKey",
    "adminUsername=$AdminUsername",
    "vmSize=$VmSize",
    '--output', 'none',
    '--only-show-errors'
) | Out-Null

$infraOutputs = ConvertFrom-AzJson -Arguments @(
    'deployment', 'group', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $infraDeploymentName,
    '--query', 'properties.outputs'
)
$vmName = $infraOutputs.vmName.value
$vmPrincipalId = $infraOutputs.vmPrincipalId.value
$publicIpAddress = $infraOutputs.publicIpAddress.value
$workspaceName = $infraOutputs.workspaceName.value
$workspaceResourceId = $infraOutputs.workspaceResourceId.value
$workspaceCustomerId = $infraOutputs.workspaceCustomerId.value
$dataCollectionEndpointResourceId = $infraOutputs.dataCollectionEndpointResourceId.value
$dataCollectionEndpointLogsIngestionUrl = $infraOutputs.dataCollectionEndpointLogsIngestionUrl.value
Write-DemoConfiguration `
    -Path $configPath `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -NamePrefix $NamePrefix `
    -Endpoint $publicIpAddress
Write-DeploymentStatus "Saved local demo configuration to '$configPath'."
$clusterName = $vmName
$resourceGroupScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$arcClusterResourceId = "$resourceGroupScope/providers/Microsoft.Kubernetes/connectedClusters/$clusterName"
$onboardingRoleResourceId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$onboardingRoleDefinitionId"
$customLocationsOid = (Invoke-AzCli -Arguments @(
    'ad', 'sp', 'show',
    '--id', $customLocationsServiceAppId,
    '--query', 'id',
    '--output', 'tsv',
    '--only-show-errors'
)).Output
if ([string]::IsNullOrWhiteSpace($customLocationsOid)) {
    throw 'The Custom Locations service principal could not be resolved in the current tenant.'
}
$temporaryRoleAssignmentId = $null

try {
    $existingRoleAssignment = (Invoke-AzCli -Arguments @(
        'role', 'assignment', 'list',
        '--subscription', $SubscriptionId,
        '--assignee-object-id', $vmPrincipalId,
        '--scope', $resourceGroupScope,
        '--role', $onboardingRoleResourceId,
        '--query', '[0].id',
        '--output', 'tsv',
        '--only-show-errors'
    )).Output

    if ([string]::IsNullOrWhiteSpace($existingRoleAssignment)) {
        $temporaryRoleAssignmentId = (Invoke-AzCli -Arguments @(
            'role', 'assignment', 'create',
            '--subscription', $SubscriptionId,
            '--assignee-object-id', $vmPrincipalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', $onboardingRoleResourceId,
            '--scope', $resourceGroupScope,
            '--query', 'id',
            '--output', 'tsv',
            '--only-show-errors'
        )).Output
    }

    Invoke-VmShellScript -VmName $vmName -ScriptPath $bootstrapScript -ScriptArguments @(
        $SubscriptionId,
        $ResourceGroupName,
        $clusterName,
        $Location,
        $K3sVersion,
        $customLocationsOid
    )
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($temporaryRoleAssignmentId)) {
        $cleanup = Invoke-AzCli -Arguments @(
            'role', 'assignment', 'delete',
            '--subscription', $SubscriptionId,
            '--ids', $temporaryRoleAssignmentId,
            '--only-show-errors'
        ) -AllowFailure
        if ($cleanup.ExitCode -ne 0) {
            Write-Warning 'The temporary Azure Arc onboarding role assignment could not be removed. Remove it manually before continuing.'
            throw 'Temporary onboarding RBAC cleanup failed.'
        }
    }
}

Ensure-KubernetesExtension `
    -ClusterName $clusterName `
    -ExtensionName $certificateExtensionName `
    -ExtensionType 'microsoft.certmanagement'

Ensure-KubernetesExtension `
    -ClusterName $clusterName `
    -ExtensionName $pipelineExtensionName `
    -ExtensionType 'microsoft.monitor.pipelinecontroller' `
    -ReleaseNamespace $pipelineNamespace

$pipelineExtension = ConvertFrom-AzJson -Arguments @(
    'k8s-extension', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--cluster-type', 'connectedClusters',
    '--cluster-name', $clusterName,
    '--name', $pipelineExtensionName
)
$pipelineExtensionId = $pipelineExtension.id
$pipelineExtensionPrincipalId = $pipelineExtension.identity.principalId
if ([string]::IsNullOrWhiteSpace($pipelineExtensionPrincipalId)) {
    throw 'The Azure Monitor pipeline extension did not expose a managed identity principal ID.'
}

$customLocationName = "$NamePrefix-monitor"
$customLocationResult = Invoke-AzCli -Arguments @(
    'customlocation', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $customLocationName,
    '--output', 'json',
    '--only-show-errors'
) -AllowFailure
$customLocation = if ($customLocationResult.ExitCode -eq 0) {
    $customLocationResult.Output | ConvertFrom-Json
}
else {
    $null
}
if ($null -ne $customLocation -and $customLocation.provisioningState -in @('Failed', 'Canceled')) {
    Invoke-AzCli -Arguments @(
        'customlocation', 'delete',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $customLocationName,
        '--yes',
        '--output', 'none',
        '--only-show-errors'
    ) | Out-Null
    $customLocation = $null
}
if ($null -eq $customLocation) {
    Invoke-AzCli -Arguments @(
        'customlocation', 'create',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $customLocationName,
        '--location', $Location,
        '--host-resource-id', $arcClusterResourceId,
        '--namespace', $pipelineNamespace,
        '--cluster-extension-ids', $pipelineExtensionId,
        '--output', 'none',
        '--only-show-errors'
    ) | Out-Null
}

$customLocationDeadline = [DateTime]::UtcNow.AddMinutes(10)
do {
    $customLocationState = (Invoke-AzCli -Arguments @(
        'customlocation', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $customLocationName,
        '--query', 'provisioningState',
        '--output', 'tsv',
        '--only-show-errors'
    )).Output
    Write-DeploymentStatus "Custom location '$customLocationName' state: $customLocationState"
    if ($customLocationState -eq 'Succeeded') {
        break
    }
    if ($customLocationState -in @('Failed', 'Canceled')) {
        throw "Custom location entered provisioning state '$customLocationState'."
    }

    Start-Sleep -Seconds 10
} while ([DateTime]::UtcNow -lt $customLocationDeadline)

if ($customLocationState -ne 'Succeeded') {
    throw "Timed out waiting for the custom location. Last state: '$customLocationState'."
}

$customLocationResourceId = (Invoke-AzCli -Arguments @(
    'customlocation', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $customLocationName,
    '--query', 'id',
    '--output', 'tsv',
    '--only-show-errors'
)).Output

$tableResourceUri = "https://management.azure.com$workspaceResourceId/tables/OTelLogs_CL?api-version=2022-10-01"
$tableBody = @{
    properties = @{
        schema = @{
            name = 'OTelLogs_CL'
            columns = @(
                @{ name = 'TimeGenerated'; type = 'datetime' }
                @{ name = 'Body'; type = 'string' }
                @{ name = 'SeverityText'; type = 'string' }
            )
        }
    }
} | ConvertTo-Json -Depth 10 -Compress
$tableBodyPath = Join-Path ([IO.Path]::GetTempPath()) "arc-monitor-table-$([Guid]::NewGuid().ToString('N')).json"
try {
    [IO.File]::WriteAllText($tableBodyPath, $tableBody, [Text.UTF8Encoding]::new($false))
    Invoke-AzCli -Arguments @(
        'rest',
        '--method', 'put',
        '--uri', $tableResourceUri,
        '--headers', 'Content-Type=application/json',
        '--body', "@$tableBodyPath",
        '--output', 'none',
        '--only-show-errors'
    ) | Out-Null
}
finally {
    Remove-Item -LiteralPath $tableBodyPath -Force -ErrorAction SilentlyContinue
}

$tableDeadline = [DateTime]::UtcNow.AddMinutes(10)
do {
    $tableStateResult = Invoke-AzCli -Arguments @(
        'rest',
        '--method', 'get',
        '--uri', $tableResourceUri,
        '--query', 'properties.provisioningState',
        '--output', 'tsv',
        '--only-show-errors'
    ) -AllowFailure
    $tableState = $tableStateResult.Output
    $displayTableState = if ([string]::IsNullOrWhiteSpace($tableState)) { 'Not available yet' } else { $tableState }
    Write-DeploymentStatus "Log Analytics table 'OTelLogs_CL' state: $displayTableState"
    if ($tableStateResult.ExitCode -eq 0 -and $tableState -eq 'Succeeded') {
        break
    }
    if ($tableState -in @('Failed', 'Canceled', 'Deleting')) {
        throw "OTelLogs_CL entered provisioning state '$tableState'."
    }

    Start-Sleep -Seconds 10
} while ([DateTime]::UtcNow -lt $tableDeadline)

if ($tableState -ne 'Succeeded') {
    throw "Timed out waiting for OTelLogs_CL. Last state: '$tableState'."
}

$pipelineName = "$NamePrefix-pipeline"
$monitoringDeploymentName = "$NamePrefix-monitoring"
Invoke-VmShellScript -VmName $vmName -ScriptPath $pipelinePreparationScript -ScriptArguments @(
    $pipelineNamespace
)

Invoke-AzCli -Arguments @(
    'deployment', 'group', 'create',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $monitoringDeploymentName,
    '--template-file', $monitoringTemplate,
    '--parameters',
    "pipelineName=$pipelineName",
    "location=$Location",
    "customLocationResourceId=$customLocationResourceId",
    "workspaceResourceId=$workspaceResourceId",
    "dataCollectionEndpointResourceId=$dataCollectionEndpointResourceId",
    "dataCollectionEndpointLogsIngestionUrl=$dataCollectionEndpointLogsIngestionUrl",
    "pipelineExtensionPrincipalId=$pipelineExtensionPrincipalId",
    '--no-wait',
    '--output', 'none',
    '--only-show-errors'
) | Out-Null

Write-Host ''
Write-Host 'Phase 1 complete.'
Write-Host "In Azure Portal, open resource group '$ResourceGroupName' and wait for deployment '$monitoringDeploymentName' to show Succeeded."
Write-Host 'Then run:'
if ($PSBoundParameters.ContainsKey('ConfigFile')) {
    Write-Host "  & .\deployment-scripts\complete-deployment.ps1 -ConfigFile '$configPath'"
}
else {
    Write-Host '  & .\deployment-scripts\complete-deployment.ps1'
}