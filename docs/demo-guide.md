# Azure Monitor pipeline data-flow demo guide

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

## End-to-end data flow

```mermaid
flowchart LR
   workstation[Telemetry-sending workstation<br/>Syslog TCP/514 and OTLP gRPC/4317]

   subgraph cluster[Arc-enabled Kubernetes cluster]
      pipeline[Azure Monitor pipeline<br/>Receive<br/>Filter and redact<br/>Aggregate<br/>Buffer durable branches<br/>Export]
   end

   dce[Data collection endpoint<br/>Azure ingestion endpoint]
   dcr[Data collection rule<br/>Validate streams and route tables]
   law[Log Analytics workspace<br/>RawSyslog_CL<br/>OTelLogs_CL<br/>EdgeLogSummary_CL]

   workstation -->|Syslog and OTLP| pipeline
   pipeline -->|Processed streams<br/>DCE URL and DCR ID| dce
   dce -->|Ingest| law
   dcr -.->|Define stream schemas and routing| dce
   dcr -.->|Select destination tables| law
```

Filtering, redaction, aggregation, and persistent buffering happen in the **Azure Monitor pipeline running on the Arc-enabled Kubernetes cluster**. The DCE is the Azure ingestion endpoint. The DCR is configuration, not a network endpoint: it validates the exported stream schemas and routes each stream to its Log Analytics table. It does not perform this demo's edge filtering, redaction, or aggregation.

