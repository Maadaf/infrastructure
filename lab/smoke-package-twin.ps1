# Vertical slice: package → central → list → twin replay.
# Prefere pacote já ingerido; se vazio, faz seed via PUT /v1/packages.
param(
  [string]$Central = "http://127.0.0.1:8090",
  [string]$Twin = "http://127.0.0.1:8080"
)

$ErrorActionPreference = "Stop"

function Get-Json($url) {
  Invoke-RestMethod -Uri $url -Method GET
}

Write-Host "== packages =="
# Always upsert lab fixture so aferição gets ANPR crops + 10s videos + WIM/LiDAR/radar.
$fixturePath = Join-Path $PSScriptRoot "..\..\freeflow-contracts\fixtures\v1\passages\evidence_package.json"
$body = Get-Content -LiteralPath $fixturePath -Raw -Encoding utf8
$pkg = $body | ConvertFrom-Json
Write-Host "Upserting lab package fixture $($pkg.package_id) (ANPR /lab crops + lateral/overview MP4 + WIM/LiDAR)"
Invoke-RestMethod -Method PUT -Uri "$Central/v1/packages/$($pkg.package_id)" `
  -ContentType "application/json; charset=utf-8" -Body $body | Out-Null
$lostPath = Join-Path $PSScriptRoot "..\..\freeflow-contracts\fixtures\v1\passages\lost_package.json"
if (Test-Path -LiteralPath $lostPath) {
  $lostBody = Get-Content -LiteralPath $lostPath -Raw -Encoding utf8
  try {
    Invoke-RestMethod -Method POST -Uri "$Central/v1/lost-packages" `
      -ContentType "application/json; charset=utf-8" -Body $lostBody | Out-Null
  } catch {
    Write-Host "lost-package seed skipped (maybe already present)"
  }
}
$list = Get-Json "$Central/api/v1/packages?limit=5"

$first = $list.items[0]
Write-Host "OK package=$($first.id) gantry=$($first.gantryId) overall=$($first.overallConfidence)"

Write-Host "== lost =="
$lost = Get-Json "$Central/api/v1/lost-packages?limit=5"
Write-Host "OK lost_count=$($lost.count)"

Write-Host "== twin replay (direct) =="
# Use raw JSON from central so nested events stay intact (PS ConvertFrom-Json mangles them).
$detailRaw = (Invoke-WebRequest -Uri "$Central/api/v1/packages/$($first.id)" -UseBasicParsing).Content
$detailObj = $detailRaw | ConvertFrom-Json
$eventsJson = if ($null -ne $detailObj.events) {
  ($detailObj.events | ConvertTo-Json -Depth 12 -Compress)
} else { "[]" }
if ($eventsJson -and -not $eventsJson.StartsWith("[")) { $eventsJson = "[$eventsJson]" }
$replayBody = @"
{"package_id":"$($first.id)","events":$eventsJson,"config_overrides":{"window_seconds":12,"speed_tolerance_kmh":25,"min_confidence":0.4,"ambiguity_margin":0.1}}
"@
$twinRaw = (Invoke-WebRequest -Method POST -Uri "$Twin/api/v1/twin/replay" `
  -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($replayBody)) `
  -UseBasicParsing).Content
Write-Host "OK twin raw=$twinRaw"

Write-Host "== central proxy replay =="
$proxyBody = @{ config_overrides = @{ window_seconds = 14; speed_tolerance_kmh = 18; min_confidence = 0.45; ambiguity_margin = 0.1 } } | ConvertTo-Json
$proxy = Invoke-RestMethod -Method POST -Uri "$Central/api/v1/packages/$($first.id)/replay" `
  -ContentType "application/json; charset=utf-8" `
  -Body $proxyBody
$proxyOverall = $proxy.overall_confidence
$proxyMode = $proxy.mode
Write-Host "OK proxy overall=$proxyOverall mode=$proxyMode"

Write-Host "OK E2E package-twin slice"
Write-Host "UI afericao: http://127.0.0.1:8089/afericao"
Write-Host "UI perdidos: http://127.0.0.1:8089/perdidos"
