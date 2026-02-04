@description('APIM instance name')
param apimName string

@description('Function App name')
param functionAppName string

@description('Function App resource ID')
param functionAppId string

@description('APIM API name')
param apiName string = 'telemetry-api'

@description('APIM operation name')
param operationName string = 'post-telemetry'

@description('APIM backend id')
param backendId string = 'function-backend'

resource apimBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  name: '${apimName}/${backendId}'
  properties: {
    title: 'Function App Backend'
    description: 'Function App backend for telemetry API'
    url: 'https://${functionAppName}.azurewebsites.net/api'
    protocol: 'http'
    credentials: {
      header: {
        'x-functions-key': [
          listKeys('${functionAppId}/host/default', '2024-04-01').functionKeys.default
        ]
      }
    }
  }
}

resource apimOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  name: '${apimName}/${apiName}/${operationName}/policy'
  properties: {
    format: 'rawxml'
    value: format('''<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="{0}" />
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>''', backendId)
  }
  dependsOn: [apimBackend]
}
