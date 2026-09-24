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

@description('Name of the existing network security group protecting the demo VM.')
param networkSecurityGroupName string

@description('CIDR allowed to send CEF traffic to the demo endpoint.')
param allowedSourceCidr string

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
var commonSecurityLogColumns = [
  'TimeGenerated'
  'DeviceVendor'
  'DeviceProduct'
  'DeviceVersion'
  'DeviceEventClassID'
  'Activity'
  'LogSeverity'
  'OriginalLogSeverity'
  'AdditionalExtensions'
  'DeviceAction'
  'ApplicationProtocol'
  'EventCount'
  'DestinationDnsDomain'
  'DestinationServiceName'
  'DestinationTranslatedAddress'
  'DestinationTranslatedPort'
  'CommunicationDirection'
  'DeviceDnsDomain'
  'DeviceExternalID'
  'DeviceFacility'
  'DeviceInboundInterface'
  'DeviceNtDomain'
  'DeviceOutboundInterface'
  'DevicePayloadId'
  'ProcessName'
  'DeviceTranslatedAddress'
  'DestinationHostName'
  'DestinationMACAddress'
  'DestinationNTDomain'
  'DestinationProcessId'
  'DestinationUserPrivileges'
  'DestinationProcessName'
  'DestinationPort'
  'DestinationIP'
  'DeviceTimeZone'
  'DestinationUserID'
  'DestinationUserName'
  'DeviceAddress'
  'DeviceName'
  'DeviceMacAddress'
  'ProcessID'
  'EndTime'
  'ExternalID'
  'ExtID'
  'FileCreateTime'
  'FileHash'
  'FileID'
  'FileModificationTime'
  'FilePath'
  'FilePermission'
  'FileType'
  'FileName'
  'FileSize'
  'ReceivedBytes'
  'Message'
  'OldFileCreateTime'
  'OldFileHash'
  'OldFileID'
  'OldFileModificationTime'
  'OldFileName'
  'OldFilePath'
  'OldFilePermission'
  'OldFileSize'
  'OldFileType'
  'SentBytes'
  'EventOutcome'
  'Protocol'
  'Reason'
  'RequestURL'
  'RequestClientApplication'
  'RequestContext'
  'RequestCookies'
  'RequestMethod'
  'ReceiptTime'
  'SourceHostName'
  'SourceMACAddress'
  'SourceNTDomain'
  'SourceDnsDomain'
  'SourceServiceName'
  'SourceTranslatedAddress'
  'SourceTranslatedPort'
  'SourceProcessId'
  'SourceUserPrivileges'
  'SourceProcessName'
  'SourcePort'
  'SourceIP'
  'StartTime'
  'SourceUserID'
  'SourceUserName'
  'EventType'
  'DeviceEventCategory'
  'DeviceCustomIPv6Address1'
  'DeviceCustomIPv6Address1Label'
  'DeviceCustomIPv6Address2'
  'DeviceCustomIPv6Address2Label'
  'DeviceCustomIPv6Address3'
  'DeviceCustomIPv6Address3Label'
  'DeviceCustomIPv6Address4'
  'DeviceCustomIPv6Address4Label'
  'DeviceCustomFloatingPoint1'
  'DeviceCustomFloatingPoint1Label'
  'DeviceCustomFloatingPoint2'
  'DeviceCustomFloatingPoint2Label'
  'DeviceCustomFloatingPoint3'
  'DeviceCustomFloatingPoint3Label'
  'DeviceCustomFloatingPoint4'
  'DeviceCustomFloatingPoint4Label'
  'DeviceCustomNumber1'
  'FieldDeviceCustomNumber1'
  'DeviceCustomNumber1Label'
  'DeviceCustomNumber2'
  'FieldDeviceCustomNumber2'
  'DeviceCustomNumber2Label'
  'DeviceCustomNumber3'
  'FieldDeviceCustomNumber3'
  'DeviceCustomNumber3Label'
  'DeviceCustomString1'
  'DeviceCustomString1Label'
  'DeviceCustomString2'
  'DeviceCustomString2Label'
  'DeviceCustomString3'
  'DeviceCustomString3Label'
  'DeviceCustomString4'
  'DeviceCustomString4Label'
  'DeviceCustomString5'
  'DeviceCustomString5Label'
  'DeviceCustomString6'
  'DeviceCustomString6Label'
  'DeviceCustomDate1'
  'DeviceCustomDate1Label'
  'DeviceCustomDate2'
  'DeviceCustomDate2Label'
  'FlexDate1'
  'FlexDate1Label'
  'FlexNumber1'
  'FlexNumber1Label'
  'FlexNumber2'
  'FlexNumber2Label'
  'FlexString1'
  'FlexString1Label'
  'FlexString2'
  'FlexString2Label'
  'RemoteIP'
  'RemotePort'
  'MaliciousIP'
  'ThreatSeverity'
  'IndicatorThreatType'
  'ThreatDescription'
  'ThreatConfidence'
  'ReportReferenceLink'
  'MaliciousIPLongitude'
  'MaliciousIPLatitude'
  'MaliciousIPCountry'
  'Computer'
  'SourceSystem'
  'SimplifiedDeviceAction'
  'CollectorHostName'
]

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' existing = {
  name: networkSecurityGroupName
}

resource cefSecurityRule 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = {
  parent: networkSecurityGroup
  name: 'Allow-CEF-Demo-Source'
  properties: {
    priority: 120
    access: 'Allow'
    direction: 'Inbound'
    protocol: 'Tcp'
    sourcePortRange: '*'
    destinationPortRange: '515'
    sourceAddressPrefix: allowedSourceCidr
    destinationAddressPrefix: '*'
  }
}

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
          'Microsoft-CommonSecurityLog-FullyFormed'
        ]
        destinations: [
          'DemoWorkspace'
        ]
        transformKql: 'source'
        outputStream: 'Microsoft-CommonSecurityLog'
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
      {
        type: 'Syslog'
        name: 'cef-receiver'
        syslog: {
          endpoint: '0.0.0.0:515'
          transportProtocol: 'tcp'
          allowedFormats: [
            'all'
          ]
        }
      }
    ]
    processors: [
      {
        type: 'MicrosoftSyslog'
        name: 'syslog-processor'
      }
      {
        type: 'MicrosoftCommonSecurityLog'
        name: 'cef-processor'
      }
      {
        type: 'TransformLanguage'
        name: 'syslog-filter-redact'
        transformLanguage: {
          transformStatement: 'source | where SyslogMessage !contains \'event_class=health\' and SeverityLevel != \'debug\' | extend SyslogMessage = replace_string(replace_string(SyslogMessage, \'demo.user@example.com\', \'[REDACTED_EMAIL]\'), \'demo-token-123\', \'[REDACTED_TOKEN]\')'
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
            stream: 'Microsoft-Syslog-FullyFormed'
            schema: {
              recordMap: [
                {
                  from: 'attributes.TimeGenerated'
                  to: 'TimeGenerated'
                }
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
        name: 'cef-exporter'
        azureMonitorWorkspaceLogs: {
          api: {
            dataCollectionEndpointUrl: dataCollectionEndpointLogsIngestionUrl
            dataCollectionRule: dataCollectionRule.properties.immutableId
            stream: 'Microsoft-CommonSecurityLog-FullyFormed'
            schema: {
              recordMap: [
                for column in commonSecurityLogColumns: {
                  from: 'attributes.${column}'
                  to: column
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
        {
          name: 'cef-pipeline'
          type: 'Logs'
          receivers: [
            'cef-receiver'
          ]
          processors: [
            'cef-processor'
          ]
          exporters: [
            'cef-exporter'
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
