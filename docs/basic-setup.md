# Standalone Arc-enabled Azure Monitor pipeline demo

This package deploys an isolated Ubuntu 22.04 VM running K3s `v1.33.3+k3s1`, connects it to Azure Arc, installs an Azure Monitor pipeline, and exposes source-restricted Syslog TCP/514 and OTLP gRPC/4317 demo endpoints. The Syslog pipeline scenario is generally available; OTLP log collection remains in preview.

It does not depend on the rest of ArcBox. SSH and the Kubernetes API are not exposed publicly; cluster bootstrap uses Azure VM Run Command. Clients send raw Syslog TCP or OTLP gRPC to Traefik. Traefik then uses a managed client certificate and mTLS for the separate in-cluster connection to the pipeline.

## What gets deployed

- A dedicated resource group, VNet, public IP, NSG, and Ubuntu 22.04 VM.
- K3s `v1.33.3+k3s1`, connected to Azure Arc with cluster-connect and custom-locations enabled.
- The `microsoft.certmanagement` and `microsoft.monitor.pipelinecontroller` Arc extensions.
- A custom location, Log Analytics workspace, data collection endpoint, data collection rule, `OTelLogs_CL` table, and Azure Monitor pipeline group.
- A Traefik TCP gateway for Syslog TCP/514 and OTLP gRPC/4317.

Only the supplied `AllowedSourceCidr` can reach ports 514 and 4317. The NSG does not expose SSH or the Kubernetes API. The deployment temporarily grants the VM identity the Arc onboarding role and removes that assignment after bootstrap.

For component relationships, deployment sequencing, identity and certificate trust, and end-to-end telemetry flows, see the [detailed architecture](architecture.md). Use [demo setup and operations](demo-setup.md) to install and verify the showcase, then follow the [12-minute demo guide](../README.md) during the presentation.

## Prerequisites

- PowerShell 7 and Azure CLI.
- An authenticated Azure CLI session (`az login`).
- Permission to create the resources and role assignments in the target subscription. Owner, or Contributor plus Role Based Access Control Administrator, is sufficient.
- An OpenSSH public key file. The deployment does not expose SSH, but Azure requires a VM administrator credential.
- Your sender's public IPv4 address expressed as a single-host CIDR, such as `203.0.113.10/32`.
- Python 3 for the OTLP demo client. Its default Windows launcher is `py`; use `-PythonCommand python3` where appropriate.

The Syslog pipeline scenario is generally available, while the OTLP receiver and OTLP log path used by this demo are preview features. Confirm that the selected region and subscription support the required features before using this package outside a disposable demo environment.

## Deploy

Copy [deploy.example.ps1](../deploy.example.ps1) to the ignored `deploy.local.ps1`, replace its example subscription, fresh resource group name, and source CIDR values, then edit it:

```powershell
Copy-Item .\deploy.example.ps1 .\deploy.local.ps1
code .\deploy.local.ps1
```

Then run phase 1:

```powershell
.\deploy.local.ps1
```

Alternatively, invoke phase 1 directly from this directory:

```powershell

& .\deploy.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -Location 'eastus2' `
    -NamePrefix 'arcmon' `
    -AllowedSourceCidr '<your-public-ip>/32' `
    -SshPublicKeyPath "$HOME\.ssh\id_ed25519.pub"
```

The Cidr is needed for you to be able to send monitoring data to the public endpoint from your workstation (simulating an edge device). Find out your Cidr with

```powershell
(Invoke-RestMethod 'https://api.ipify.org') + '/32'
```

Phase 1 commonly takes 20-40 minutes. It removes the temporary `Kubernetes Cluster - Azure Arc Onboarding` role assignment in a `finally` block, including failed bootstrap paths. At the end, it starts the `<prefix>-monitoring` resource-group deployment and returns without waiting for the long-running pipeline resource deployment.

In Azure Portal, open the resource group, select **Deployments**, and wait for `<prefix>-monitoring` to show **Succeeded**. Then run phase 2:

```powershell
& .\complete-deployment.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

