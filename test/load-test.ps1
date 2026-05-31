# IIS in-process native request-context leak driver.
#
# Sends GET requests with deep random URL paths. IIS allocates one native
# request-context block per URL-prefix level and leaks them all under
# ASP.NET Core IIS in-process hosting on Windows.
#
#   URL shape : /{guid}/{r0}/{r1}/.../{rN-1}
#   GUID at depth 1 → every prefix in the chain is unique per request
#   Each segment → one leaked ~320-byte native block
#
# Watch in Azure Portal:
#   App Service → <name> → Monitoring → Metrics → Private Bytes (Max, 1-min)

param(
    [Parameter(Mandatory)]
    [string] $BaseUrl,
    [int]    $Concurrency  = 200,
    [int]    $SegmentCount = 35,    # path segments per request; each leaks one block
                                    # keep ≤ 50 to stay within HTTP.SYS segment limits
    [int]    $DurationSec  = 0      # 0 = run until Ctrl+C
)

Write-Host "Target      : $BaseUrl/{guid}/{rand}x$($SegmentCount - 1)"
Write-Host "Segments    : $SegmentCount  (~$SegmentCount leaked blocks/request)"
Write-Host "Concurrency : $Concurrency workers"
Write-Host "Duration    : $(if ($DurationSec -le 0) { 'indefinite (Ctrl+C to stop)' } else { "$DurationSec s" })"
Write-Host ""

try {
    $null = Invoke-WebRequest $BaseUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    Write-Host "App is up." -ForegroundColor Green
} catch {
    Write-Error "App did not respond at $BaseUrl`n$_"
    exit 1
}

Write-Host ""
Write-Host "Starting load test. Ctrl+C to stop." -ForegroundColor Cyan
Write-Host "Watch Private Bytes: Azure Portal → Metrics → Private Bytes (Max, 1-min)"
Write-Host ""

$shared = [hashtable]::Synchronized(@{ ok = 0L; err = 0L })
$cts = if ($DurationSec -le 0) {
    [System.Threading.CancellationTokenSource]::new()
} else {
    [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($DurationSec))
}

$parallelJob = 1..$Concurrency | ForEach-Object -Parallel {
    $sh       = $using:shared
    $baseUrl  = $using:BaseUrl
    $segCount = $using:SegmentCount
    $token    = ($using:cts).Token

    $client         = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $rng            = [System.Random]::new()

    try {
        while (-not $token.IsCancellationRequested) {
            $url = "$baseUrl/$([System.Guid]::NewGuid().ToString('N'))"
            for ($i = 1; $i -lt $segCount; $i++) {
                $url += '/' + $rng.Next(0x10000).ToString('x4')
            }

            try {
                $resp = $client.GetAsync($url, $token).GetAwaiter().GetResult()
                $resp.Dispose()
                $sh.ok++
            } catch [System.OperationCanceledException] {
                break
            } catch {
                $sh.err++
            }
        }
    } finally {
        $client.Dispose()
    }
} -ThrottleLimit $Concurrency -AsJob

$startTime   = [DateTime]::UtcNow
$lastOk      = 0L
$probeClient = [System.Net.Http.HttpClient]::new()
$probeClient.Timeout = [TimeSpan]::FromSeconds(5)

try {
    while ($parallelJob.State -in 'NotStarted', 'Running') {
        Start-Sleep -Seconds 5
        $nowOk   = $shared.ok
        $nowErr  = $shared.err
        $elapsed = ([DateTime]::UtcNow - $startTime).TotalSeconds
        $rps     = [Math]::Round(($nowOk - $lastOk) / 5, 1)

        $privateMB = '?'
        try {
            $r = $probeClient.GetAsync($BaseUrl).GetAwaiter().GetResult()
            $vals = $null
            if ($r.Headers.TryGetValues('X-Private-Bytes-MB', [ref]$vals)) {
                $privateMB = $vals | Select-Object -First 1
            }
            $r.Dispose()
        } catch { }

        Write-Host ("[{0:mm\:ss}] {1,7:F1} req/s | requests={2,10} err={3,6} | private bytes={4,6} MB" -f `
            [TimeSpan]::FromSeconds($elapsed), $rps, $nowOk, $nowErr, $privateMB)
        $lastOk = $nowOk
    }
} finally {
    $cts.Cancel()
    $probeClient.Dispose()
    $parallelJob | Stop-Job -PassThru | Remove-Job -Force

    $elapsed = ([DateTime]::UtcNow - $startTime).TotalSeconds
    $finalOk = $shared.ok

    Write-Host ""
    Write-Host "Load test complete." -ForegroundColor Green
    Write-Host ("  Duration  : {0:F0} s"    -f $elapsed)
    Write-Host ("  Requests  : {0} ok   {1} err" -f $finalOk, $shared.err)
    Write-Host ("  Avg req/s : {0:F1}"      -f ($finalOk / [Math]::Max($elapsed, 1)))
    Write-Host ""
    Write-Host "Steady climb in Private Bytes confirms the leak." -ForegroundColor Yellow
}
