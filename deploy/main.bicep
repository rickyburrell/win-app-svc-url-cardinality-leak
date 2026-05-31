targetScope = 'subscription'

param location string = 'eastus'

@description('App Service Plan SKU. P1v3/P2v3/P3v3 all use the same IIS/ASP.NET Core runtime as prod.')
@allowed(['P1v3', 'P2v3', 'P3v3'])
param appServicePlanSkuName string = 'P2v3'

var rgName = 'rg-leak-test-app'

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: rgName
  location: location
}

module resources 'resources.bicep' = {
  name: 'leak-test-resources'
  scope: rg
  params: {
    location:               location
    appServicePlanSkuName:  appServicePlanSkuName
  }
}

output webAppName                 string = resources.outputs.webAppName
output appInsightsConnectionString string = resources.outputs.appInsightsConnectionString
