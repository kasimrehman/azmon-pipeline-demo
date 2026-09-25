# Demo setup and operations

This page is for the operator preparing the full Azure Monitor pipeline showcase. The customer-facing Syslog, CEF, and OTLP experiments are in the [scenario guide](../README.md).

The showcase is an additive update to the base deployment. It keeps the VM, network, Arc cluster, extensions, custom location, gateway, workspace, and DCE. It updates the existing DCR and pipeline group, continues to use the built-in `Syslog` table, adds CEF ingestion to the built-in `CommonSecurityLog` table, expands `OTelLogs_CL`, and adds `EdgeLogSummary_CL`.

## Prerequisites

1. Complete both deployment phases in [basic setup](basic-setup.md).
2. Use a workstation whose public IPv4 address is covered by the deployment's `AllowedSourceCidr`.
3. Install Azure CLI, PowerShell, and Python 3, then authenticate with `az login`.
4. Confirm the operator can update the resource group, DCR, pipeline group, Log Analytics tables, and invoke VM Run Command.
5. Enable Microsoft Sentinel on the workspace and confirm that
   `CommonSecurityLog | take 0` resolves. The setup stops with a clear error
   rather than deploying a CEF data flow when the built-in table is absent.
6. Ensure the VM hosting K3s is running. Starting a previously deallocated VM does not redeploy or replace the environment:

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
& .\deployment-scripts\setup-demo.ps1
```

The setup performs these operations:

- Creates an 8 GiB static persistent volume and reserves up to 2 GiB for each of two exporter queues, leaving filesystem headroom.
- Routes normalized, filtered, and redacted records to the built-in `Syslog` table.
- Adds a separate TCP/515 receiver that parses CEF and writes it unchanged to
  the built-in `CommonSecurityLog` table.
- Expands the OTLP table with run, sequence, service, environment, site, trace, duration, and event-class fields.
- Creates `EdgeLogSummary_CL`.
- Adds Syslog and OTLP filtering and redaction processors.
- Adds a one-minute Syslog aggregation branch before raw-event filtering, preserving volume counts without storing every health record.
- Enables persistent exporter queues for OTLP and the Syslog summary branch. The individual-record Syslog exporter remains non-persistent.
- Adds the source-restricted TCP/515 NSG rule and updates the existing Traefik
  release with the CEF route. These are incremental updates and do not recreate
  the VM, cluster, workspace, DCE, or public IP.

The volume uses `hostPath` and advertises `ReadWriteMany`. K3s runs the pipeline collector in a user namespace, so setup makes the dedicated synthetic buffer directory mode `0777`; container root otherwise cannot create queue segments on the host path. This permissive local path is suitable only for this isolated single-node demonstration and must not hold secrets or unrelated data. Use secured, resilient shared storage that genuinely supports `ReadWriteMany` for a production or multi-node design.

The pipeline controller may take several minutes to reconcile the update. Re-running the original `monitoring.bicep` deployment restores the base straight-through configuration, so run `setup-demo.ps1` again afterward if that occurs.

## Prove readiness

Run the full preflight:

```powershell
& .\validation-scripts\test-demo-readiness.ps1 -Protocol Both
```

The preflight verifies the Azure deployment, pipeline state, table schemas, built-in pipeline metrics, bound persistent volume, inactive outage control, ready receiver endpoints, public TCP reachability, and an end-to-end test run. The ingestion check can take several minutes because it waits for Log Analytics and the one-minute aggregation window.

Set `-Protocol Syslog` or `-Protocol OTLP` to validate only that presentation path. The default is `Both`. Protocol selection affects the local checks and generated traffic only; it does not redeploy or modify the Azure pipeline.

Set `-Protocol CEF` to validate only CEF ingestion, or `-Protocol All` to
validate Syslog, OTLP, and CEF together. `Both` retains its original meaning of
Syslog plus OTLP.

If the VM is stopped or deallocated, the Azure resources and schemas can still pass while the site runtime and receiver ports are unavailable. The preflight reports the VM power state, prints the exact `az vm start` command, and skips the dependent cluster and TCP checks until the VM is running.

If the pipeline service has no ready endpoints, the check now prints pod status, collector restart details, and the latest collector startup error. A durable-buffer `Permission denied` error means the demo host path was prepared by an older script version; re-run `setup-demo.ps1` to repair its mode and reconcile the existing deployment.

Use `-SkipIngestionTest` only for a quick structural check. Do not treat that reduced check as proof that the demo data path works.

The readiness check proves steady-state ingestion, filtering, redaction, and aggregation. It does not simulate an outage or prove buffered recovery.

Both the base deployment and the showcase route `Microsoft-Syslog-FullyFormed` to the built-in `Syslog` table. The showcase adds schema-preserving filtering and redaction before export and retains `EdgeLogSummary_CL` for aggregate rows. Re-running `setup-demo.ps1` reapplies this configuration without recreating the base infrastructure.

## Rehearse persistent recovery

Run this once after setup and again after changing the pipeline, network, or storage configuration:

```powershell
& .\validation-scripts\test-demo-recovery.ps1 -Protocol Both
```

The rehearsal sends a unique continuous run, interrupts the VM's route to the DCE for 60 seconds, restores it in a `finally` block, and waits for records generated before, during, and after the interruption. A pass proves that the persistent OTLP and Syslog summary queues drained without losing their expected records and that non-persistent individual Syslog ingestion resumed after restoration. It does not claim lossless individual Syslog delivery or guarantee lossless delivery for other outage conditions.

Use `-Protocol Syslog` to rehearse summary-queue recovery and individual Syslog resumption, or `-Protocol OTLP` to rehearse OTLP queue recovery. These modes use the existing combined pipeline and require no deployment.

## Start presentation traffic

Start a bounded run. The endpoint is loaded from `demo.config.psd1`:

```powershell
& .\generator-scripts\run-demo.ps1 `
    -DurationMinutes 2 `
    -EventsPerSecond 5 `
    -RunId 'DEMO-20260919-01' `
    -Protocol Both
```

Choose `-Protocol Syslog`, `-Protocol OTLP`, or `-Protocol Both` without redeploying the pipeline. `Both` is the default. The runner displays the actual first source message and explains which fields remain fixed or vary in later messages; pass `-ShowPayloadSample:$false` to suppress it. An OTLP-enabled run creates a cached Python environment under the current user's local application-data directory and later runs reuse it. Syslog-only mode uses Python's standard library and does not install the OpenTelemetry packages. The rate is per enabled protocol, so `5` in `Both` mode sends five Syslog records and five OTLP records per second.

Generated traffic is synthetic. Most records are low-value health events that the pipeline drops. Retained records contain fixed demonstration email and token values that the pipeline replaces before export.

## Run the resilience segment

Open a separate operator terminal for the restore command. Check the current state first:

```powershell
& .\operations-scripts\set-demo-outage.ps1 `
    -Action Status
```

While `run-demo.ps1` is sending records, block only the DCE addresses resolved by the VM:

```powershell
& .\operations-scripts\set-demo-outage.ps1 `
    -Action Block
```

Restore connectivity after one to two minutes:

```powershell
& .\operations-scripts\set-demo-outage.ps1 `
    -Action Restore
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
& .\operations-scripts\set-demo-outage.ps1 `
    -Action Restore
```

Run the readiness script again before the next presentation. When the environment is no longer needed, delete the resource group with `cleanup.ps1` as described in the README.
