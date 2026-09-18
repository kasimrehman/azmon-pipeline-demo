# Standalone Arc-enabled Azure Monitor pipeline demo

This package deploys an isolated Ubuntu 22.04 VM running K3s `v1.33.3+k3s1`, connects it to Azure Arc, installs the Azure Monitor pipeline preview, and exposes source-restricted Syslog TCP/514 and OTLP gRPC/4317 demo endpoints.

It does not depend on the rest of ArcBox. SSH and the Kubernetes API are not exposed publicly; cluster bootstrap uses Azure VM Run Command. Traefik accepts the two external TCP protocols and uses a managed client certificate for mTLS to the in-cluster pipeline.

## What gets deployed

- A dedicated resource group, VNet, public IP, NSG, and Ubuntu 22.04 VM.
- K3s `v1.33.3+k3s1`, connected to Azure Arc with cluster-connect and custom-locations enabled.
- The `microsoft.certmanagement` and `microsoft.monitor.pipelinecontroller` Arc extensions.
- A custom location, Log Analytics workspace, data collection endpoint, data collection rule, `OTelLogs_CL` table, and Azure Monitor pipeline group.
- A Traefik TCP gateway for Syslog TCP/514 and OTLP gRPC/4317.

Only the supplied `AllowedSourceCidr` can reach ports 514 and 4317. The NSG does not expose SSH or the Kubernetes API. The deployment temporarily grants the VM identity the Arc onboarding role and removes that assignment after bootstrap.

## Prerequisites

- PowerShell 7 and Azure CLI.
- An authenticated Azure CLI session (`az login`).
- Permission to create the resources and role assignments in the target subscription. Owner, or Contributor plus Role Based Access Control Administrator, is sufficient.
- An OpenSSH public key file. The deployment does not expose SSH, but Azure requires a VM administrator credential.
- Your sender's public IPv4 address expressed as a single-host CIDR, such as `203.0.113.10/32`.
- Python 3 for the OTLP demo client. Its default Windows launcher is `py`; use `-PythonCommand python3` where appropriate.

The pipeline resource API and extensions are previews. Confirm that the selected region and subscription support them before using this package outside a disposable demo environment.

## Deploy

Copy [deploy.example.ps1](deploy.example.ps1) to the ignored `deploy.local.ps1`, replace its example subscription, fresh resource group name, and source CIDR values, then edit it:

```powershell
Copy-Item .\deploy.example.ps1 .\deploy.local.ps1
code .\deploy.local.ps1
```

Then deploy:
```powershell
.\deploy.local.ps1
```

Alternatively, invoke the deployer directly from the repository root:

```powershell

& .\deploy.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo-test' `
    -Location 'eastus2' `
    -NamePrefix 'arcmon' `
    -AllowedSourceCidr '<your-public-ip>/32' `
    -SshPublicKeyPath "$HOME\.ssh\id_ed25519.pub"
```

Find out your Cidr with 

```powershell
(Invoke-RestMethod 'https://api.ipify.org') + '/32'
```

Deployment commonly takes 20-40 minutes. The script is rerunnable and removes the temporary `Kubernetes Cluster - Azure Arc Onboarding` role assignment in a `finally` block, including failed bootstrap paths.

The deployment performs these stages in order:

1. Deploy the Azure infrastructure and configure host limits required by Arc and Azure Monitor sidecars.
2. Install K3s, connect it to Arc, and enable Custom Locations.
3. Install the certificate-management and pipeline-controller extensions.
4. Create the custom location and custom Log Analytics table.
5. Start pipeline deployment asynchronously, reconcile its certificate trust, and configure Traefik.
6. Wait for the Azure deployment and Kubernetes workloads to report ready.

The preview certificate extension can create the Azure Monitor root CA Secrets without promoting the active `*-current` aliases expected by its ClusterIssuers. The gateway script detects this state and performs an idempotent in-cluster promotion without printing certificate or key data. Remove this compatibility step when the extension implements that rotation contract directly.

## Validate

```powershell
& .\validate.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

The validation checks both ARM deployments, the workspace, Arc connectivity, the full pinned K3s version, both extensions, the custom location, DCR, pipeline group, custom table, and TCP reachability from the current machine.

## Send demo logs

Use the endpoint printed by `deploy.ps1` or `validate.ps1`:

```powershell
& .\send-syslog-demo.ps1 -Endpoint '<public-ip>'
& .\send-otlp-demo.ps1 -Endpoint '<public-ip>'
```

You can retrieve it again from Azure at any time:

```powershell
az network public-ip show `
    --subscription '<subscription-id>' `
    --resource-group 'rg-arc-monitor-demo-test' `
    --name 'arcmon-pip' `
    --query ipAddress `
    --output tsv
```

Each command prints a unique marker. Allow several minutes for ingestion, then query the deployed Log Analytics workspace.

```kusto
Syslog
| where TimeGenerated > ago(30m)
| where SyslogMessage startswith "ARC-MONITOR-DEMO-SYSLOG-"
| project TimeGenerated, Computer, Facility, SeverityLevel, ProcessName, SyslogMessage
| order by TimeGenerated desc
```

```kusto
OTelLogs_CL
| where TimeGenerated > ago(30m)
| where tostring(pack_all()) contains "ARC-MONITOR-DEMO-OTLP-"
| order by TimeGenerated desc
```

Use the complete marker printed by each sender for final proof. A successful TCP connection or OTLP export confirms transport, but the deployment is end-to-end validated only when both exact markers are returned from the standalone workspace.

## Verified deployment

Verified on September 18, 2026 in East US 2 with K3s `v1.33.3+k3s1`, Azure Monitor pipeline operator `1.7.0`, pipeline `0.99.0`, and Traefik chart `41.6.0`. The deployment, all validation checks, Syslog ingestion, and OTLP ingestion completed successfully.

This is a preview demo, not a production reference architecture. Pin and retest preview API, extension, image, and chart versions before reuse.

## Clean up

Cleanup deletes the entire standalone resource group and prompts for confirmation:

```powershell
& .\cleanup.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo'
```

For unattended cleanup, add `-Force`. The script refuses to delete a resource group that does not have the standalone demo workload tag.

Azure charges accrue for the VM, public IP, Log Analytics ingestion, and related resources until the resource group is deleted.
