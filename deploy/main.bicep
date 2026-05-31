targetScope = 'subscription'

param location string = 'southafricanorth'

@description('App Service Plan SKU. P1v3/P2v3/P3v3 are all Windows Premium V3 — same IIS/ASP.NET Core runtime.')
@allowed(['P1v3', 'P2v3', 'P3v3'])
param appServicePlanSkuName string = 'P2v3'

var rgName = 'rg-win-app-svc-url-cardinality-leak'

// 6-char suffix derived from subscription ID — makes globally-unique resource names
// stable across re-deployments within the same subscription.
var suffix = take(uniqueString(subscription().subscriptionId), 6)

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: rgName
  location: location
}

module resources 'resources.bicep' = {
  name: 'win-app-svc-url-cardinality-leak-resources'
  scope: rg
  params: {
    location:               location
    appServicePlanSkuName:  appServicePlanSkuName
    suffix:                 suffix
  }
}

output webAppName                 string = resources.outputs.webAppName
output appInsightsConnectionString string = resources.outputs.appInsightsConnectionString
