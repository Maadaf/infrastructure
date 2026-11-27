#Requires -Version 5.1
<#
.SYNOPSIS
  Smoke E2E lab: simulador (central) → vehicle-tracker → edge-uploader → central-api.

.DESCRIPTION
  Assume stacks central + lab já up, ou corre com -Up.
  Sai 0 quando o central recebe pelo menos uma passagem nova com evidência
  s3://freeflow-central/... e o JPEG materializado é válido.
  mock-central-api foi retirado — smoke contra o central real.
  -Demo: auth no simulador + CENTRAL_AUTH_TOKEN no central/EU.

.EXAMPLE
  cd "D:\Tracevia Brasil\Free Flow\SW\infrastructure"
  .\lab\smoke.ps1 -Up

.EXAMPLE
  .\lab\smoke.ps1 -Up -Demo
#>
param(
    [switch]$Up,
    [switch]$Demo,
    [int]$TimeoutSeconds = 240,
    [string]$Scenario = "scenario-lab.yaml",
    [double]$TimeScale = 40,
    [int]$Seed = 42,
    [string]$OperatorToken = "",
    [string]$CentralToken = ""
)

$ErrorActionPreference = "Stop"
$infraRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $infraRoot

function Read-EnvFile([string]$Path) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        $parts = $line.Split("=", 2)
        if ($parts.Count -eq 2) {
            $map[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
    return $map
}

function Ensure-Network([string]$Name) {
    $existing = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $Name }
    if (-not $existing) {
        docker network create $Name | Out-Null
    }
}

function Wait-HttpOk([string]$Url, [int]$Seconds, [hashtable]$Headers = $null) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $params = @{
                Uri = $Url
                Method = "Get"
                TimeoutSec = 3
                UseBasicParsing = $true
            }
            if ($Headers) { $params["Headers"] = $Headers }
            $response = Invoke-WebRequest @params
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                return
            }
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    throw "Timeout à espera de $Url"
}

function Get-AuthHeaders([string]$Token) {
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    return @{ Authorization = "Bearer $Token" }
}

if ($Demo) {
    $envFile = Join-Path $infraRoot ".env.demo.auth"
    if (-not (Test-Path -LiteralPath $envFile)) {
        Write-Error "Demo auth: falta $envFile (copie de .env.demo.auth.example)"
        exit 1
    }
    $demoEnv = Read-EnvFile $envFile
    if (-not $OperatorToken) { $OperatorToken = [string]$demoEnv["FREEFLOW_OPERATOR_TOKEN"] }
    if (-not $CentralToken) { $CentralToken = [string]$demoEnv["CENTRAL_AUTH_TOKEN"] }
    # Compat: ficheiros antigos ainda com MCA_AUTH_TOKEN
    if (-not $CentralToken) { $CentralToken = [string]$demoEnv["MCA_AUTH_TOKEN"] }
    if (-not $OperatorToken -or -not $CentralToken) {
        Write-Error "Demo auth: FREEFLOW_OPERATOR_TOKEN e CENTRAL_AUTH_TOKEN são obrigatórios em .env.demo.auth"
        exit 1
    }
}

if ($Up) {
    Ensure-Network "freeflow_default"
    Ensure-Network "freeflow_central"
    if ($Demo) {
        Write-Host ">> docker compose -f compose.central.yaml -f compose.demo.yaml --env-file .env.demo.auth up -d --build"
        docker compose -f compose.central.yaml -f compose.demo.yaml --env-file .env.demo.auth up -d --build
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Write-Host ">> docker compose -f compose.lab.yaml --env-file .env.demo.auth up -d --build"
        docker compose -f compose.lab.yaml --env-file .env.demo.auth up -d --build
    } else {
        Write-Host ">> docker compose -f compose.central.yaml up -d --build"
        docker compose -f compose.central.yaml up -d --build
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Write-Host ">> docker compose -f compose.lab.yaml up -d --build"
        docker compose -f compose.lab.yaml up -d --build
    }
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# Lab E2E sem equipamentos: gateways órfãos (compose.full / hardware) poluem NATS.
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
        Write-Host ">> A parar gateway órfão $name (fora do lab E2E)"
        docker stop $name | Out-Null
    }
}

$simHeaders = Get-AuthHeaders $OperatorToken
$centralHeaders = Get-AuthHeaders $CentralToken

Write-Host ">> A aguardar serviços..."
Wait-HttpOk "http://127.0.0.1:8222/healthz" 90
Wait-HttpOk "http://127.0.0.1:8080/api/v1/status" 120 $simHeaders
Wait-HttpOk "http://127.0.0.1:8081/health/live" 120
Wait-HttpOk "http://127.0.0.1:8082/health/live" 120
Wait-HttpOk "http://127.0.0.1:8090/health/live" 120 $centralHeaders
Wait-HttpOk "http://127.0.0.1:8090/health/ready" 120 $centralHeaders
if ($Demo) {
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:8080/api/v1/status" -TimeoutSec 5 | Out-Null
        Write-Error "Demo auth: /api/v1/status aceitou pedido sem token"
        exit 1
    } catch {
        Write-Host ">> Auth simulador OK (401/403 sem token)"
    }
}

