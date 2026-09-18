@description('Name of the Azure Monitor pipeline group.')
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

@description('Tags applied to resources that support tags.')
param tags object = {
  workload: 'azure-monitor-pipeline-demo'
  environment: 'demo'
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
          'Microsoft-Syslog-FullyFormed'
        ]
        destinations: [
          'DemoWorkspace'
        ]
        transformKql: 'source'
        outputStream: 'Microsoft-Syslog'
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
    ]
    exporters: [
      {
        type: 'AzureMonitorWorkspaceLogs'
        name: 'syslog-exporter'
        azureMonitorWorkspaceLogs: {
          api: {
            dataCollectionEndpointUrl: dataCollectionEndpointLogsIngestionUrl
            dataCollectionRule: dataCollectionRule.properties.immutableId
            stream: 'Microsoft-Syslog-FullyFormed'
            schema: {
              recordMap: [
                {
                  from: 'attributes.CollectorHostName'
                  to: 'CollectorHostName'
                }
                {
                  from: 'attributes.Computer'
                  to: 'Computer'
                }
                {
                  from: 'attributes.EventTime'
                  to: 'EventTime'
                }
                {
                  from: 'attributes.Facility'
                  to: 'Facility'
                }
                {
                  from: 'attributes.HostIP'
                  to: 'HostIP'
                }
                {
                  from: 'attributes.HostName'
                  to: 'HostName'
                }
                {
                  from: 'attributes.ProcessID'
                  to: 'ProcessID'
                }
                {
                  from: 'attributes.ProcessName'
                  to: 'ProcessName'
                }
                {
                  from: 'attributes.SeverityLevel'
                  to: 'SeverityLevel'
                }
                {
                  from: 'attributes.SourceSystem'
                  to: 'SourceSystem'
                }
                {
                  from: 'attributes.SyslogMessage'
                  to: 'SyslogMessage'
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
              ]
            }
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
          ]
          exporters: [
            'syslog-exporter'
          ]
        }
        {
          name: 'otlp-pipeline'
          type: 'Logs'
          receivers: [
            'otlp-receiver'
          ]
          exporters: [
            'otlp-exporter'
          ]
        }
      ]
    }
  }
  dependsOn: [
    pipelineDcrAccess
  ]
}

output dataCollectionRuleName string = dataCollectionRule.name
output dataCollectionRuleImmutableId string = dataCollectionRule.properties.immutableId
output pipelineGroupName string = pipelineGroup.name