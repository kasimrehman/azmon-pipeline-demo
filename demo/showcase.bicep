@description('Name of the existing Azure Monitor pipeline group.')
param pipelineName string

@description('Azure region shared by the DCE, DCR, workspace, and pipeline group.')
param location string = resourceGroup().location

@description('Resource ID of the custom location backed by the Arc-enabled cluster.')
param customLocationResourceId string

@description('Resource ID of the Log Analytics workspace.')
param workspaceResourceId string

@description('Resource ID of the data collection endpoint.')
param dataCollectionEndpointResourceId string

@description('Logs ingestion URL exposed by the data collection endpoint.')
param dataCollectionEndpointLogsIngestionUrl string

@description('Object ID of the Azure Monitor pipeline extension managed identity.')
param pipelineExtensionPrincipalId string

@description('Persistent volume prepared by setup-demo.ps1.')
param persistentVolumeName string = 'azure-monitor-pipeline-demo-pv'

@description('Maximum disk space in GiB used by each exporter buffer.')
@minValue(1)
param maxStorageUsage int = 2

@description('Maximum buffered record age in minutes.')
@minValue(1)
@maxValue(2880)
param retentionPeriod int = 120

@description('Tags applied to resources that support tags.')
param tags object = {
  workload: 'azure-monitor-pipeline-demo'
  environment: 'demo'
  showcase: 'full'
}

var dcrName = '${pipelineName}-dcr'
var monitoringMetricsPublisherRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '3913510d-42f4-4e42-8a64-420c390055eb'
)

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: dcrName
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dataCollectionEndpointResourceId
    streamDeclarations: {
      'Custom-RawSyslog': {
        columns: [
          {
            name: 'TimeGenerated'
            type: 'datetime'
          }
          {
            name: 'Body'
            type: 'string'
          }
          {
            name: 'SeverityText'
            type: 'string'
          }
        ]
      }
      'Custom-OTLP': {
        columns: [
          {
            name: 'Body'
            type: 'string'
          }
          {
            name: 'TimeGenerated'
            type: 'datetime'
          }
          {
            name: 'SeverityText'
            type: 'string'
          }
          {
            name: 'DemoRunId'
            type: 'string'
          }
          {
            name: 'SequenceNumber'
            type: 'long'
          }
          {
            name: 'ServiceName'
            type: 'string'
          }
          {
            name: 'DeploymentEnvironment'
            type: 'string'
          }
          {
            name: 'Site'
            type: 'string'
          }
          {
            name: 'TraceId'
            type: 'string'
          }
          {
            name: 'DurationMs'
            type: 'real'
          }
          {
            name: 'EventClass'
            type: 'string'
          }
        ]
      }
      'Custom-EdgeLogSummary': {
        columns: [
          {
            name: 'TimeGenerated'
            type: 'datetime'
          }
          {
            name: 'DemoRunId'
            type: 'string'
          }
          {
            name: 'Site'
            type: 'string'
          }
          {
            name: 'SeverityLevel'
            type: 'string'
          }
          {
            name: 'EventCount'
            type: 'long'
          }
        ]
      }
    }
    dataSources: {}
    destinations: {
      logAnalytics: [
        {
          name: 'DemoWorkspace'
          workspaceResourceId: workspaceResourceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Custom-RawSyslog'
        ]
        destinations: [
          'DemoWorkspace'
        ]
        transformKql: 'source | project TimeGenerated, CollectorHostName = "", Computer = "", EventTime = TimeGenerated, Facility = "", HostIP = "", HostName = "", ProcessID = toint(""), ProcessName = "", SeverityLevel = SeverityText, SourceSystem = "Azure", SyslogMessage = Body'
        outputStream: 'Custom-RawSyslog_CL'
      }
      {
        streams: [
          'Custom-OTLP'
        ]
        destinations: [
          'DemoWorkspace'
        ]
        transformKql: 'source'
        outputStream: 'Custom-OTelLogs_CL'
      }
      {
        streams: [
          'Custom-EdgeLogSummary'
        ]
        destinations: [
          'DemoWorkspace'
        ]
        transformKql: 'source'
        outputStream: 'Custom-EdgeLogSummary_CL'
      }
    ]
  }
}

