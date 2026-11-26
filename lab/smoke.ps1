#Requires -Version 5.1
<#
.SYNOPSIS
  Smoke E2E lab: simulador → vehicle-tracker → edge-uploader → mock-central.

.DESCRIPTION
  Assume que `docker compose -f compose.lab.yaml up -d --build` já correu
  (ou corre com -Up). Sai 0 quando o mock-central recebe pelo menos uma
  passagem nova. Camera-gateway não faz parte do lab; se estiver a correr
  como órfão do compose principal, este script para-o.

.EXAMPLE
  cd "D:\Tracevia Brasil\Free Flow\SW\infrastructure"
  docker compose -f compose.lab.yaml up -d --build
  .\lab\smoke.ps1
#>
param(
    [switch]$Up,
    [int]$TimeoutSeconds = 180,
    [string]$Scenario = "scenario-lab.yaml",
    [double]$TimeScale = 40,
    [int]$Seed = 42
)

$ErrorActionPreference = "Stop"
$infraRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $infraRoot

if ($Up) {
    Write-Host ">> docker compose -f compose.lab.yaml up -d --build"
    docker compose -f compose.lab.yaml up -d --build
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# Lab E2E sem equipamentos: camera-gateway a apontar para host NATS só gera ruído.
$cg = docker ps -q -f "name=freeflow-camera-gateway" 2>$null
if ($cg) {
    Write-Host ">> A parar camera-gateway (fora do lab E2E sem câmara)"
    docker stop freeflow-camera-gateway-1 | Out-Null
}

function Wait-HttpOk([string]$Url, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 3 -UseBasicParsing
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                return
            }
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    throw "Timeout à espera de $Url"
}

function Get-MockCount {
    try {
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:8090/v1/passages" -TimeoutSec 5
        if ($null -eq $response.count) { return 0 }
        return [int]$response.count
    } catch {
        return -1
    }
}

Write-Host ">> A aguardar serviços..."
Wait-HttpOk "http://127.0.0.1:8222/healthz" 90
Wait-HttpOk "http://127.0.0.1:8080/api/v1/status" 120
Wait-HttpOk "http://127.0.0.1:8081/health/live" 120
Wait-HttpOk "http://127.0.0.1:8082/health/live" 120
Wait-HttpOk "http://127.0.0.1:8090/health/live" 60

$baseline = Get-MockCount
if ($baseline -lt 0) { $baseline = 0 }
Write-Host ">> Mock baseline count=$baseline"

$bodyObj = [ordered]@{
    scenario = $Scenario
    time_scale = $TimeScale
    materialize_evidence = $false
    seed = $Seed
}
$body = ($bodyObj | ConvertTo-Json -Compress)
$tmp = Join-Path $env:TEMP "freeflow-lab-smoke-start.json"
# UTF-8 sem BOM — o simulador rejeita JSON com BOM / aspas estragadas pelo PowerShell.
[System.IO.File]::WriteAllText($tmp, $body)

Write-Host ">> A iniciar cenário $Scenario (time_scale=$TimeScale seed=$Seed)"
$curlOut = & curl.exe -sS -w "`nHTTP_CODE:%{http_code}" -X POST `
    "http://127.0.0.1:8080/api/v1/scenarios/start" `
    -H "Content-Type: application/json" `
    --data-binary "@$tmp"
$curlText = [string]$curlOut
$codeMatch = [regex]::Match($curlText, "HTTP_CODE:(\d+)\s*$")
$httpCode = if ($codeMatch.Success) { [int]$codeMatch.Groups[1].Value } else { 0 }
if ($codeMatch.Success -and $codeMatch.Index -gt 0) {
    $bodyOut = $curlText.Substring(0, $codeMatch.Index).Trim()
} else {
    $bodyOut = $curlText
}

if ($httpCode -lt 200 -or $httpCode -ge 300) {
    Write-Error "POST /scenarios/start falhou (HTTP $httpCode): $bodyOut"
    Write-Host "Dicas: confirme que o simulador está up e que scenario-lab.yaml está montado."
    exit 1
}
Write-Host ">> Cenário aceite (HTTP $httpCode): $bodyOut"

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$items = @()
$poll = 0
while ((Get-Date) -lt $deadline) {
    $poll++
    try {
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:8090/v1/passages" -TimeoutSec 5
        $count = 0
        if ($null -ne $response.count) { $count = [int]$response.count }
        if ($count -gt $baseline) {
            $items = @($response.items)
            break
        }
        if (($poll % 5) -eq 0) {
            $sim = Invoke-RestMethod -Uri "http://127.0.0.1:8080/api/v1/status" -TimeoutSec 3
            Write-Host (">> A aguardar mock... poll={0} mock_count={1} baseline={2} sim_state={3} published={4}/{5}" -f `
                $poll, $count, $baseline, $sim.state, $sim.published_events, $sim.total_events)
        }
    } catch {
        if (($poll % 5) -eq 0) {
            Write-Host ">> A aguardar mock... poll=$poll (mock ainda indisponível)"
        }
    }
    Start-Sleep -Seconds 2
}

if (@($items).Count -lt 1) {
    Write-Error "E2E falhou: mock-central sem passagens novas após ${TimeoutSeconds}s (baseline=$baseline)"
    Write-Host "Dicas: docker compose -f compose.lab.yaml logs vehicle-tracker edge-uploader mock-central-api simulator --tail 80"
    exit 1
}

$newest = @($items) | Sort-Object { $_.confirmed_at } | Select-Object -Last 1
Write-Host "OK E2E lab: mock-central count=$(@($items).Count) passage_id=$($newest.passage_id) status=$($newest.status)"
exit 0
