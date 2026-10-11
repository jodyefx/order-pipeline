<#
.SYNOPSIS
  End-to-end smoke tests for the order pipeline against local Docker infrastructure.

.DESCRIPTION
  1. Starts docker compose (SQL Server, Service Bus emulator, Azurite) and waits until healthy.
  2. Starts the Functions host with `dotnet run` unless one is already listening on -BaseUrl.
  3. Sends test orders and checks both the HTTP response and what landed on the queue.
  4. Stops the Functions host if this script started it (containers are left running).

.EXAMPLE
  .\tests\smoke\Run-SmokeTests.ps1
#>
param(
    [string]$BaseUrl = "http://localhost:7071"
)

$ErrorActionPreference = "Stop"
$repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
$funcProj   = Join-Path $repoRoot "src\OrderPipeline.Functions"
$peekScript = Join-Path $PSScriptRoot "peek-queue.cs"
$hostLog    = Join-Path $PSScriptRoot "functions-host.log"
$script:passed = 0
$script:failed = 0

function Write-Step($text) { Write-Host "`n== $text ==" -ForegroundColor Cyan }

function Assert($name, [bool]$condition, $detail = "") {
    if ($condition) { $script:passed++; Write-Host "  PASS  $name" -ForegroundColor Green }
    else            { $script:failed++; Write-Host "  FAIL  $name  $detail" -ForegroundColor Red }
}

function Test-Url($url) {
    try { Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 3 | Out-Null; return $true } catch { return $false }
}

function Wait-Until($what, [scriptblock]$check, [int]$timeoutSec = 180) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while (-not (& $check)) {
        if ((Get-Date) -gt $deadline) { throw "Timed out after ${timeoutSec}s waiting for $what" }
        Start-Sleep -Seconds 2
    }
}

# Sends a POST and returns @{ Status = <int>; Body = <parsed JSON or $null>; Raw = <string> }.
# Windows PowerShell throws on 4xx/5xx, so the error response is read back out of the exception.
function Send-Order([string]$body) {
    try {
        $r = Invoke-WebRequest "$BaseUrl/api/orders" -Method Post -Body $body -ContentType "application/json" -UseBasicParsing
        $status = [int]$r.StatusCode; $raw = $r.Content
    } catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { throw }
        $status = [int]$resp.StatusCode
        $raw = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
    }
    $parsed = $null
    if ($raw) { try { $parsed = $raw | ConvertFrom-Json } catch {} }
    return @{ Status = $status; Body = $parsed; Raw = $raw }
}

