@description('Primary region for all resources.')
param location string = resourceGroup().location

@description('Resource name prefix. Use 3-10 lowercase letters or numbers.')
param prefix string

@description('APIM publisher email.')
param apimPublisherEmail string

@description('APIM publisher name.')
param apimPublisherName string

@description('Cosmos DB throughput for container (RU/s).')
param cosmosThroughput int = 400

@description('Function runtime name.')
@allowed([ 'dotnet-isolated' ])
param functionRuntime string = 'dotnet-isolated'

@description('Function runtime version.')
param functionRuntimeVersion string = '8.0'

var storageName = toLower('st${uniqueString(resourceGroup().id, prefix)}')
var functionPlanName = '${prefix}-plan'
var functionAppName = '${prefix}-func'
var apimName = '${prefix}-apim'
var cosmosName = '${prefix}-cosmos'
var logAnalyticsName = '${prefix}-log'
var appInsightsName = '${prefix}-appi'
var deploymentContainerName = 'deployments'
var cosmosDataContributorRoleId = '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'

module network './network.bicep' = {
  name: '${prefix}-network'
  params: {
    location: location
    prefix: prefix
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}


resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    DisableLocalAuth: true
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
  }
  resource blobServices 'blobServices' = {
    name: 'default'
    resource deploymentContainer 'containers' = {
      name: deploymentContainerName
      properties: {
        publicAccess: 'None'
      }
    }
  }
}

resource functionPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: functionPlanName
  location: location
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: functionPlan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    siteConfig: {
      minTlsVersion: '1.2'
    }
    virtualNetworkSubnetId: network.outputs.functionSubnetId
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 50
        instanceMemoryMB: 2048
      }
      runtime: {
        name: functionRuntime
        version: functionRuntimeVersion
      }
    }
  }
  resource appSettings 'config' = {
    name: 'appsettings'
    properties: {
      AzureWebJobsStorage__accountName: storage.name
      AzureWebJobsStorage__credential: 'managedidentity'
      APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.properties.ConnectionString
      APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
      CosmosDb__DatabaseName: 'telemetrydb'
      CosmosDb__ContainerName: 'telemetry'
      CosmosDb__AccountEndpoint: cosmosAccount.properties.documentEndpoint
    }
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  sku: {
    name: 'StandardV2'
    capacity: 1
  }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: network.outputs.apimOutboundSubnetId
    }
    outboundPublicIPAddressCount: 1
  }
}

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = {
  name: cosmosName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: location
        failoverPriority: 0
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    publicNetworkAccess: 'Enabled'
    enableAutomaticFailover: false
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-11-15' = {
  name: '${cosmosAccount.name}/telemetrydb'
  properties: {
    resource: {
      id: 'telemetrydb'
    }
  }
}

resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-11-15' = {
  name: '${cosmosAccount.name}/telemetrydb/telemetry'
  properties: {
    resource: {
      id: 'telemetry'
      partitionKey: {
        paths: [
          '/deviceId'
        ]
        kind: 'Hash'
      }
    }
    options: {
      throughput: cosmosThroughput
    }
  }
}

resource cosmosRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-11-15' = {
  name: guid(cosmosAccount.id, functionApp.name, cosmosDataContributorRoleId)
  parent: cosmosAccount
  properties: {
    principalId: functionApp.identity.principalId
    roleDefinitionId: cosmosDataContributorRoleId
    scope: cosmosAccount.id
  }
}

resource storageBlobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionApp.name, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storage
  properties: {
    roleDefinitionId: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.documents.azure.com'
  location: 'global'
}

resource privateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${privateDnsZone.name}/${prefix}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: network.outputs.vnetId
    }
  }
}

resource functionPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
}

resource functionPrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${functionPrivateDnsZone.name}/${prefix}-func-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: network.outputs.vnetId
    }
  }
}

resource cosmosPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: '${prefix}-cosmos-pe'
  location: location
  properties: {
    subnet: {
      id: network.outputs.privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-cosmos-pls'
        properties: {
          privateLinkServiceId: cosmosAccount.id
          groupIds: [
            'Sql'
          ]
        }
      }
    ]
  }
}

resource cosmosPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  name: '${cosmosPrivateEndpoint.name}/cosmos-dns'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'cosmos-zone'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

resource functionPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: '${prefix}-func-pe'
  location: location
  properties: {
    subnet: {
      id: network.outputs.privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-func-pls'
        properties: {
          privateLinkServiceId: functionApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

resource functionPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  name: '${functionPrivateEndpoint.name}/func-dns'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'func-zone'
        properties: {
          privateDnsZoneId: functionPrivateDnsZone.id
        }
      }
    ]
  }
}

resource apimApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  name: '${apim.name}/telemetry-api'
  properties: {
    displayName: 'Telemetry API'
    path: 'telemetry'
    protocols: [
      'https'
    ]
    apiType: 'http'
    subscriptionRequired: false
  }
}

resource apimOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  name: '${apim.name}/telemetry-api/post-telemetry'
  properties: {
    displayName: 'POST telemetry'
    method: 'POST'
    urlTemplate: '/telemetry'
    request: {
      queryParameters: []
      headers: []
      representations: [
        {
          contentType: 'application/json'
        }
      ]
    }
    responses: [
      {
        statusCode: 201
        description: 'Created'
      }
      {
        statusCode: 400
        description: 'Bad Request'
      }
      {
        statusCode: 500
        description: 'Internal Server Error'
      }
    ]
  }
  dependsOn: [
    apimApi
  ]
}

output functionAppName string = functionApp.name
output functionAppId string = functionApp.id
output apimName string = apim.name
output cosmosAccountName string = cosmosAccount.name
output vnetName string = network.outputs.vnetName