The Arc-enabled Kubernetes cluster is not a data source. The workstation is the source because it sends Syslog and OTLP to the pipeline receivers. The cluster is the pipeline's execution location. During deployment, the pipeline resource's **Custom location** targets the custom location backed by that Arc-enabled cluster. In an Azure portal creation flow, this relationship is selected on **Basics** using **Cluster name** and **Custom location**, not on **Dataflows** and not in the DCR. This Bicep-deployed showcase establishes the same relationship through the pipeline resource's `extendedLocation`.

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
       -EventsPerSecond 5 `
       -RunId $runId `
       -ShowPayloadSample
   ```

6. Verify the readiness script's `PREFLIGHT-...` run in Log Analytics.
7. Open and arrange these views before presenting:
   - This guide at **End-to-end data flow**.
   - **Azure Monitor** > **Pipelines** > `<prefix>-pipeline`.
   - The pipeline's **Dataflows** configuration.
   - The Arc-enabled Kubernetes resource and its Extensions page.
   - Log Analytics Logs with saved Syslog and OTLP queries.
   - The pipeline's **Monitoring** > **Metrics** page.
8. Start the bounded generator before the live query segment and confirm that data is arriving.
9. Run `test-demo-recovery.ps1` on the same deployed version. Keep the restore command ready in a separate terminal during the presentation.
10. Use the staged run ID in every query and chart.

## Evidence model for the standard run

The rest of this guide is organized by feature. Every feature identifies where its configuration is visible, what effect it should have, and where to verify that effect.

Keep the generator terminal visible and use its run ID in every query. The sender's final JSON line is the source of truth for how many Syslog and OTLP events were sent.

The normal command output contains status and counters, not every event body. `-ShowPayloadSample` adds one `source-sample` JSON line for retained sequence 3. It displays the exact pre-pipeline Syslog wire message and OTLP body, including the synthetic plaintext `demo.user@example.com` and `demo-token-123`. It does not print every event or any real secret.

| Evidence | Expected after ingestion settles |
| --- | --- |
| Syslog events sent | Final sender `counts.syslog` |
| OTLP events sent | Final sender `counts.otlp` |
| Raw Syslog records retained | Five retained events per complete ten-event pattern |
| OTLP records retained | Five retained events per complete ten-event pattern |
| Syslog source events represented in summaries | Equal to the Syslog events sent |
| Unredacted synthetic email or token values | 0 |

The generator repeats a ten-event pattern. Five health/debug events are filtered and five transaction/warning/error events are retained. Each retained event contains both synthetic sensitive values, so both redaction-marker counts should equal the retained count. The readiness and recovery scripts calculate exact expectations from the final sender counts.

### Portal navigation used in this guide

In the Azure portal, search for and open **Azure Monitor**, select **Pipelines**, and then select `<prefix>-pipeline`. This is the primary presentation surface. Use its **Dataflows** experience to explain each source, listening port, transformation, destination workspace, and destination table. Use **Monitoring** > **Metrics** for pipeline health and the Log Analytics workspace **Logs** page for the resulting records.

This showcase was deployed from Bicep because it uses advanced configuration beyond the portal's guided creation experience. The portal can present the pipeline and its logical dataflows, but the current guided UI doesn't expose every advanced setting, including the persistent-volume name, exporter queue limits, custom record maps, or a custom batch interval. Do not open **JSON View** during the normal demo. Prove those advanced behaviors with the readiness and recovery checks below; use the Bicep definition only as optional engineering follow-up.

## Feature-oriented run of show

### Feature 1: Unify old and new sources

**Where the feature is set up:** In **Azure Monitor** > **Pipelines** > `<prefix>-pipeline`, open **Dataflows**. Show the Syslog source on TCP/514 and the OTLP source on TCP/4317. Follow each visual dataflow to the `<prefix>-law` Log Analytics workspace and its destination table: `RawSyslog_CL`, `OTelLogs_CL`, or `EdgeLogSummary_CL`.

**Expected telemetry effect:** The same run ID appears through both protocols. After filtering, each raw table retains five events per complete ten-event pattern. OTLP rows also retain sequence, service, site, trace, duration, and event-class fields.

**How and where to check:** In the Log Analytics workspace, open **Logs**, set the time picker to include the current run, and run:

```kusto
let RunId = "DEMO-20260919-01";
union
(
   RawSyslog_CL
   | where SyslogMessage contains RunId
   | summarize Records=count()
   | extend Path="Syslog TCP/514"
),
(
   OTelLogs_CL
   | where DemoRunId == RunId
   | summarize Records=count()
   | extend Path="OTLP gRPC/4317"
)
| project Path, Records
```

Then open representative OTLP records to show the mapped fields:

```kusto
let RunId = "DEMO-20260919-01";
OTelLogs_CL
| where DemoRunId == RunId
| project TimeGenerated, SequenceNumber, SeverityText, EventClass, ServiceName, Site, TraceId, DurationMs, Body
| order by SequenceNumber desc
| take 10
```

**Say:** One Azure-managed edge pipeline accepts a legacy protocol and a modern observability protocol, then sends each to its intended Azure Monitor table.

### Feature 2: Reduce noise and cost

**Where the feature is set up:** In **Azure Monitor** > **Pipelines** > `<prefix>-pipeline` > **Dataflows**, open the raw Syslog dataflow and its data transformation, then do the same for the OTLP dataflow. Show the `where` clauses that remove Syslog `event_class=health` and debug severity, and OTLP health bodies and `DEBUG` severity. The visual dataflow places each transformation between its source and Log Analytics destination.

**Expected telemetry effect:** Five of every ten generated events are health/debug records and must be absent from both raw tables. Each raw table therefore retains five events per complete ten-event pattern, with zero retained health or debug records.

**How and where to check:** In Log Analytics **Logs**, run:

```kusto
let RunId = "DEMO-20260919-01";
union
(
   RawSyslog_CL
   | where SyslogMessage contains RunId
   | summarize Retained=count(),
            HealthRecords=countif(SyslogMessage contains "event_class=health"),
            DebugRecords=countif(tolower(SeverityLevel) == "debug")
   | extend Path="Syslog"
),
(
   OTelLogs_CL
   | where DemoRunId == RunId
   | summarize Retained=count(),
            HealthRecords=countif(EventClass == "health"),
            DebugRecords=countif(SeverityText == "DEBUG")
   | extend Path="OTLP"
)
| project Path, Retained, HealthRecords, DebugRecords
```

**Expected result:** `Retained` matches five events per complete ten-event pattern; `HealthRecords=0` and `DebugRecords=0` for both paths.

**Say:** The edge pipeline removes low-value records before they cross the WAN or consume Log Analytics ingestion.

### Feature 3: Minimize sensitive data

**Where the feature is set up:** Keep **Azure Monitor** > **Pipelines** > `<prefix>-pipeline` > **Dataflows** open. In the raw Syslog and OTLP transformation editors, show the `replace_string` expressions that replace `demo.user@example.com` and `demo-token-123` with `[REDACTED_EMAIL]` and `[REDACTED_TOKEN]`.

**Expected telemetry effect:** No retained row contains either original synthetic value. Every retained row contains both redaction markers, so each marker count equals the retained count in each raw table.

**How and where to check:** First show the generator terminal's `source-sample` line. Sequence 3 contains `email=demo.user@example.com` in both `syslogWireMessage` and `otlpBody`; this is the plaintext source before edge processing. Then, in the Azure portal, open the Log Analytics workspace **Logs** blade and query that exact run and sequence:

```kusto
let RunId = "DEMO-20260919-01";
union
(
   RawSyslog_CL
   | where SyslogMessage contains RunId and SyslogMessage contains "sequence=3 "
   | project Path="Syslog", StoredBody=SyslogMessage
),
(
   OTelLogs_CL
   | where DemoRunId == RunId and SequenceNumber == 3
   | project Path="OTLP", StoredBody=Body
)
```

The two stored rows should contain `email=[REDACTED_EMAIL]` and `token=[REDACTED_TOKEN]`. Next run the aggregate leak check:

```kusto
let RunId = "DEMO-20260919-01";
union
(
   RawSyslog_CL
   | where SyslogMessage contains RunId
   | summarize Retained=count(),
            UnredactedValues=countif(SyslogMessage contains "demo.user@example.com" or SyslogMessage contains "demo-token-123"),
            RedactedEmails=countif(SyslogMessage contains "[REDACTED_EMAIL]"),
            RedactedTokens=countif(SyslogMessage contains "[REDACTED_TOKEN]")
   | extend Path="Syslog"
),
(
   OTelLogs_CL
   | where DemoRunId == RunId
   | summarize Retained=count(),
            UnredactedValues=countif(Body contains "demo.user@example.com" or Body contains "demo-token-123"),
            RedactedEmails=countif(Body contains "[REDACTED_EMAIL]"),
            RedactedTokens=countif(Body contains "[REDACTED_TOKEN]")
   | extend Path="OTLP"
)
| project Path, Retained, UnredactedValues, RedactedEmails, RedactedTokens
```

**Expected result:** `UnredactedValues=0`; both marker columns equal `Retained` for each path.

**Say:** Sensitive values are changed at the site. Azure Monitor receives the minimized form rather than storing the original values first.

### Feature 4: Preserve trends without every raw event

**Where the feature is set up:** In **Azure Monitor** > **Pipelines** > `<prefix>-pipeline` > **Dataflows**, open the Syslog summary dataflow whose destination is `EdgeLogSummary_CL`. Show its aggregation transformation, which groups by minute, run ID, site, and severity. This parallel branch receives the Syslog source before the raw dataflow's filter. The one-minute batch interval is advanced Bicep configuration and isn't editable in the current portal experience.

**Expected telemetry effect:** Summary rows represent all Syslog source events, including health/debug events removed from `RawSyslog_CL`. `sum(EventCount)` equals the final Syslog sent count while the raw table retains five events per complete ten-event pattern. Per complete pattern, the summaries represent five debug, three informational, one warning, and one error event.

**How and where to check:** In Log Analytics **Logs**, first prove the total reduction:

```kusto
let RunId = "DEMO-20260919-01";
let RawRetained = toscalar(
   RawSyslog_CL
   | where SyslogMessage contains RunId
   | count
);
EdgeLogSummary_CL
| where DemoRunId == RunId
| summarize SummarySourceEvents=sum(EventCount)
| extend RawRetained
| project RawRetained, SummarySourceEvents
```

Then show the one-minute rollups:

```kusto
let RunId = "DEMO-20260919-01";
EdgeLogSummary_CL
| where DemoRunId == RunId
| summarize Events=sum(EventCount) by bin(TimeGenerated, 1m), Site, SeverityLevel
| order by TimeGenerated asc
```

**Expected result:** `RawRetained` matches five events per complete ten-event pattern, and `SummarySourceEvents` equals the sender's final Syslog count. Multiple minute/severity rows are expected; re-aggregation is intentional because a batch can emit more than one summary row for the same clock minute.

**Say:** The raw branch saves ingestion by dropping repetitive detail, while the parallel summary branch preserves the operational trend and the count of filtered events.

### Feature 5: Survive a temporary cloud-path failure

**Where the feature is set up:** In **Azure Monitor** > **Pipelines** > `<prefix>-pipeline` > **Dataflows**, identify the two durable branches by their destinations: `OTelLogs_CL` and `EdgeLogSummary_CL`. Persistent-volume and per-exporter queue settings are advanced Bicep configuration and aren't exposed by the current guided portal UI, so use the recovery harness as the live proof. State the boundary clearly: `RawSyslog_CL` is intentionally nonpersistent because extension `1.7.0` stalls that exporter when persistence is enabled.

**Expected telemetry effect:** During a temporary DCE-path interruption, OTLP records and Syslog summaries queue locally and drain after restoration. The recovery run must retain every expected filtered OTLP sequence and every summarized Syslog source event. Raw Syslog is not lossless during the interruption; it must resume after restoration.

**How and where to check:** Run the complete recovery harness rather than manually issuing separate block and restore commands:

```powershell
& .\test-demo-recovery.ps1 `
   -SubscriptionId '<subscription-id>' `
   -ResourceGroupName 'rg-arc-monitor-demo' `
   -NamePrefix 'arcmon' `
   -EventsPerSecond 2