# Returns the queued message (parsed) for a MessageId, or $null if it's not on the queue.
function Find-QueuedMessage([string]$messageId) {
    # Windows PowerShell turns redirected native stderr into errors, so don't let them be fatal here.
    $ErrorActionPreference = "Continue"
    $out = & dotnet run $peekScript -- $messageId 2>$null
    if ($LASTEXITCODE -notin 0, 1) {
        throw "peek-queue.cs failed (exit $LASTEXITCODE). Run it directly to see why: dotnet run `"$peekScript`" -- $messageId"
    }
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out | Select-Object -Last 1) | ConvertFrom-Json
}

function Get-ErrorKeys($response) {
    if ($null -eq $response.Body -or $null -eq $response.Body.errors) { return @() }
    return @($response.Body.errors.PSObject.Properties.Name)
}

$startedHost = $null
try {
    # ---------------------------------------------------------------- infrastructure
    Write-Step "Starting Docker containers"
    if (-not (Test-Path (Join-Path $repoRoot ".env"))) {
        throw "Missing .env at repo root. Copy .env.example to .env and set MSSQL_SA_PASSWORD."
    }
    docker compose -f (Join-Path $repoRoot "docker-compose.yml") up -d
    if ($LASTEXITCODE -ne 0) { throw "docker compose up failed. Is Docker Desktop running?" }
    Wait-Until "Service Bus emulator" { Test-Url "http://localhost:5300/health" }
    Write-Host "  Service Bus emulator is healthy"

    Write-Step "Starting Functions host"
    if (Test-Url $BaseUrl) {
        Write-Host "  Already running at $BaseUrl; using it"
    } else {
        Write-Host "  dotnet run (log: $hostLog)"
        $port = ([uri]$BaseUrl).Port
        $startedHost = Start-Process dotnet -ArgumentList "run --no-launch-profile -- --port $port" -WorkingDirectory $funcProj `
            -RedirectStandardOutput $hostLog -RedirectStandardError "$hostLog.err" -PassThru -WindowStyle Hidden
        Wait-Until "Functions host at $BaseUrl" { Test-Url $BaseUrl }
        Write-Host "  Functions host is up"
    }

    Write-Host "  Warming up queue peek tool (first run compiles it)..."
    Find-QueuedMessage "warmup" | Out-Null

    # ---------------------------------------------------------------- test cases
    Write-Step "Valid order is accepted and published"
    $orderId = [guid]::NewGuid().ToString()
    $r = Send-Order (@{
        orderId    = $orderId
        customerId = "cust-42"
        items      = @(
            @{ sku = "WIDGET-1"; quantity = 2; unitPrice = 9.99 },
            @{ sku = "GADGET-7"; quantity = 1; unitPrice = 24.50 }
        )
    } | ConvertTo-Json -Depth 5)
    Assert "returns 202 Accepted" ($r.Status -eq 202) "got $($r.Status): $($r.Raw)"
    Assert "response echoes orderId" ($r.Body.orderId -eq $orderId) $r.Raw
    $msg = Find-QueuedMessage $orderId
    Assert "message is on the 'orders' queue with MessageId = orderId" ($null -ne $msg)
    if ($msg) {
        Assert "Subject is OrderSubmitted" ($msg.Subject -eq "OrderSubmitted") "got '$($msg.Subject)'"
        Assert "ContentType is application/json" ($msg.ContentType -eq "application/json") "got '$($msg.ContentType)'"
        Assert "total is computed (2 x 9.99 + 1 x 24.50 = 44.48)" ([decimal]$msg.Body.total -eq 44.48) "got $($msg.Body.total)"
        Assert "both line items carried over" (@($msg.Body.items).Count -eq 2) "got $(@($msg.Body.items).Count)"
    }

    Write-Step "Missing required fields are rejected"
    $r = Send-Order '{"customerId":"","items":[]}'
    $keys = Get-ErrorKeys $r
    Assert "returns 400 Bad Request" ($r.Status -eq 400) "got $($r.Status)"
    Assert "reports orderId error" ($keys -contains "orderId") "errors: $($keys -join ', ')"
    Assert "reports customerId error" ($keys -contains "customerId") "errors: $($keys -join ', ')"
    Assert "reports items error" ($keys -contains "items") "errors: $($keys -join ', ')"

    Write-Step "Bad line items are rejected and NOT published"
    $badId = [guid]::NewGuid().ToString()
    $r = Send-Order (@{
        orderId    = $badId
        customerId = "cust-42"
        items      = @(@{ sku = ""; quantity = 0; unitPrice = -1 })
    } | ConvertTo-Json -Depth 5)
    $keys = Get-ErrorKeys $r
    Assert "returns 400 Bad Request" ($r.Status -eq 400) "got $($r.Status)"
    Assert "reports items[0].sku" ($keys -contains "items[0].sku") "errors: $($keys -join ', ')"
    Assert "reports items[0].quantity" ($keys -contains "items[0].quantity") "errors: $($keys -join ', ')"
    Assert "reports items[0].unitPrice" ($keys -contains "items[0].unitPrice") "errors: $($keys -join ', ')"
    Assert "nothing published for the rejected order" ($null -eq (Find-QueuedMessage $badId))

    Write-Step "Field length limits are enforced"
    $r = Send-Order (@{
        orderId    = [guid]::NewGuid().ToString()
        customerId = ("x" * 65)
        items      = @(@{ sku = ("S" * 51); quantity = 1; unitPrice = 1 })
    } | ConvertTo-Json -Depth 5)
    $keys = Get-ErrorKeys $r
    Assert "returns 400 Bad Request" ($r.Status -eq 400) "got $($r.Status)"
    Assert "customerId over 64 chars rejected" ($keys -contains "customerId") "errors: $($keys -join ', ')"
    Assert "sku over 50 chars rejected" ($keys -contains "items[0].sku") "errors: $($keys -join ', ')"

    Write-Step "Malformed input is rejected"
    $r = Send-Order '{"orderId":'
    Assert "truncated JSON returns 400" ($r.Status -eq 400) "got $($r.Status)"
    $r = Send-Order ''
    Assert "empty body returns 400" ($r.Status -eq 400) "got $($r.Status)"
    $r = Send-Order '{"orderId":"not-a-guid","customerId":"c","items":[{"sku":"A","quantity":1,"unitPrice":1}]}'
    Assert "non-GUID orderId returns 400" ($r.Status -eq 400) "got $($r.Status)"
}
catch {
    $script:failed++
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($startedHost -and (Test-Path $hostLog)) {
        Write-Host "Last lines of the Functions host log:" -ForegroundColor Yellow
        Get-Content $hostLog -Tail 20
    }
}
finally {
    if ($startedHost) {
        # dotnet run spawns the func host as a child process, so kill the whole tree.
        taskkill /PID $startedHost.Id /T /F 2>&1 | Out-Null
        Write-Host "`n(stopped the Functions host this script started; containers left running)"
    }
}

Write-Host ""
$summary = "$($script:passed) passed, $($script:failed) failed"
if ($script:failed -eq 0) { Write-Host "ALL PASSED: $summary" -ForegroundColor Green; exit 0 }
else                      { Write-Host "FAILURES: $summary" -ForegroundColor Red; exit 1 }
