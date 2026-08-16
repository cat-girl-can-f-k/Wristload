[CmdletBinding()]
param(
  [string]$FlutterRoot = 'C:\src\flutter'
)

# Build-only script: pub get + `flutter build windows --debug`.
# No analyze, no tests, no packaging, no auto-launch.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$flutter = Join-Path $FlutterRoot 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
  throw "Flutter launcher not found: $flutter"
}

function Invoke-Checked {
  param(
    [Parameter(Mandatory)] [string]$FilePath,
    [Parameter(Mandatory)] [string[]]$Arguments
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
  }
}

Push-Location $projectRoot
try {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'tool\generate_page_registry.ps1')
  if ($LASTEXITCODE -ne 0) {
    throw 'Page registry generation failed'
  }

  Write-Host '== Dependencies =='
  Invoke-Checked -FilePath $flutter -Arguments @('pub', 'get')

  Write-Host '== Windows debug build (no tests) =='
  Invoke-Checked -FilePath $flutter -Arguments @('build', 'windows', '--debug')

  $buildDirectory = Join-Path $projectRoot 'build\windows\x64\runner\Debug'
  $exe = Join-Path $buildDirectory 'wristload.exe'
  $kernel = Join-Path $buildDirectory 'data\flutter_assets\kernel_blob.bin'
  foreach ($path in @($exe, $kernel)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Required runtime file is missing: $path"
    }
  }

  Write-Host ''
  Write-Host "Build OK: $exe"
  Write-Host "Kernel  : $kernel"
  Write-Host 'Note: if only Dart code changed, wristload.exe may keep its old timestamp (runner unchanged). Check kernel_blob.bin timestamp to confirm the build is fresh.'
} finally {
  Pop-Location
}
