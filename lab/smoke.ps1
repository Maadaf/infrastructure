#Requires -Version 5.1
<#
.SYNOPSIS
  Smoke E2E lab: simulador → vehicle-tracker → edge-uploader → mock-central.

.DESCRIPTION
  Assume que `docker compose -f compose.lab.yaml up -d --build` já correu
  (ou corre com -Up). Sai 0 quando o mock-central tem pelo menos uma passagem.

.EXAMPLE
  cd "D:\Tracevia Brasil\Free Flow\SW\infrastructure"
  docker compose -f compose.lab.yaml up -d --build
  .\lab\smoke.ps1
#>
param(
    [switch]$Up,
    [int]$TimeoutSeconds = 180,
    [string]$Scenario = "scenario-lab.yaml",
    [double]$TimeScale = 40
)

$ErrorActionPreference = "Stop"
$infraRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $infraRoot

if ($Up) {
    Write-Host ">> docker compose -f compose.lab.yaml up -d --build"
    docker compose -f compose.lab.yaml up -d --build
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
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

Write-Host ">> A aguardar serviços..."
Wait-HttpOk "http://127.0.0.1:8222/healthz" 90
Wait-HttpOk "http://127.0.0.1:8080/api/v1/status" 120
Wait-HttpOk "http://127.0.0.1:8081/health/live" 120
Wait-HttpOk "http://127.0.0.1:8082/health/live" 120
Wait-HttpOk "http://127.0.0.1:8090/health/live" 60

$body = @{
    scenario = $Scenario
    time_scale = $TimeScale
    materialize_evidence = $false
} | ConvertTo-Json

Write-Host ">> A iniciar cenário $Scenario (time_scale=$TimeScale)"
Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8080/api/v1/scenarios/start" `
    -ContentType "application/json" -Body $body | Out-Null

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$items = @()
while ((Get-Date) -lt $deadline) {
    try {
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:8090/v1/passages" -TimeoutSec 5
        if ($null -ne $response.count -and [int]$response.count -ge 1) {
            $items = @($response.items)
            break
        }
    } catch {
        # retry
    }
    Start-Sleep -Seconds 2
}

if (@($items).Count -lt 1) {
    Write-Error "E2E falhou: mock-central sem passagens após ${TimeoutSeconds}s"
    Write-Host "Dicas: docker compose -f compose.lab.yaml logs vehicle-tracker edge-uploader mock-central-api simulator --tail 80"
    exit 1
}

$first = @($items)[0]
Write-Host "OK E2E lab: mock-central count=$(@($items).Count) passage_id=$($first.passage_id) status=$($first.status)"
exit 0
