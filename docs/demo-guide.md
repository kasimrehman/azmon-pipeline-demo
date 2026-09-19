# 12-minute demo guide

This runbook presents the repository as an edge telemetry control plane: Azure centrally defines and manages a pipeline running on Arc-enabled Kubernetes, while Syslog and OTLP data are processed close to their sources and exported to Azure Monitor.

This guide assumes the operator has completed the [demo setup and readiness check](demo-setup.md). The showcase includes continuous Syslog and OTLP traffic, edge filtering and redaction, one-minute aggregation, persistent buffering, and built-in pipeline health metrics.

## Presenter preparation

Complete this checklist before the audience joins.

1. Deploy and complete the environment by following the [README](../README.md).
2. Install the showcase by following [demo setup and operations](demo-setup.md).
3. Run the full readiness check:

   ```powershell
   & .\test-demo-readiness.ps1 `
       -SubscriptionId '<subscription-id>' `
       -ResourceGroupName 'rg-arc-monitor-demo' `
       -NamePrefix 'arcmon'
   ```

4. Retrieve the public endpoint:

   ```powershell
   $endpoint = az network public-ip show `
       --subscription '<subscription-id>' `
       --resource-group 'rg-arc-monitor-demo' `
       --name 'arcmon-pip' `
       --query ipAddress `
       --output tsv
   ```

5. Choose a fresh run ID and stage the presentation command:

   ```powershell
   $runId = 'DEMO-20260919-01'
   & .\run-demo.ps1 `
       -Endpoint $endpoint `
       -DurationMinutes 10 `
       -EventsPerSecond 5 `
       -RunId $runId
   ```

6. Verify the readiness script's `PREFLIGHT-...` run in Log Analytics.
7. Open and arrange these views before presenting:
   - This guide and the architecture diagram.
   - The Azure resource group overview.
   - The Arc-enabled Kubernetes resource and its Extensions page.
   - The Azure Monitor pipeline group configuration.
   - Log Analytics Logs with saved Syslog and OTLP queries.
   - The pipeline group **Metrics** blade.
   - `demo/showcase.bicep` at the pipeline processors and service pipelines.
8. Start the bounded generator one or two minutes before the live query segment so data is already arriving.
9. Run `test-demo-recovery.ps1` on the same deployed version. Keep the restore command ready in a separate terminal during the presentation.
10. Use the staged run ID in every query and chart.

## Saved queries

Replace the run ID with the value printed by the generator.

```kusto
let RunId = "DEMO-20260919-01";
Syslog
| where TimeGenerated > ago(30m)
| where SyslogMessage contains RunId
| project TimeGenerated, Computer, Facility, SeverityLevel, ProcessName, SyslogMessage
| order by TimeGenerated desc
```

```kusto
let RunId = "DEMO-20260919-01";
OTelLogs_CL
| where TimeGenerated > ago(30m)
| where DemoRunId == RunId
| project TimeGenerated, SequenceNumber, SeverityText, EventClass, ServiceName, Site, TraceId, DurationMs, Body
| order by TimeGenerated desc
```

```kusto
let RunId = "DEMO-20260919-01";
OTelLogs_CL
| where TimeGenerated > ago(30m) and DemoRunId == RunId
| summarize Retained=count(), HealthRecords=countif(EventClass == "health"), UnredactedValues=countif(Body contains "demo.user@example.com" or Body contains "demo-token-123"), RedactedValues=countif(Body contains "[REDACTED_")
```

```kusto
let RunId = "DEMO-20260919-01";
EdgeLogSummary_CL
| where TimeGenerated > ago(30m)
| where DemoRunId == RunId
| summarize Events=sum(EventCount) by bin(TimeGenerated, 1m), Site, SeverityLevel
| order by TimeGenerated asc
```

The summary branch counts the pre-filter Syslog stream, so dropped health details still contribute to the rollup without being stored as raw records. The batch processor can also emit more than one summary row for the same clock minute, so the query intentionally re-aggregates rows with `sum(EventCount)`.

## 12-minute run of show

### 0:00-1:00 - Set the premise

**Show:** The architecture-at-a-glance diagram.

**Say:** This is an edge telemetry control plane. Azure owns the desired configuration while the collector runs next to data sources on Arc-enabled Kubernetes.

**Why:** It frames the value as centralized governance and edge processing rather than another log forwarder.

### 1:00-2:15 - Connect Azure control plane to the edge

**Show:** The resource group, Arc-enabled cluster, custom location, two extensions, and pipeline group.

