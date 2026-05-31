# Builds and deploys WinAppSvcUrlCardinalityLeak to the Azure App Service.
# Requires Azure CLI (az) to be installed and logged in.
# Run provision.ps1 first to create the infrastructure.

$resourceGroup  = 'rg-win-app-svc-url-cardinality-leak'
$deploymentName = 'leak-test-app'

$scriptDir   = $PSScriptRoot
$repoRoot    = Split-Path -Parent $scriptDir          # leak-test-app\
$projectPath = Join-Path $repoRoot 'WinAppSvcUrlCardinalityLeak'
$publishDir  = Join-Path $repoRoot '.publish'
$zipPath     = Join-Path $repoRoot '.publish.zip'

Write-Host "Building and publishing..."
if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }

# Framework-dependent win-x64 publish — matches the production deployment model.
# --no-self-contained is explicit because the csproj sets <RuntimeIdentifier>win-x64</RuntimeIdentifier>
# which would otherwise cause the SDK to default to self-contained.
dotnet publish $projectPath `
    --configuration Release `
    --no-self-contained `
    --output $publishDir `
    --nologo
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Zipping output..."
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path "$publishDir\*" -DestinationPath $zipPath

try {
    az account show --output none 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Logging in to Azure..."
        az login --output none
        if ($LASTEXITCODE -ne 0) { throw "az login failed" }
    }

    $accounts = az account list --query "[].{Name:name, Id:id}" -o json | ConvertFrom-Json
    if ($accounts.Count -eq 0) { throw "No subscriptions found." }

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
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription" }

    Write-Host "Reading web app name from deployment output..."
    $webAppName = az deployment sub show `
        --name $deploymentName `
        --query properties.outputs.webAppName.value `
        --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $webAppName) { throw "Could not read webAppName from deployment '$deploymentName'. Run provision.ps1 first." }

    Write-Host "Deploying to $webAppName..."
    # WEBSITE_RUN_FROM_PACKAGE=1 is set in Bicep — app runs directly from the mounted zip.
    az webapp deploy `
        --resource-group $resourceGroup `
        --name           $webAppName `
        --src-path       (Resolve-Path $zipPath) `
        --type           zip `
        --async          false
    if ($LASTEXITCODE -ne 0) { throw "Deployment failed" }

    Write-Host ""
    Write-Host "Publish succeeded." -ForegroundColor Green
    Write-Host "  URL : https://$webAppName.azurewebsites.net"
} finally {
    Write-Host "Cleaning up build artefacts..."
    if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }
    if (Test-Path $zipPath)    { Remove-Item $zipPath -Force }
}