resource pipelineDcrAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataCollectionRule.id, pipelineExtensionPrincipalId, monitoringMetricsPublisherRoleDefinitionId)
  scope: dataCollectionRule
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleDefinitionId
    principalId: pipelineExtensionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource pipelineGroup 'Microsoft.Monitor/pipelineGroups@2026-04-01' = {
  name: pipelineName
  location: location
  extendedLocation: {
    name: customLocationResourceId
    type: 'CustomLocation'
  }
  properties: {
    receivers: [
      {
        type: 'Syslog'
        name: 'syslog-receiver'
        syslog: {
          endpoint: '0.0.0.0:514'
          transportProtocol: 'tcp'
          allowedFormats: [
            'all'
          ]
        }
      }
      {
        type: 'OTLP'
        name: 'otlp-receiver'
        otlp: {
          endpoint: '0.0.0.0:4317'
        }
      }
    ]
    processors: [
      {
        type: 'MicrosoftSyslog'
        name: 'syslog-processor'
      }
      {
        type: 'Batch'
        name: 'syslog-export-batch'
        batch: {
          timeout: 60000
        }
      }
      {
        type: 'TransformLanguage'
        name: 'syslog-filter-redact'
        transformLanguage: {
          transformStatement: 'source | where SyslogMessage !contains "event_class=health" and SeverityLevel != "debug" | extend ProcessID = toint(ProcessID), SyslogMessage = replace_string(replace_string(SyslogMessage, "demo.user@example.com", "[REDACTED_EMAIL]"), "demo-token-123", "[REDACTED_TOKEN]")'
        }
      }
      {
        type: 'Batch'
        name: 'summary-batch'
        batch: {
          timeout: 60000
        }
      }
      {
        type: 'TransformLanguage'
        name: 'syslog-summary'
        transformLanguage: {
          transformStatement: 'source | extend DemoRunId = extract("run_id=([^ ]+)", 1, SyslogMessage), Site = extract("site=([^ ]+)", 1, SyslogMessage), TimeGenerated = bin(TimeGenerated, 1m) | summarize EventCount=count() by TimeGenerated, DemoRunId, Site, SeverityLevel'
        }
      }
      {
        type: 'TransformLanguage'
        name: 'otlp-filter-redact'
        transformLanguage: {
          transformStatement: 'source | where Body !contains "event_class=health" and SeverityText != "DEBUG" | extend Body = replace_string(replace_string(Body, "demo.user@example.com", "[REDACTED_EMAIL]"), "demo-token-123", "[REDACTED_TOKEN]")'
        }
      }
      {
        type: 'Batch'
        name: 'otlp-export-batch'
        batch: {
          timeout: 60000
        }
      }
    ]
    exporters: [
      {
        type: 'AzureMonitorWorkspaceLogs'
        name: 'syslog-exporter-v3'
        azureMonitorWorkspaceLogs: {
          api: {
            dataCollectionEndpointUrl: dataCollectionEndpointLogsIngestionUrl
            dataCollectionRule: dataCollectionRule.properties.immutableId
            stream: 'Custom-RawSyslog'
            schema: {
              recordMap: [
                {
                  from: 'attributes.SeverityLevel'
                  to: 'SeverityText'
                }
                {
                  from: 'attributes.SyslogMessage'
                  to: 'Body'
                }
                {
                  from: 'attributes.TimeGenerated'
                  to: 'TimeGenerated'
                }
              ]
            }
          }
        }
      }
      {
        type: 'AzureMonitorWorkspaceLogs'
        name: 'syslog-summary-exporter'
        azureMonitorWorkspaceLogs: {
          api: {
            dataCollectionEndpointUrl: dataCollectionEndpointLogsIngestionUrl
            dataCollectionRule: dataCollectionRule.properties.immutableId
            stream: 'Custom-EdgeLogSummary'
            schema: {
              recordMap: [
                {
                  from: 'attributes.TimeGenerated'
                  to: 'TimeGenerated'
                }
                {
                  from: 'attributes.DemoRunId'
                  to: 'DemoRunId'
                }
                {
                  from: 'attributes.Site'
                  to: 'Site'
                }
                {
                  from: 'attributes.SeverityLevel'
                  to: 'SeverityLevel'
                }
                {
                  from: 'attributes.EventCount'
                  to: 'EventCount'
                }
              ]
            }
          }
          persistence: {
            maxStorageUsage: maxStorageUsage
            retentionPeriod: retentionPeriod
          }
        }
      }
      {
        type: 'AzureMonitorWorkspaceLogs'
        name: 'otlp-exporter'
        azureMonitorWorkspaceLogs: {
          api: {
            dataCollectionEndpointUrl: dataCollectionEndpointLogsIngestionUrl
            dataCollectionRule: dataCollectionRule.properties.immutableId
            stream: 'Custom-OTLP'
            schema: {
              recordMap: [
                {
                  from: 'severity_text'
                  to: 'SeverityText'
                }
                {
                  from: 'body'
                  to: 'Body'
                }
                {
                  from: 'time_unix_nano'
                  to: 'TimeGenerated'
                }
                {
                  from: 'attributes.DemoRunId'
                  to: 'DemoRunId'
                }
                {
                  from: 'attributes.SequenceNumber'
                  to: 'SequenceNumber'
                }
                {
                  from: 'attributes.ServiceName'
                  to: 'ServiceName'
                }
                {
                  from: 'attributes.DeploymentEnvironment'
                  to: 'DeploymentEnvironment'
                }
                {
                  from: 'attributes.Site'
                  to: 'Site'
                }
                {
                  from: 'attributes.TraceId'
                  to: 'TraceId'
                }
                {
                  from: 'attributes.DurationMs'
                  to: 'DurationMs'
                }
                {
                  from: 'attributes.EventClass'
                  to: 'EventClass'
                }
              ]
            }
          }
          persistence: {
            maxStorageUsage: maxStorageUsage
            retentionPeriod: retentionPeriod
          }
        }
      }
    ]
    service: {
      pipelines: [
        {
          name: 'syslog-pipeline'
          type: 'Logs'
          receivers: [
            'syslog-receiver'
          ]
          processors: [
            'syslog-processor'
            'syslog-export-batch'
            'syslog-filter-redact'
          ]
          exporters: [
            'syslog-exporter-v3'
          ]
        }
        {
          name: 'syslog-summary-pipeline'
          type: 'Logs'
          receivers: [
            'syslog-receiver'
          ]
          processors: [
            'syslog-processor'
            'summary-batch'
            'syslog-summary'
          ]
          exporters: [
            'syslog-summary-exporter'
          ]
        }
        {
          name: 'otlp-pipeline'
          type: 'Logs'
          receivers: [
            'otlp-receiver'
          ]
          processors: [
            'otlp-export-batch'
            'otlp-filter-redact'
          ]
          exporters: [
            'otlp-exporter'
          ]
        }
      ]
      persistence: {
        persistentVolumeName: persistentVolumeName
      }
    }
  }
  dependsOn: [
    pipelineDcrAccess
  ]
}

output dataCollectionRuleName string = dataCollectionRule.name
output dataCollectionRuleImmutableId string = dataCollectionRule.properties.immutableId
output pipelineGroupName string = pipelineGroup.name
