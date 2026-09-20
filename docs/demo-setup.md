# Demo setup and operations

This page is for the operator preparing the full Azure Monitor pipeline showcase. The customer-facing presentation is in the [12-minute demo guide](../README.md).

The showcase is an additive update to the base deployment. It keeps the VM, network, Arc cluster, extensions, custom location, gateway, workspace, DCE, and public endpoints. It updates the existing DCR and pipeline group, expands `OTelLogs_CL`, and adds `RawSyslog_CL` and `EdgeLogSummary_CL`.

## Prerequisites

1. Complete both deployment phases in [basic setup](basic-setup.md).
2. Use a workstation whose public IPv4 address is covered by the deployment's `AllowedSourceCidr`.
3. Install Azure CLI, PowerShell, and Python 3, then authenticate with `az login`.
4. Confirm the operator can update the resource group, DCR, pipeline group, Log Analytics tables, and invoke VM Run Command.
5. Ensure the VM hosting K3s is running. Starting a previously deallocated VM does not redeploy or replace the environment:

   ```powershell
   az vm start `
       --subscription '<subscription-id>' `
       --resource-group 'rg-arc-monitor-demo' `
       --name 'arcmon-k3s'
   ```

   Allow a few minutes after startup for K3s, Arc extensions, the pipeline pod, and its receiver endpoints to become ready.

## Install the showcase

Run the one-time setup from the repository root:

```powershell
& .\setup-demo.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

The setup performs these operations:

- Creates an 8 GiB static persistent volume and reserves up to 2 GiB for each of two exporter queues, leaving filesystem headroom.
- Creates `RawSyslog_CL` for normalized raw Syslog records retained by the showcase.
- Expands the OTLP table with run, sequence, service, environment, site, trace, duration, and event-class fields.
- Creates `EdgeLogSummary_CL`.
- Adds Syslog and OTLP filtering and redaction processors.
- Adds a one-minute Syslog aggregation branch before raw-event filtering, preserving volume counts without storing every health record.
- Enables persistent exporter queues for OTLP and the Syslog summary branch. Raw Syslog remains non-persistent because extension `1.7.0` stalls that exporter when persistence is enabled.

The volume uses `hostPath` and advertises `ReadWriteMany`. K3s runs the pipeline collector in a user namespace, so setup makes the dedicated synthetic buffer directory mode `0777`; container root otherwise cannot create queue segments on the host path. This permissive local path is suitable only for this isolated single-node demonstration and must not hold secrets or unrelated data. Use secured, resilient shared storage that genuinely supports `ReadWriteMany` for a production or multi-node design.

The pipeline controller may take several minutes to reconcile the update. Re-running the original `monitoring.bicep` deployment restores the base straight-through configuration, so run `setup-demo.ps1` again afterward if that occurs.

## Prove readiness

Run the full preflight:

```powershell
& .\test-demo-readiness.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

The preflight verifies the Azure deployment, pipeline state, table schemas, built-in pipeline metrics, bound persistent volume, inactive outage control, ready receiver endpoints, public TCP reachability, and an end-to-end test run. The ingestion check can take several minutes because it waits for Log Analytics and the one-minute aggregation window.

If the VM is stopped or deallocated, the Azure resources and schemas can still pass while the site runtime and receiver ports are unavailable. The preflight reports the VM power state, prints the exact `az vm start` command, and skips the dependent cluster and TCP checks until the VM is running.

If the pipeline service has no ready endpoints, the check now prints pod status, collector restart details, and the latest collector startup error. A durable-buffer `Permission denied` error means the demo host path was prepared by an older script version; re-run `setup-demo.ps1` to repair its mode and reconcile the existing deployment.

Use `-SkipIngestionTest` only for a quick structural check. Do not treat that reduced check as proof that the demo data path works.

The readiness check proves steady-state ingestion, filtering, redaction, and aggregation. It does not simulate an outage or prove buffered recovery.

The base deployment sends normalized records through `Microsoft-Syslog-FullyFormed` to the standard `Syslog` table. The additive showcase instead uses the custom `RawSyslog_CL` stream and table. This keeps the demo's filtered and redacted raw branch on the same custom logs-ingestion contract as its OTLP and summary branches and avoids a stalled standard-table exporter observed with pipeline extension `1.7.0`. Re-running `setup-demo.ps1` is the recovery procedure: it ensures the custom table exists and reapplies the custom raw stream without recreating the base infrastructure.

## Rehearse persistent recovery

Run this once after setup and again after changing the pipeline, network, or storage configuration:

```powershell
& .\test-demo-recovery.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

The rehearsal sends a unique continuous run, interrupts the VM's route to the DCE for 60 seconds, restores it in a `finally` block, and waits for records generated before, during, and after the interruption. A pass proves that the persistent OTLP and Syslog summary queues drained without losing their expected records and that non-persistent raw Syslog resumed after restoration. It does not claim lossless raw Syslog delivery or guarantee lossless delivery for other outage conditions.

## Start presentation traffic

Retrieve the endpoint and start a bounded run:

```powershell
$endpoint = az network public-ip show `
    --subscription '<subscription-id>' `
    --resource-group 'rg-arc-monitor-demo' `
    --name 'arcmon-pip' `
    --query ipAddress `
    --output tsv

& .\run-demo.ps1 `
    -Endpoint $endpoint `
    -DurationMinutes 10 `
    -EventsPerSecond 5 `
    -RunId 'DEMO-20260919-01'
```

The first run creates a cached Python environment under the current user's local application-data directory. Later runs reuse it. The rate is per protocol, so `5` sends five Syslog records and five OTLP records per second.

Generated traffic is synthetic. Most records are low-value health events that the pipeline drops. Retained records contain fixed demonstration email and token values that the pipeline replaces before export.

## Run the resilience segment

Open a separate operator terminal for the restore command. Check the current state first:

```powershell
& .\set-demo-outage.ps1 `
    -Action Status `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

While `run-demo.ps1` is sending records, block only the DCE addresses resolved by the VM:

```powershell
& .\set-demo-outage.ps1 `
    -Action Block `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

Restore connectivity after one to two minutes:

```powershell
& .\set-demo-outage.ps1 `
    -Action Restore `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

The block action installs host routes for the DCE's currently resolved IPv4 addresses. It does not intentionally block Arc or inbound receiver traffic, but another destination sharing one of those addresses can also be affected. DNS addresses can change and bypass the block, so use `test-demo-recovery.ps1` on the deployed environment and always verify `Status` returns `INACTIVE` afterward.

## Open the operator views

Before the audience joins, open:

- The architecture diagram.
- The resource group overview.
- The Arc-enabled Kubernetes Extensions page.
- The pipeline group configuration.
- Log Analytics Logs with the queries from the demo guide.
- The pipeline group's **Metrics** blade with CPU, memory, uptime, sent records, and failed records selected.

A custom workbook is not required. The pipeline resource exposes the health metrics used by this demo directly in Azure Monitor.

## Recovery and cleanup

If anything interrupts the demo, restore the DCE path first:

```powershell
& .\set-demo-outage.ps1 `
    -Action Restore `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

Run the readiness script again before the next presentation. When the environment is no longer needed, delete the resource group with `cleanup.ps1` as described in the README.
