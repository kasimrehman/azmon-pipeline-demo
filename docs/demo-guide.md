# 12-minute demo guide

## What this demo is about

Imagine a company with factories, hospitals, retail stores, or remote offices. Each site has older infrastructure that emits Syslog and newer applications that emit OpenTelemetry (OTLP). Sending every raw event directly across the WAN creates several problems:

- Every site needs separately managed collection software and configuration.
- Repetitive health messages consume bandwidth and paid ingestion without adding much investigative value.
- Sensitive values can leave the site before a central team has a chance to remove them.
- A WAN or Azure endpoint interruption can create a telemetry gap.
- Operators need to know whether silence means a quiet source, a broken receiver, or a failed export.

This demo represents one of those sites. Azure holds the centrally governed pipeline definition. Azure Arc carries that desired state to a collector running on Kubernetes at the site. The collector accepts both Syslog and OTLP, processes records before they leave the site, and exports the useful result to Azure Monitor through managed identity.

The point is not merely that logs arrive in Log Analytics. The demo shows that the edge pipeline can make deliberate decisions about telemetry before transmission:

1. **Unify old and new sources.** Network devices and appliances continue using Syslog while modern applications use OTLP.
2. **Reduce noise and cost.** Low-value health and debug records are removed before WAN transfer and ingestion.
3. **Minimize sensitive data.** Synthetic email and token values are redacted at the site rather than after storage.
4. **Preserve trends without every raw event.** Repeated Syslog records become one-minute counts with useful dimensions.
5. **Survive a temporary cloud-path failure.** Persistent queues retain OTLP records and Syslog summaries, then drain after connectivity returns; raw Syslog resumes after restoration.
6. **Operate centrally.** Azure manages the pipeline configuration and exposes health metrics even though collection runs outside Azure.

This is a scale-model of a distributed design: the demo deploys one single-node K3s site, while a real organization could apply the pattern to many Arc-enabled locations. Its public raw-protocol endpoints and local `hostPath` storage are demonstration choices, not a production reference architecture.

## Real-world scenario map

| Situation | Problem shown | What to demonstrate | Operational value |
| --- | --- | --- | --- |
| Hybrid data center modernization | Syslog appliances and OTLP applications coexist for years | Both receivers process one continuous, correlated run | Modernize telemetry without a flag-day source migration |
| Retail branch or factory | WAN links and central ingestion are costly | Filtering and one-minute aggregation happen before export | Send fewer low-value records while retaining volume trends |
| Hospital or regulated site | Raw messages may contain identifiers or credentials | Fixed synthetic values become redaction markers before arrival | Reduce data exposure and support data-minimization controls |
| Remote office, mine, or vessel | Connectivity to Azure can be intermittent | Block the DCE path, keep sending, restore it, and query recovered sequences | Avoid an immediate telemetry gap during a short outage |
| Central operations team | Distributed collectors drift and are difficult to troubleshoot | Show Arc reconciliation, declarative configuration, and pipeline metrics | Govern and observe edge collection from Azure |

The audience should leave understanding the boundary: source systems send locally, the pipeline decides what is worth transmitting, and Azure Monitor remains the central analytics and operations destination.

This guide assumes the operator has completed the [demo setup and readiness check](demo-setup.md). The showcase includes continuous Syslog and OTLP traffic, edge filtering and redaction, one-minute aggregation, persistent buffering for OTLP and summaries, and built-in pipeline health metrics.

## Existing deployment or new deployment?

You do not need to start over when the repository's base infrastructure is already deployed. Do not rerun `deploy.ps1` or `complete-deployment.ps1` merely to add the showcase. Run the additive setup against the existing resource group and prefix, then run readiness:

```powershell
& .\setup-demo.ps1 `
   -SubscriptionId '<subscription-id>' `
   -ResourceGroupName '<existing-resource-group>' `
   -NamePrefix '<existing-prefix>'

& .\test-demo-readiness.ps1 `
   -SubscriptionId '<subscription-id>' `
   -ResourceGroupName '<existing-resource-group>' `
   -NamePrefix '<existing-prefix>'
```

Only use the base deployment steps in the README when the VM, Arc-enabled cluster, workspace, DCE, pipeline group, and gateway do not already exist.

## Presenter preparation

Complete this checklist before the audience joins.

1. Confirm the base environment exists and its K3s VM is running, or deploy it by following the [README](../README.md) when starting with an empty resource group. Starting a deallocated VM resumes the existing environment; it does not require redeployment.
2. Install the additive showcase by following [demo setup and operations](demo-setup.md). Re-run setup after pulling changes to its storage preparation.
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
RawSyslog_CL
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

**Show:** Query the `RawSyslog_CL` and `OTelLogs_CL` tables using the active run ID or exact markers.

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

**Say:** Persistent buffering protects OTLP records and Syslog summaries during a temporary cloud-path interruption and drains them after recovery. The raw Syslog branch is non-persistent and demonstrates resumed flow after restoration.

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
