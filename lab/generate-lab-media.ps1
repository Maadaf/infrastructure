# Regenerates lab ANPR crops + ~10s lateral/overview MP4s from highway refs.
# Prefer Docker ffmpeg (jrottenberg/ffmpeg). Writes ops-ui/public/lab, copies fixtures, updates hashes.
param(
  [switch]$SkipVideos,
  [switch]$SkipImages,
  [switch]$PreferHostFfmpeg
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$labUi = Join-Path $root "ops-ui\public\lab"
$fixAnpr = Join-Path $PSScriptRoot "fixtures\anpr"
$fixVideo = Join-Path $PSScriptRoot "fixtures\video"
$genPy = Join-Path $PSScriptRoot "generate_anpr_crops.py"
$prepPy = Join-Path $PSScriptRoot "prepare_lab_video_assets.py"
$hashPy = Join-Path $PSScriptRoot "update_fixture_media_hashes.py"
$fonts = "C:\Windows\Fonts"
$plate = "ABC1D23"

New-Item -ItemType Directory -Force -Path $labUi, $fixAnpr, $fixVideo | Out-Null

if (-not $SkipImages) {
  Write-Host "== ANPR crops from real Mercosul photos ($plate) =="
  python $genPy --out $labUi
  if ($LASTEXITCODE -ne 0) { throw "ANPR crop generation failed" }
}

if (-not $SkipVideos) {
  Write-Host "== prepare video assets from refs (Pillow) =="
  python $prepPy --lab $labUi --ref-dir $fixVideo
  if ($LASTEXITCODE -ne 0) { throw "video asset prep failed" }

  Write-Host "== videos 10s (ffmpeg, prefer Docker) =="
  $genDir = Join-Path $labUi "_gen"
  $enc = @("-c:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", "high", "-level", "4.0", "-crf", "22", "-preset", "veryfast", "-movflags", "+faststart", "-an", "-t", "10", "-r", "30")

  # Lateral: pan L→R across wide plate (side highway sedan pass ≈ ref-lateral)
  $latFcTpl = "[0:v]crop=960:540:(iw-960)*t/10:(ih-540)/2,drawtext=fontfile=FONT:text='LATERAL | CAM-L | A1-KM10-N':x=12:y=10:fontsize=18:fontcolor=0xa0dcaa,drawtext=fontfile=FONT:text='t=%{pts\:hms}  |  plate PLATE  |  +/-5s':x=12:y=34:fontsize=14:fontcolor=0x78a082,drawtext=fontfile=FONT:text='LAB CLIP | FreeFlow':x=12:y=518:fontsize=13:fontcolor=0x6e9680"
  # Overview: slow vertical drift on tall plate (high panoramic multi-lane ≈ ref-overview)
  $ovFcTpl = "[0:v]crop=960:540:(iw-960)/2:(ih-540)*t/10,drawtext=fontfile=FONT:text='OVERVIEW | CAM-O | A1-KM10-N':x=12:y=10:fontsize=18:fontcolor=0xa0dcaa,drawtext=fontfile=FONT:text='t=%{pts\:hms}  |  plate PLATE  |  +/-5s':x=12:y=34:fontsize=14:fontcolor=0x78a082,drawtext=fontfile=FONT:text='LAB CLIP | FreeFlow':x=12:y=518:fontsize=13:fontcolor=0x6e9680"

  $ffmpegCmd = if ($PreferHostFfmpeg) { Get-Command ffmpeg -ErrorAction SilentlyContinue } else { $null }
  $useDocker = -not $ffmpegCmd

  if ($useDocker) {
    Write-Host "using docker jrottenberg/ffmpeg:4.4-alpine"
    docker pull jrottenberg/ffmpeg:4.4-alpine | Out-Null
    $latFc = $latFcTpl.Replace("FONT", "/fonts/consola.ttf").Replace("PLATE", $plate)
    $ovFc = $ovFcTpl.Replace("FONT", "/fonts/consola.ttf").Replace("PLATE", $plate)
    docker run --rm `
      -v "${labUi}:/out" `
      -v "${fonts}:/fonts:ro" `
      --entrypoint ffmpeg jrottenberg/ffmpeg:4.4-alpine `
      -y -loop 1 -i /out/_gen/lateral-bg.png `
      -filter_complex $latFc @enc /out/video-lateral.mp4
    if ($LASTEXITCODE -ne 0) { throw "docker ffmpeg lateral failed" }
    docker run --rm `
      -v "${labUi}:/out" `
      -v "${fonts}:/fonts:ro" `
      --entrypoint ffmpeg jrottenberg/ffmpeg:4.4-alpine `
      -y -loop 1 -i /out/_gen/overview-bg.png `
      -filter_complex $ovFc @enc /out/video-overview.mp4
    if ($LASTEXITCODE -ne 0) { throw "docker ffmpeg overview failed" }
  } else {
    $ffFont = (Join-Path $fonts "consola.ttf")
    if (-not (Test-Path $ffFont)) { $ffFont = Join-Path $fonts "arial.ttf" }
    $ffFont = $ffFont.Replace("\", "/")
    $latFc = $latFcTpl.Replace("FONT", $ffFont).Replace("PLATE", $plate)
    $ovFc = $ovFcTpl.Replace("FONT", $ffFont).Replace("PLATE", $plate)
    & ffmpeg -y -loop 1 -i (Join-Path $genDir "lateral-bg.png") `
      -filter_complex $latFc @enc (Join-Path $labUi "video-lateral.mp4")
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg lateral failed" }
    & ffmpeg -y -loop 1 -i (Join-Path $genDir "overview-bg.png") `
      -filter_complex $ovFc @enc (Join-Path $labUi "video-overview.mp4")
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg overview failed" }
  }
}

Write-Host "== copy fixtures =="
Copy-Item (Join-Path $labUi "anpr-front.jpg"), (Join-Path $labUi "anpr-rear.jpg") $fixAnpr -Force
if (-not $SkipVideos) {
  Copy-Item (Join-Path $labUi "video-lateral.mp4"), (Join-Path $labUi "video-overview.mp4") $fixVideo -Force
  $genDir = Join-Path $labUi "_gen"
  if (Test-Path $genDir) { Remove-Item -Recurse -Force $genDir }
}

Write-Host "== update evidence_package.json hashes + plate $plate =="
python $hashPy
if ($LASTEXITCODE -ne 0) { throw "fixture hash update failed" }

Write-Host "OK lab media under $labUi"
Write-Host "Next (Docker only): compose rebuild ops-ui + smoke-package-twin.ps1"