**Say:** The custom location places the Azure resource on K3s, and the extension controller reconciles it into a running collector. No inbound SSH or Kubernetes API access is required.

**Why:** It demonstrates Azure-managed lifecycle and policy boundaries for infrastructure outside a managed AKS cluster.

### 2:15-3:15 - Start mixed continuous traffic

**Show:** Start the bounded generator and point out its run ID, event mix, rate, and sent counters.

**Say:** One centrally managed pipeline accepts legacy Syslog and modern OTLP at the same edge location.

**Why:** Simultaneous, visible traffic makes later filtering, aggregation, and recovery evidence credible.

### 3:15-4:45 - Prove both paths end to end

**Show:** Query the `Syslog` and `OTelLogs_CL` tables using the active run ID or exact markers.

**Say:** Transport success is not the proof. The proof is that the same identifiers sent at the edge appear in the intended Azure Monitor tables.

**Why:** This verifies the complete receiver, processor, exporter, DCE, DCR, and workspace path.

### 4:45-6:15 - Show edge filtering and redaction

**Show:** Generator sent counts, pipeline received/exported counts, and examples where low-value records are absent and synthetic sensitive values are redacted.

**Say:** The pipeline removes or changes data before it consumes WAN bandwidth and Log Analytics ingestion.

**Why:** Data-volume control and privacy are stronger differentiators than simple forwarding.

### 6:15-7:30 - Show edge aggregation

**Show:** Repeated raw events at the generator and one-minute rollups in `EdgeLogSummary_CL`.

**Say:** High-volume repeated events can become operational summaries close to their source while preserving useful dimensions. Health details are removed from the raw stream but retained as counts in the summary stream.

**Why:** Aggregation makes ingestion reduction visible and provides a clear before-and-after comparison.

### 7:30-9:30 - Disconnect and recover

**Show:** Apply the rehearsed egress fault, keep numbered events flowing, observe failed-export or retry signals, restore connectivity, and query for the recovered sequence.

```powershell
& .\set-demo-outage.ps1 -Action Block -SubscriptionId '<subscription-id>' -ResourceGroupName 'rg-arc-monitor-demo' -NamePrefix 'arcmon'
& .\set-demo-outage.ps1 -Action Restore -SubscriptionId '<subscription-id>' -ResourceGroupName 'rg-arc-monitor-demo' -NamePrefix 'arcmon'
```

**Say:** Persistent buffering protects telemetry during a temporary cloud-path interruption and drains it after recovery.

**Why:** This demonstrates edge resilience, not only steady-state collection.

### 9:30-10:45 - Operate the pipeline

**Show:** The pipeline group's Azure Monitor Metrics blade with sent records, failed records, CPU, memory, and uptime.

**Say:** The telemetry pipeline is itself observable, so operators can distinguish source silence, receiver pressure, and export failure.

**Why:** Operational visibility turns the demo from a configuration exercise into a manageable service.

### 10:45-12:00 - Close on security and governance

**Show:** The source-restricted NSG, Traefik-to-pipeline mTLS resources, managed-identity DCR role assignment, and the declarative pipeline in `demo/showcase.bicep`.

**Say:** Public clients use raw protocol transport in this demo. The in-cluster Traefik-to-pipeline hop uses mTLS, and the pipeline exports through managed identity. The entire desired state is repeatable from source control.

**Why:** This closes with an accurate trust-boundary story and the central-management value proposition.

## Failure plan

- If new records have not arrived, show the last successful rehearsal run and state the expected ingestion delay.
- If OTLP fails, continue with Syslog and identify OTLP as the preview path.
- If the generator fails, use the two one-shot sender scripts.
- If a metric chart is empty, show the successful readiness output and direct Log Analytics queries.
- If the outage control does not apply cleanly, skip the outage. Never create an untested live firewall change.
- If recovery is incomplete, restore connectivity first, stop the generator, and avoid claiming lossless buffering.

## After the demo

1. Stop the generator and verify that its final counts were printed.
2. Confirm that any simulated egress fault was removed.
3. Save the run ID and final queries if evidence is needed.
4. Leave the environment running only when another demonstration is scheduled; Azure charges continue until cleanup.
5. Delete the standalone resource group with `cleanup.ps1` when it is no longer needed.

## Reference documentation

- [Azure Monitor pipeline overview](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-overview)
- [Pipeline transformations](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-transformations)
- [Configure a pipeline with CLI and ARM](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-configure-cli)
- [Performance and sizing](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-sizing)
- [TLS configuration](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-tls)
- [Troubleshooting and pipeline metrics](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-troubleshoot)
- [Pipeline extension releases](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-extension-versions)
