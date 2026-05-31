# win-app-svc-url-cardinality-leak

Minimal ASP.NET Core 8 app reproducing a native memory leak in IIS in-process hosting on Windows Azure App Service — does not reproduce on Linux.

**Trigger:** Every request to a unique URL path leaks ~320 bytes of unmanaged memory per path segment, regardless of application code. The leak is in the IIS/Windows hosting layer, not in .NET.

---

## Prerequisites

- [.NET 8 SDK](https://dotnet.microsoft.com/download)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- PowerShell 7+
- An Azure subscription

---

## Deploy

### 1. Provision infrastructure

```powershell
.\deploy\provision.ps1
```

Creates a resource group, Premium V3 App Service plan, and web app. Safe to re-run (idempotent). You will be prompted to log in and select a subscription.

The default SKU is **P2v3**. Edit `$appServicePlanSku` in `provision.ps1` to change it.

### 2. Publish the app

```powershell
.\deploy\publish.ps1
```

Builds a framework-dependent win-x64 release, zips it, and deploys via `az webapp deploy`.

---

## Reproduce the leak

```powershell
.\test\load-test.ps1 -BaseUrl https://<your-app>.azurewebsites.net
```

| Parameter | Default | Description |
|---|---|---|
| `-BaseUrl` | *(required)* | App Service URL |
| `-Concurrency` | `200` | Parallel workers |
| `-SegmentCount` | `35` | Path segments per request — each leaks one native block |
| `-DurationSec` | `0` | Run duration in seconds; `0` = run until Ctrl+C |

The script prints req/s, error count, and private bytes every 5 seconds:

```
[00:30]   312.4 req/s | requests=     1562 err=     0 | private bytes=   184 MB
[01:00]   318.1 req/s | requests=     3153 err=     0 | private bytes=   271 MB
```

### What to watch

**Azure Portal → App Service → Monitoring → Metrics → Private Bytes (Max, 1-min)**

You should see a steady, linear climb that does not plateau. Stop the load test and observe that private bytes do not drop — confirming unmanaged memory that is never reclaimed.

---

## How the leak works

Each request URL has the shape `/{guid}/{rand}/{rand}/...` — the GUID at depth 1 ensures every prefix chain is globally unique. The hosting layer allocates a native block for each URL prefix level and does not free them. With 35 segments per request and 200 concurrent workers, native memory grows at roughly 15–20 KB/request.

The application code itself (`Program.cs`) is intentionally trivial — a catch-all route that returns 200 OK — to rule out any application-level cause.
