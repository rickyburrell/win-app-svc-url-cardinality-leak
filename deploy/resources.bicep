// Minimal Windows App Service to reproduce the IIS in-process native request-context leak.
// Stripped to the minimum needed:
//   - Windows App Service (kind: 'app')
//   - .NET 8.0 LTS, 64-bit, IIS Integrated pipeline
//   - AlwaysOn, HTTP/2, WEBSITE_RUN_FROM_PACKAGE=1
//   - App Insights + Log Analytics for memory/CPU monitoring
// Intentionally omitted: VNet, Front Door, Key Vault, custom domain, staging slot, auto-scale.

param location string
param appServicePlanSkuName string
param suffix string

// ── Naming ───────────────────────────────────────────────────────────────────
var appServicePlanName = 'asp-win-app-svc-url-cardinality-leak'
var webAppName         = 'app-win-app-svc-url-cardinality-leak-${suffix}'
var logAnalyticsName   = 'law-win-app-svc-url-cardinality-leak-${suffix}'
var appInsightsName    = 'ai-win-app-svc-url-cardinality-leak'
// Storage: 3-24 chars, lowercase alphanumeric only — 'stwinappsvcleak' = 15 + 6 suffix = 21
var storageAccountName = 'stwinappsvcleak${suffix}'

// ── Log Analytics ─────────────────────────────────────────────────────────────
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ── Application Insights ──────────────────────────────────────────────────────
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ── Storage account (dump / LeakTrack diagnostic storage) ────────────────────
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource dumpsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'dumps'
  properties: { publicAccess: 'None' }
}

// SAS token: blob service, all permissions, service+container+object scope, expires 2030-01-01
var sasExpiry = '2030-01-01T00:00:00Z'
var accountSasParams = {
  signedServices: 'b'
  signedPermission: 'rwdlacup'
  signedResourceTypes: 'sco'
  signedExpiry: sasExpiry
  signedProtocol: 'https'
}
var sasToken = storageAccount.listAccountSas('2023-01-01', accountSasParams).accountSasToken
var dumpsSasUri = '${storageAccount.properties.primaryEndpoints.blob}dumps?${sasToken}'

// ── App Service Plan (Windows Premium V3) ────────────────────────────────────
resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: appServicePlanSkuName
    capacity: 1
  }
  kind: 'app' // Windows
  properties: {
    reserved: false // false = Windows
    perSiteScaling: false
  }
}

// ── App settings ─────────────────────────────────────────────────────────────
var appSettings = [
  {
    name: 'WEBSITE_RUN_FROM_PACKAGE'
    value: '1'
  }
  // Ensures appsettings.json (not appsettings.Development.json) is loaded
  {
    name: 'ASPNETCORE_ENVIRONMENT'
    value: 'Production'
  }
  // Stack metadata (sets "dotnet" in Portal)
  {
    name: 'CURRENT_STACK'
    value: 'dotnet'
  }
  // Verbose ASP.NET Core errors
  {
    name: 'ASPNETCORE_DETAILEDERRORS'
    value: '1'
  }
  {
    name: 'WEBSITE_TIME_ZONE'
    value: 'UTC'
  }
  {
    name: 'WEBSITE_WARMUP_PATH'
    value: '/echo?echo=warmup'
  }
  // Application Insights
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsights.properties.ConnectionString
  }
  {
    name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
    value: appInsights.properties.InstrumentationKey
  }
  {
    name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
    value: '~3'
  }
  {
    name: 'XDT_MicrosoftApplicationInsights_Mode'
    value: 'recommended'
  }
  {
    name: 'APPINSIGHTS_PROFILERFEATURE_VERSION'
    value: '1.0.0'
  }
  {
    name: 'DiagnosticServices_EXTENSION_VERSION'
    value: '~3'
  }
  // LeakTrack: injects LeakTrack.dll into w3wp to record allocation call stacks in memory dumps.
  // Required by Microsoft support to pinpoint the native leak source.
  {
    name: 'WEBSITE_CRASHMONITORING_SETTINGS'
    value: '{"StartTimeUtc":"2026-05-31T00:00:00.000Z","MaxHours":360,"MaxDumpCount":3,"ExceptionFilter":"-f E053534F -f C00000FD.STACK_OVERFLOW","InjectLeakTrack":true}'
  }
  // DaaS dump storage — LeakTrack and memory dumps are uploaded here
  {
    name: 'WEBSITE_DAAS_STORAGE_SASURI'
    value: dumpsSasUri
  }
]

// ── Web App ───────────────────────────────────────────────────────────────────
resource webApp 'Microsoft.Web/sites@2024-04-01' = {
  name: webAppName
  location: location
  kind: 'app' // Windows Web app (not 'app,linux')
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      // .NET 8.0 LTS
      netFrameworkVersion: 'v8.0'
      // 64-bit worker
      use32BitWorkerProcess: false
      // Always On — prevents cold-start skewing the test
      alwaysOn: true
      // HTTP/2
      http20Enabled: true
      // IIS Integrated pipeline
      managedPipelineMode: 'Integrated'
      // Load balancing
      loadBalancing: 'LeastRequests'
      // CURRENT_STACK metadata for Portal display
      metadata: [
        {
          name: 'CURRENT_STACK'
          value: 'dotnet'
        }
      ]
      // Preload enabled
      virtualApplications: [
        {
          virtualPath: '/'
          physicalPath: 'site\\wwwroot'
          preloadEnabled: true
        }
      ]
      defaultDocuments: [
        'index.html'
      ]
      // TLS
      ftpsState: 'FtpsOnly'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      // Logging
      detailedErrorLoggingEnabled: true
      httpLoggingEnabled: true
      requestTracingEnabled: true
      logsDirectorySizeLimit: 35
      healthCheckPath: '/echo?echo=health'
      // Public access — no Front Door restriction for the test app
      publicNetworkAccess: 'Enabled'
      ipSecurityRestrictionsDefaultAction: 'Allow'
      scmIpSecurityRestrictionsDefaultAction: 'Allow'
      appSettings: appSettings
    }
  }
}

// ── Web app logs config ───────────────────────────────────────────────────────
resource webAppLogs 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: webApp
  name: 'logs'
  properties: {
    detailedErrorMessages: {
      enabled: true
    }
    failedRequestsTracing: {
      enabled: true
    }
    applicationLogs: {
      fileSystem: {
        level: 'Information'
      }
    }
    httpLogs: {
      fileSystem: {
        retentionInMb: 35
        enabled: true
        retentionInDays: 30
      }
    }
  }
}

// ── Diagnostic settings → Log Analytics ──────────────────────────────────────
resource webAppDiags 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${webAppName}'
  scope: webApp
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        enabled: true
      }
      {
        category: 'AppServiceAuthenticationLogs'
        enabled: true
      }
      {
        category: 'AppServiceAuditLogs'
        enabled: true
      }
      {
        category: 'AppServiceIPSecAuditLogs'
        enabled: true
      }
      {
        category: 'AppServicePlatformLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output webAppName                 string = webApp.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output storageAccountName         string = storageAccount.name
output dumpContainerUri           string = '${storageAccount.properties.primaryEndpoints.blob}dumps'
