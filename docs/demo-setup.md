# Demo setup and operations

This page is for the operator preparing the full Azure Monitor pipeline showcase. The customer-facing presentation is in the [12-minute demo guide](demo-guide.md).

The showcase is an additive update to the base deployment. It keeps the VM, network, Arc cluster, extensions, custom location, gateway, workspace, DCE, and public endpoints. It updates the existing DCR and pipeline group, expands `OTelLogs_CL`, and adds `EdgeLogSummary_CL`.

## Prerequisites

1. Complete both deployment phases in the [README](../README.md).
2. Use a workstation whose public IPv4 address is covered by the deployment's `AllowedSourceCidr`.
3. Install Azure CLI, PowerShell, and Python 3, then authenticate with `az login`.
4. Confirm the operator can update the resource group, DCR, pipeline group, Log Analytics tables, and invoke VM Run Command.

## Install the showcase

Run the one-time setup from the repository root:

```powershell
& .\setup-demo.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

The setup performs these operations:

- Creates an 8 GiB static persistent volume and reserves up to 2 GiB for each of three exporter queues, leaving filesystem headroom.
- Expands the OTLP table with run, sequence, service, environment, site, trace, duration, and event-class fields.
- Creates `EdgeLogSummary_CL`.
- Adds Syslog and OTLP filtering and redaction processors.
- Adds a one-minute Syslog aggregation branch before raw-event filtering, preserving volume counts without storing every health record.
- Enables persistent exporter queues.

The volume uses `hostPath` and advertises `ReadWriteMany`. This is suitable only for this single-node demonstration. Use resilient shared storage that genuinely supports `ReadWriteMany` for a production or multi-node design.

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

Use `-SkipIngestionTest` only for a quick structural check. Do not treat that reduced check as proof that the demo data path works.

The readiness check proves steady-state ingestion, filtering, redaction, and aggregation. It does not simulate an outage or prove buffered recovery.

## Rehearse persistent recovery

Run this once after setup and again after changing the pipeline, network, or storage configuration:

```powershell
& .\test-demo-recovery.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'rg-arc-monitor-demo' `
    -NamePrefix 'arcmon'
```

The rehearsal sends a unique continuous run, interrupts the VM's route to the DCE for 60 seconds, restores it in a `finally` block, and waits for Syslog and OTLP records generated before, during, and after the interruption. A pass is evidence that the configured exporter queues drained after that rehearsed outage; it is not a general guarantee of lossless delivery.

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