Phase 2 does not poll Azure. It verifies that the monitoring deployment already succeeded, configures the mTLS Traefik gateway, and prints the Syslog and OTLP endpoints. It is safe to run again if gateway configuration needs to be retried.

If VM Run Command reports `error: no matching resources found` during K3s bootstrap, the Kubernetes API became available before K3s registered its Node object. `bootstrap-k3s.sh` handles this startup race by waiting for a Node object to exist before waiting for its `Ready` condition. Do not replace the two-phase check with only `kubectl wait --for=condition=Ready node --all`: `kubectl wait --all` does not wait for matching resources to be created.

Arc feature enablement can also return `UPGRADE FAILED: context deadline exceeded` when a base Arc connection is immediately followed by an agent upgrade; in the observed failure, the `kube-aad-proxy` certificate was never issued. The bootstrap requests Custom Locations during initial Arc onboarding, retries feature enablement only for a pre-existing connection, and requires every Arc deployment to become available before continuing.

The deployment performs these stages in order:

1. Deploy the Azure infrastructure and configure host limits required by Arc and Azure Monitor sidecars.
2. Install K3s, connect it to Arc, and enable Custom Locations.
3. Install the certificate-management and pipeline-controller extensions.
4. Create the custom location and custom Log Analytics table.
5. Prepare pipeline certificate trust, start the monitoring deployment asynchronously, and end phase 1.
6. After the monitoring deployment succeeds, run phase 2 to configure Traefik and expose the endpoints.

The certificate-management extension can create the Azure Monitor root CA Secrets without promoting the active `*-current` aliases expected by its ClusterIssuers. Phase 1 detects this state and performs an idempotent in-cluster promotion without printing certificate or key data. Remove this compatibility step when the extension implements that rotation contract directly.

## Validate

Run validation after phase 2:

```powershell
& .\validate.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

The validation checks both ARM deployments, the workspace, Arc connectivity, the full pinned K3s version, both extensions, the custom location, DCR, pipeline group, custom table, and TCP reachability from the current machine.

## Install the full showcase

The base deployment is intentionally small. Add continuous traffic, filtering, redaction, aggregation, persistent buffering, and full readiness checks without changing the base scripts:

```powershell
& .\setup-demo.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'

& .\test-demo-readiness.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

The readiness check sends a short run and waits for filtered, redacted, and aggregated records. See [demo setup and operations](demo-setup.md) for the persistent-storage limitation and rehearsed outage controls.

Before presenting the resilience segment, run `test-demo-recovery.ps1` as documented in the operator guide. The normal readiness check does not simulate an outage.

## Send demo logs

Use the endpoint printed by `complete-deployment.ps1` or `validate.ps1`:

```powershell
& .\send-syslog-demo.ps1 -Endpoint '<public-ip>'
& .\send-otlp-demo.ps1 -Endpoint '<public-ip>'
```

You can retrieve the public IP from Azure at any time:

```powershell
az network public-ip show `
    --subscription '<subscription-id>' `
    --resource-group 'rg-arc-monitor-demo' `
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

`ago(30m)` evaluates to the timestamp at the start of the 30-minute window. `TimeGenerated > ago(30m)` therefore keeps newer records from that window; `<` would select records older than 30 minutes.

Use the complete marker printed by each sender for final proof. A successful TCP connection or OTLP export confirms transport, but the deployment is end-to-end validated only when both exact markers are returned from the standalone workspace.

## Verified deployment

Verified on September 18, 2026 in East US 2 with K3s `v1.33.3+k3s1`, Azure Monitor pipeline operator `1.7.0`, pipeline `0.99.0`, and Traefik chart `41.6.0`. The deployment, all validation checks, Syslog ingestion, and OTLP ingestion completed successfully.

This is a demonstration, not a production reference architecture. The OTLP path remains in preview. Pin and retest the resource API, extension, image, and chart versions before reuse.

## Clean up

Cleanup deletes the entire standalone resource group and prompts for confirmation:

```powershell
& .\cleanup.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo'
```

For unattended cleanup, add `-Force`. The script refuses to delete a resource group that does not have the standalone demo workload tag.

Azure charges accrue for the VM, public IP, Log Analytics ingestion, and related resources until the resource group is deleted.
