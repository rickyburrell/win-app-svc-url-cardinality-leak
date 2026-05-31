# Provisions the rg-leak-test-app resource group and all Azure resources.
# Run once (or re-run to update infrastructure); safe to re-run — idempotent.
#
# Prerequisites:
#   - Azure CLI installed (az)
#   - Sufficient permissions on the target subscription to create resource groups and App Services

$location       = 'eastus'
$deploymentName = 'leak-test-app'

# P1v3 / P2v3 / P3v3 are all Premium V3 — same IIS/ASP.NET Core runtime as prod P3v3.
# P2v3 gives enough headroom for a sustained load test without the prod P3v3 cost.
$appServicePlanSku = 'P2v3'

$scriptDir = $PSScriptRoot

Write-Host "Logging in to Azure..."
az login
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$accounts = az account list --query "[].{Name:name, Id:id}" -o json | ConvertFrom-Json
if ($accounts.Count -eq 0) { Write-Error "No subscriptions found."; exit 1 }

if ($accounts.Count -eq 1) {
    $subscriptionId = $accounts[0].Id
    Write-Host "Using subscription: $($accounts[0].Name) ($subscriptionId)"
} else {
    Write-Host ""
    Write-Host "Available subscriptions:"
    for ($i = 0; $i -lt $accounts.Count; $i++) {
        Write-Host "  [$($i)] $($accounts[$i].Name)  ($($accounts[$i].Id))"
    }
    $idx = [int](Read-Host "Select subscription (0-$($accounts.Count - 1))")
    $subscriptionId = $accounts[$idx].Id
    Write-Host "Selected: $($accounts[$idx].Name) ($subscriptionId)"
}

Write-Host "Setting subscription ($subscriptionId)..."
az account set --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Deploying Bicep at subscription scope..."
$resultJson = az deployment sub create `
    --name           $deploymentName `
    --location       $location `
    --template-file  "$scriptDir\main.bicep" `
    --parameters     appServicePlanSkuName=$appServicePlanSku `
    --output json
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$result = $resultJson | ConvertFrom-Json
if ($result.properties.provisioningState -eq 'Succeeded') {
    $webAppName = $result.properties.outputs.webAppName.value
    Write-Host ""
    Write-Host "Provisioning succeeded." -ForegroundColor Green
    Write-Host "  Web App : $webAppName"
    Write-Host "  URL     : https://$webAppName.azurewebsites.net"
    Write-Host "  Portal  : https://portal.azure.com/#resource/subscriptions/$subscriptionId/resourceGroups/rg-leak-test-app/providers/Microsoft.Web/sites/$webAppName"
    Write-Host ""
    Write-Host "Next: run .\publish.ps1 to build and deploy the app." -ForegroundColor Cyan
} else {
    Write-Error "Deployment finished with state: $($result.properties.provisioningState)"
    exit 1
}
