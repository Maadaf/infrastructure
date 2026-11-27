#Requires -Version 5.1
<#
.SYNOPSIS
  Smoke: pórtico (lab) → edge-uploader → central-api (Postgres + MinIO).
  Simulador sobe com o stack central (compose.central.yaml).

.DESCRIPTION
  Sobe o stack central (se -Up), sobe o lab apontado ao central-api,
  materializa evidência e confirma que a passagem e o blob estão no central.
  mock-central-api foi retirado.

.EXAMPLE
  cd "D:\Tracevia Brasil\Free Flow\SW\infrastructure"
  .\lab\smoke-central.ps1 -Up
#>
param(
    [switch]$Up,
    [int]$TimeoutSeconds = 240,
    [string]$Scenario = "scenario-lab.yaml",
    [double]$TimeScale = 40,
    [int]$Seed = 42
)

$ErrorActionPreference = "Stop"
$infraRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $infraRoot

function Wait-HttpOk([string]$Url, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 3 -UseBasicParsing
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) { return }
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    throw "Timeout à espera de $Url"
}

function Ensure-Network([string]$Name) {
    $existing = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $Name }
    if (-not $existing) {
        docker network create $Name | Out-Null
    }
}

if ($Up) {
    Ensure-Network "freeflow_default"
    Ensure-Network "freeflow_central"

    Write-Host ">> docker compose -f compose.central.yaml up -d --build"
    docker compose -f compose.central.yaml up -d --build
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host ">> docker compose -f compose.lab.yaml up -d --build"
    docker compose -f compose.lab.yaml up -d --build
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$orphanGateways = @(
    "freeflow-camera-gateway-1",
    "freeflow-lidar-gateway-1",
    "freeflow-radar-gateway-1",
    "freeflow-rfid-gateway-1",
    "freeflow-wim-gateway-1"
)
foreach ($name in $orphanGateways) {
    $id = docker ps -q -f "name=$name" 2>$null
    if ($id) {
        Write-Host ">> A parar gateway órfão $name"
        docker stop $name | Out-Null
    }
}

Write-Host ">> A aguardar serviços..."
Wait-HttpOk "http://127.0.0.1:8222/healthz" 90
Wait-HttpOk "http://127.0.0.1:8080/api/v1/status" 120
Wait-HttpOk "http://127.0.0.1:8081/health/live" 120
Wait-HttpOk "http://127.0.0.1:8082/health/live" 120
Wait-HttpOk "http://127.0.0.1:8090/health/live" 120
Wait-HttpOk "http://127.0.0.1:8090/health/ready" 120

$baseline = 0
$knownPassageIds = @{}
try {
    $baseResponse = Invoke-RestMethod -Uri "http://127.0.0.1:8090/v1/passages" -TimeoutSec 5
    if ($null -ne $baseResponse.count) { $baseline = [int]$baseResponse.count }
    foreach ($item in @($baseResponse.items)) {
        if ($null -ne $item.passage_id) { $knownPassageIds[[string]$item.passage_id] = $true }
    }
} catch {
    $baseline = 0
}
Write-Host ">> Central baseline count=$baseline known=$($knownPassageIds.Count)"

$bodyObj = [ordered]@{
    scenario = $Scenario
    time_scale = $TimeScale
    materialize_evidence = $true
    seed = $Seed
}
$body = ($bodyObj | ConvertTo-Json -Compress)
$tmp = Join-Path $env:TEMP "freeflow-central-smoke-start.json"
[System.IO.File]::WriteAllText($tmp, $body)

Write-Host ">> POST cenário lab materialize_evidence=true"
$curlOut = & curl.exe -sS -w "`nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:8080/api/v1/scenarios/start" `
    -H "Content-Type: application/json" --data-binary "@$tmp"
$curlText = [string]$curlOut
$codeMatch = [regex]::Match($curlText, "HTTP_CODE:(\d+)\s*$")
$httpCode = if ($codeMatch.Success) { [int]$codeMatch.Groups[1].Value } else { 0 }
if ($httpCode -lt 200 -or $httpCode -ge 300) {
    Write-Error "POST /scenarios/start falhou (HTTP $httpCode): $curlText"
    exit 1
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$chosen = $null
$centralUri = $null
$poll = 0
while ((Get-Date) -lt $deadline) {
    $poll++
    try {
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:8090/v1/passages" -TimeoutSec 5
        $candidates = @($response.items) | Where-Object {
            $null -ne $_.passage_id -and -not $knownPassageIds.ContainsKey([string]$_.passage_id)
        } | Sort-Object { $_.confirmed_at } -Descending
        foreach ($item in $candidates) {
            $evidence = @()
            if ($null -ne $item.passage -and $null -ne $item.passage.evidence) {
                $evidence = @($item.passage.evidence)
            }
            $hit = @($evidence | Where-Object { $_.uri -like "s3://freeflow-central/*" })
            $blobs = 0
            if ($null -ne $item.evidence_blob_count) { $blobs = [int]$item.evidence_blob_count }
            if ($hit.Count -ge 1 -and $blobs -ge 1) {
                $chosen = $item
                $centralUri = [string]$hit[0].uri
                break
            }
        }
        if ($null -ne $chosen) { break }
        if (($poll % 5) -eq 0) {
            Write-Host (">> A aguardar central s3://freeflow-central... poll={0} count={1}" -f $poll, $response.count)
        }
    } catch {
        if (($poll % 5) -eq 0) {
            Write-Host ">> A aguardar central... poll=$poll"
        }
    }
    Start-Sleep -Seconds 2
}

if ($null -eq $chosen) {
    Write-Error "Smoke central falhou: sem passagem nova com blob em s3://freeflow-central/ após ${TimeoutSeconds}s"
    Write-Host "Dicas: docker compose -f compose.central.yaml logs central-api simulator --tail 80"
    Write-Host "       docker compose -f compose.lab.yaml logs edge-uploader vehicle-tracker --tail 80"
    exit 1
}

# Confirmar objecto no MinIO central via API (lista evidências / get bytes path).
$passageId = [string]$chosen.passage_id
$ops = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/v1/passages/$passageId" -TimeoutSec 5
if (-not $ops.evidenceMinio -or ($ops.evidenceMinio -notlike "s3://freeflow-central/*")) {
    Write-Error "Smoke central falhou: ops passage sem evidenceMinio central ($($ops.evidenceMinio))"
    exit 1
}

$evidenceId = $null
foreach ($ev in @($chosen.passage.evidence)) {
    if ([string]$ev.uri -like "s3://freeflow-central/*") {
        $evidenceId = [string]$ev.evidence_id
        break
    }
}
if (-not $evidenceId) {
    Write-Error "Smoke central falhou: sem evidence_id com URI central"
    exit 1
}

$jpegPath = Join-Path $env:TEMP ("freeflow-central-evidence-{0}.jpg" -f $passageId)
& curl.exe -sS -f -o $jpegPath ("http://127.0.0.1:8090/api/v1/evidence/{0}/{1}" -f $passageId, $evidenceId)
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $jpegPath)) {
    Write-Error "Smoke central falhou: GET evidência central HTTP"
    exit 1
}
$bytes = [System.IO.File]::ReadAllBytes($jpegPath)
if ($bytes.Length -lt 100 -or $bytes[0] -ne 0xFF -or $bytes[1] -ne 0xD8 -or $bytes[2] -ne 0xFF) {
    Write-Error "Smoke central falhou: blob central não é JPEG (len=$($bytes.Length))"
    exit 1
}

Write-Host "OK E2E central: passage_id=$passageId evidence=$centralUri jpeg_bytes=$($bytes.Length) blobs=$($chosen.evidence_blob_count)"
exit 0
