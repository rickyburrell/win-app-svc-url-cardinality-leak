// Minimal Windows App Service to reproduce the IIS in-process ANCM native request-context leak.
// Stripped to the minimum needed:
//   - Windows App Service (kind: 'app')
//   - .NET 8.0 LTS, 64-bit, IIS Integrated pipeline
//   - AlwaysOn, HTTP/2, WEBSITE_RUN_FROM_PACKAGE=1
//   - App Insights + Log Analytics for memory/CPU monitoring
// Intentionally omitted: VNet, Front Door, Key Vault, custom domain, staging slot, auto-scale.

param location string
param appServicePlanSkuName string

// ── Naming ───────────────────────────────────────────────────────────────────
var appServicePlanName = 'asp-win-app-svc-url-cardinality-leak'
var webAppName         = 'app-win-app-svc-url-cardinality-leak'
var logAnalyticsName   = 'law-win-app-svc-url-cardinality-leak'
var appInsightsName    = 'ai-win-app-svc-url-cardinality-leak'

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

// ── App Service Plan (Windows Premium V3 — same family as prod P3v3) ──────────
resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: appServicePlanSkuName
    capacity: 1
  }
  kind: 'app' // Windows
  properties: {
    reserved: false // false = Windows (mirrors prod)
    perSiteScaling: false
  }
}

// ── App settings — mirrors production exactly ─────────────────────────────────
var appSettings = [
  // Required for ZipDeploy; matches prod setting
  {
    name: 'WEBSITE_RUN_FROM_PACKAGE'
    value: '1'
  }
  // Ensures appsettings.json (not appsettings.Development.json) is loaded — matches prod
  {
    name: 'ASPNETCORE_ENVIRONMENT'
    value: 'Production'
  }
  // Stack metadata (sets "dotnet" in Portal)
  {
    name: 'CURRENT_STACK'
    value: 'dotnet'
  }
  // Verbose ASP.NET Core errors — matches prod
  {
    name: 'ASPNETCORE_DETAILEDERRORS'
    value: '1'
  }
  // SpaProxy assembly stub — matches prod app settings
  {
    name: 'ASPNETCORE_HOSTINGSTARTUPASSEMBLIES'
    value: 'Microsoft.AspNetCore.SpaProxy'
  }
  {
    name: 'WEBSITE_TIME_ZONE'
    value: 'UTC'
  }
  // Warmup path — matches prod
  {
    name: 'WEBSITE_WARMUP_PATH'
    value: '/images/v1/echo?echo=Warmup'
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
]

// ── Web App ───────────────────────────────────────────────────────────────────
resource webApp 'Microsoft.Web/sites@2024-04-01' = {
  name: webAppName
  location: location
  kind: 'app' // Windows Web app — matches prod (not 'app,linux')
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      // .NET 8.0 LTS — matches prod netFrameworkVersion
      netFrameworkVersion: 'v8.0'
      // 64-bit worker — matches prod use32BitWorkerProcess: false
      use32BitWorkerProcess: false
      // Always On — matches prod (prevents cold-start skewing the test)
      alwaysOn: true
      // HTTP/2 — matches prod
      http20Enabled: true
      // IIS Integrated pipeline — matches prod managedPipelineMode
      managedPipelineMode: 'Integrated'
      // Load balancing — matches prod
      loadBalancing: 'LeastRequests'
      // CURRENT_STACK metadata for Portal display
      metadata: [
        {
          name: 'CURRENT_STACK'
          value: 'dotnet'
        }
      ]
      // Preload enabled — matches prod virtualApplications
      virtualApplications: [
        {
          virtualPath: '/'
          physicalPath: 'site\\wwwroot'
          preloadEnabled: true
        }
      ]
      // Default document — opens Swagger on browse
      defaultDocuments: [
        'docs/index.html'
      ]
      // TLS — matches prod
      ftpsState: 'FtpsOnly'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      // Logging
      detailedErrorLoggingEnabled: true
      httpLoggingEnabled: true
      requestTracingEnabled: true
      logsDirectorySizeLimit: 35
      // Health check — same path as prod
      healthCheckPath: '/images/v1/echo?echo=health'
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