```

The script restores the route in a `finally` block and queries Log Analytics until it can test all phases. Its success line is the primary evidence:

```text
[PASS] Persistent recovery: OTLP retained all <retained> filtered records across the outage, the summary retained all <sent> source events, and raw Syslog resumed after restoration for <run-id>.
```

For an audience drill-down, use the printed recovery run ID:

```kusto
let RunId = "RECOVERY-...";
OTelLogs_CL
| where DemoRunId == RunId
| summarize Retained=count(), DistinctSequences=dcount(SequenceNumber), First=min(TimeGenerated), Last=max(TimeGenerated)
```

```kusto
let RunId = "RECOVERY-...";
EdgeLogSummary_CL
| where DemoRunId == RunId
| summarize SourceEvents=sum(EventCount), First=min(TimeGenerated), Last=max(TimeGenerated)
```

**Say:** The durable branches preserve their exact expected evidence during the rehearsed outage and drain it after recovery. Raw Syslog has the narrower guarantee that live flow resumes.

### Feature 6: Operate centrally

**Where the feature is set up:** In the Azure portal, open **Azure Monitor** > **Pipelines** > `<prefix>-pipeline`. Use **Dataflows** to show the centrally managed Syslog, OTLP, and summary paths. Then select **Monitoring** > **Metrics** to show that Azure monitors the pipeline running on the Arc-enabled cluster.

**Expected telemetry effect:** The Azure-managed definition controls what the remote pipeline receives, processes, and exports. During steady traffic, exported log records increase while failed-export records remain at zero. During the rehearsed outage, failed or retried export activity may appear before returning to normal. CPU, memory, and uptime should have current data.

**How and where to check:** First use the end-to-end diagram to identify the boundary: the workstation is the source, the pipeline runs on the Arc-enabled cluster, and the DCE/DCR route processed streams to Log Analytics. In the portal, show the pipeline dataflows and add metric charts for `exported_log_records`, `log_records_failed_to_export`, `process_cpu_utilization`, `process_memory_usage`, and `process_uptime`. Split by exporter or another available dimension when useful. The readiness script verifies the pipeline resource, cluster runtime, receiver ports, ingestion path, and all five metric definitions.

**Say:** Azure centrally defines and observes the dataflow while processing runs close to the sources. The cluster is the execution location, not the data source; Syslog and OTLP clients are the sources.

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
- [Configure a pipeline in the Azure portal](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-configure-portal)
- [Pipeline transformations](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-transformations)
- [Configure a pipeline with CLI and ARM](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-configure-cli)
- [Performance and sizing](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-sizing)
- [TLS configuration](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-tls)
- [Troubleshooting and pipeline metrics](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-troubleshoot)
- [Pipeline extension releases](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-extension-versions)