$baseline = 0
$knownPassageIds = @{}
try {
    $baseParams = @{
        Uri = "http://127.0.0.1:8090/v1/passages"
        TimeoutSec = 5
    }
    if ($centralHeaders) { $baseParams["Headers"] = $centralHeaders }
    $baseResponse = Invoke-RestMethod @baseParams
    if ($null -ne $baseResponse.count) { $baseline = [int]$baseResponse.count }
    foreach ($item in @($baseResponse.items)) {
        if ($null -ne $item.passage_id) { $knownPassageIds[[string]$item.passage_id] = $true }
    }
} catch {
    $baseline = 0
}
Write-Host ">> Central baseline count=$baseline known_passages=$($knownPassageIds.Count)"

$bodyObj = [ordered]@{
    scenario = $Scenario
    time_scale = $TimeScale
    materialize_evidence = $true
    seed = $Seed
}
$body = ($bodyObj | ConvertTo-Json -Compress)
$tmp = Join-Path $env:TEMP "freeflow-lab-smoke-start.json"
# UTF-8 sem BOM — o simulador rejeita JSON com BOM / aspas estragadas pelo PowerShell.
[System.IO.File]::WriteAllText($tmp, $body)

Write-Host ">> A iniciar cenário $Scenario (time_scale=$TimeScale seed=$Seed materialize_evidence=true)"
$curlArgs = @(
    "-sS", "-w", "`nHTTP_CODE:%{http_code}",
    "-X", "POST",
    "http://127.0.0.1:8080/api/v1/scenarios/start",
    "-H", "Content-Type: application/json",
    "--data-binary", "@$tmp"
)
if ($OperatorToken) {
    $curlArgs += @("-H", "Authorization: Bearer $OperatorToken")
}
$curlOut = & curl.exe @curlArgs
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
    Write-Host "Dicas: confirme que o simulador (compose.central) está up, MinIO healthy, e scenario-lab.yaml montado."
    exit 1
}
Write-Host ">> Cenário aceite (HTTP $httpCode): $bodyOut"

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$chosen = $null
$centralUri = $null
$poll = 0
while ((Get-Date) -lt $deadline) {
    $poll++
    try {
        $params = @{
            Uri = "http://127.0.0.1:8090/v1/passages"
            TimeoutSec = 5
        }
        if ($centralHeaders) { $params["Headers"] = $centralHeaders }
        $response = Invoke-RestMethod @params
        $count = 0
        if ($null -ne $response.count) { $count = [int]$response.count }
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
            $simParams = @{
                Uri = "http://127.0.0.1:8080/api/v1/status"
                TimeoutSec = 3
            }
            if ($simHeaders) { $simParams["Headers"] = $simHeaders }
            $sim = Invoke-RestMethod @simParams
            Write-Host (">> A aguardar central s3://freeflow-central... poll={0} count={1} baseline={2} sim_state={3} published={4}/{5}" -f `
                $poll, $count, $baseline, $sim.state, $sim.published_events, $sim.total_events)
        }
    } catch {
        if (($poll % 5) -eq 0) {
            Write-Host ">> A aguardar central s3://freeflow-central... poll=$poll (central ainda indisponível)"
        }
    }
    Start-Sleep -Seconds 2
}

if ($null -eq $chosen) {
    Write-Error "E2E falhou: central sem passagem nova com evidência s3://freeflow-central/ após ${TimeoutSeconds}s (baseline=$baseline)"
    Write-Host "Dicas: pare gateways órfãos; docker compose -f compose.central.yaml logs central-api simulator --tail 80"
    Write-Host "       docker compose -f compose.lab.yaml logs vehicle-tracker edge-uploader --tail 80"
    exit 1
}

Write-Host ">> Evidência no central: uri=$centralUri"

# JPEG real via API central
$passageId = [string]$chosen.passage_id
$evidenceId = $null
foreach ($ev in @($chosen.passage.evidence)) {
    if ([string]$ev.uri -like "s3://freeflow-central/*") {
        $evidenceId = [string]$ev.evidence_id
        break
    }
}
if (-not $evidenceId) {
    Write-Error "E2E falhou: sem evidence_id com URI central"
    exit 1
}

$jpegPath = Join-Path $env:TEMP ("freeflow-lab-evidence-{0}.jpg" -f $passageId)
$evidenceCurl = @(
    "-sS", "-f", "-o", $jpegPath,
    ("http://127.0.0.1:8090/api/v1/evidence/{0}/{1}" -f $passageId, $evidenceId)
)
if ($CentralToken) {
    $evidenceCurl += @("-H", "Authorization: Bearer $CentralToken")
}
& curl.exe @evidenceCurl
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $jpegPath)) {
    Write-Error "E2E falhou: não foi possível obter JPEG de /api/v1/evidence/$passageId/$evidenceId"
    exit 1
}
$bytes = [System.IO.File]::ReadAllBytes($jpegPath)
if ($bytes.Length -lt 100 -or $bytes[0] -ne 0xFF -or $bytes[1] -ne 0xD8 -or $bytes[2] -ne 0xFF) {
    Write-Error "E2E falhou: evidência não é JPEG válido (len=$($bytes.Length))"
    exit 1
}
Write-Host ">> JPEG central OK: passage_id=$passageId bytes=$($bytes.Length) magic=FFD8FF"

Write-Host "OK E2E lab: central passage_id=$passageId evidence=$centralUri jpeg_bytes=$($bytes.Length)"
exit 0
