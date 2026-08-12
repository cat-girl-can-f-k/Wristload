[CmdletBinding()]
param(
  [string]$FlutterRoot = 'C:\src\flutter',
  [string]$OutputRoot = '',
  [switch]$SkipSmokeTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $releaseDirectoryName = -join [char[]]@(0x53D1, 0x5E03, 0x5305)
  $OutputRoot = Join-Path (Split-Path (Split-Path $projectRoot -Parent) -Parent) $releaseDirectoryName
}

$flutter = Join-Path $FlutterRoot 'bin\flutter.bat'
$dart = Join-Path $FlutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
  throw "Flutter launcher not found: $flutter"
}
if (-not (Test-Path -LiteralPath $dart -PathType Leaf)) {
  throw "Dart executable not found: $dart"
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

$temporaryRoot = $null
Push-Location $projectRoot
try {
  Write-Host '== Toolchain =='
  Invoke-Checked -FilePath $flutter -Arguments @('--version')

  Write-Host '== Dependencies =='
  Invoke-Checked -FilePath $flutter -Arguments @('pub', 'get')

  Write-Host '== Static analysis =='
  Invoke-Checked -FilePath $dart -Arguments @('analyze')

  Write-Host '== Tests =='
  Invoke-Checked -FilePath $flutter -Arguments @('test')

  $buildStartedAt = Get-Date
  Write-Host '== Windows debug build =='
  Invoke-Checked -FilePath $flutter -Arguments @('build', 'windows', '--debug')

  $buildDirectory = Join-Path $projectRoot 'build\windows\x64\runner\Debug'
  $exe = Join-Path $buildDirectory 'wristload.exe'
  $required = @(
    $exe,
    (Join-Path $buildDirectory 'flutter_windows.dll'),
    (Join-Path $buildDirectory 'bluetooth_low_energy_windows_plugin.dll'),
    (Join-Path $buildDirectory 'data\icudtl.dat'),
    (Join-Path $buildDirectory 'data\flutter_assets\kernel_blob.bin'),
    (Join-Path $buildDirectory 'data\flutter_assets\AssetManifest.bin')
  )
  foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Required runtime file is missing: $path"
    }
  }

  $dartInputs = @(
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'lib') -Recurse -File -Filter '*.dart'
    Get-Item -LiteralPath (Join-Path $projectRoot 'pubspec.yaml')
    Get-Item -LiteralPath (Join-Path $projectRoot 'pubspec.lock')
  )
  $runnerInputs = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'windows\runner') -Recurse -File |
    Where-Object { $_.Extension -in @('.cpp', '.h', '.rc', '.manifest') }
  $pluginInputs = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'plugins\bluetooth_low_energy_windows\windows') -Recurse -File |
    Where-Object { $_.Extension -in @('.cpp', '.h') }
  $latestDartInput = $dartInputs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  $latestRunnerInput = $runnerInputs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  $latestPluginInput = $pluginInputs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  $allSourceInputs = @($dartInputs) + @($runnerInputs) + @($pluginInputs)
  $latestSource = $allSourceInputs |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
  $kernel = Get-Item -LiteralPath (Join-Path $buildDirectory 'data\flutter_assets\kernel_blob.bin')
  $plugin = Get-Item -LiteralPath (Join-Path $buildDirectory 'bluetooth_low_energy_windows_plugin.dll')
  $runner = Get-Item -LiteralPath $exe
  if ($latestSource.LastWriteTimeUtc -gt $buildStartedAt.ToUniversalTime()) {
    throw "Source changed during the build: $($latestSource.FullName)"
  }
  if ($kernel.LastWriteTimeUtc -lt $latestDartInput.LastWriteTimeUtc) {
    throw "kernel_blob.bin is older than its newest Dart input: $($latestDartInput.FullName)"
  }
  if ($plugin.LastWriteTimeUtc -lt $latestPluginInput.LastWriteTimeUtc) {
    throw "The Windows Bluetooth plugin DLL is older than its newest source: $($latestPluginInput.FullName)"
  }
  if ($runner.LastWriteTimeUtc -lt $latestRunnerInput.LastWriteTimeUtc) {
    throw "The Windows runner EXE is older than its newest source: $($latestRunnerInput.FullName)"
  }

  if (-not $SkipSmokeTest) {
    Write-Host '== Launch smoke test =='
    $process = Start-Process -FilePath $exe -WorkingDirectory $buildDirectory -PassThru
    try {
      if ($process.WaitForExit(5000)) {
        throw "Application exited during smoke test with code $($process.ExitCode)."
      }
    } finally {
      if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
      }
    }
  }

  $pubspec = Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Encoding UTF8
  $versionLine = $pubspec | Where-Object { $_ -match '^version:\s*' } | Select-Object -First 1
  if ($null -eq $versionLine) {
    throw 'Unable to read the application version from pubspec.yaml.'
  }
  $version = ($versionLine -replace '^version:\s*', '') -replace '\+', '-'

  if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
  }
  $betaCandidates = @(
    Get-ChildItem -LiteralPath $OutputRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object {
        if ($_.Name -match '^beta(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') {
          [pscustomobject]@{
            Name = $_.Name
            Major = [int]$Matches.major
            Minor = [int]$Matches.minor
            Patch = [int]$Matches.patch
          }
        }
      }
  )
  if ($betaCandidates.Count -eq 0) {
    $betaVersion = 'beta0.1.0'
  } else {
    $latestBeta = $betaCandidates | Sort-Object Major, Minor, Patch | Select-Object -Last 1
    $nextPatch = $latestBeta.Patch + 1
    $betaVersion = "beta$($latestBeta.Major).$($latestBeta.Minor).$nextPatch"
  }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $artifactName = "Wristload-$betaVersion-windows-x64-debug-test-$stamp"
  $zipName = "$artifactName.zip"
  $zipPath = Join-Path $OutputRoot $zipName
  $versionDirectory = Join-Path $OutputRoot $betaVersion
  if (Test-Path -LiteralPath $versionDirectory) {
    throw "Refusing to overwrite an existing beta directory: $versionDirectory"
  }
  if (Test-Path -LiteralPath $zipPath) {
    throw "Refusing to overwrite an existing ZIP: $zipPath"
  }

  $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "Wristload-$([guid]::NewGuid().ToString('N'))"
  $artifactDirectory = Join-Path $temporaryRoot $artifactName
  $extractedDirectory = Join-Path $temporaryRoot 'extracted'
  New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
  Copy-Item -Path (Join-Path $buildDirectory '*') -Destination $artifactDirectory -Recurse

  $projectGitPath = $projectRoot.Replace([IO.Path]::DirectorySeparatorChar, '/')
  $gitRevision = (& git -c "safe.directory=$projectGitPath" rev-parse HEAD 2>$null)
  $gitDirty = [bool](& git -c "safe.directory=$projectGitPath" status --porcelain 2>$null)
  $files = Get-ChildItem -LiteralPath $artifactDirectory -Recurse -File |
    Sort-Object FullName |
    ForEach-Object {
      [ordered]@{
        path = $_.FullName.Substring($artifactDirectory.Length + 1).Replace([IO.Path]::DirectorySeparatorChar, '/')
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
      }
    }
  $manifest = [ordered]@{
    artifact = $artifactName
    releaseVersion = $betaVersion
    package = $zipName
    applicationVersion = $version
    configuration = 'Debug'
    target = 'windows-x64'
    builtAt = (Get-Date).ToString('o')
    gitRevision = $gitRevision
    gitDirty = $gitDirty
    verification = [ordered]@{
      dartAnalyze = 'passed'
      flutterTest = 'passed'
      launchSmokeTest = $(if ($SkipSmokeTest) { 'skipped' } else { 'passed' })
    }
    files = @($files)
  }
  $manifestPath = Join-Path $artifactDirectory 'build-manifest.json'
  $manifestJson = $manifest | ConvertTo-Json -Depth 6
  Set-Content -LiteralPath $manifestPath -Value $manifestJson -Encoding UTF8

  Compress-Archive -Path (Join-Path $artifactDirectory '*') -DestinationPath $zipPath -CompressionLevel Optimal
  $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  Set-Content -LiteralPath "$zipPath.sha256" -Encoding ASCII -Value "$zipHash  $([IO.Path]::GetFileName($zipPath))"

  Write-Host '== Extract test package =='
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractedDirectory -Force
  $extractedItems = @(Get-ChildItem -Force -LiteralPath $extractedDirectory)
  if ($extractedItems.Count -eq 0) {
    throw "The test package extracted no files: $zipPath"
  }
  New-Item -ItemType Directory -Path $versionDirectory -Force | Out-Null
  foreach ($item in $extractedItems) {
    Move-Item -LiteralPath $item.FullName -Destination $versionDirectory -Force
  }
  foreach ($path in $required) {
    $relativePath = $path.Substring($buildDirectory.Length + 1)
    $extractedPath = Join-Path $versionDirectory $relativePath
    if (-not (Test-Path -LiteralPath $extractedPath -PathType Leaf)) {
      throw "Required runtime file is missing after ZIP extraction: $extractedPath"
    }
  }
  $finalExe = Join-Path $versionDirectory 'wristload.exe'
  $finalProcess = $null
  if (-not $SkipSmokeTest) {
    Write-Host '== Launch extracted beta version =='
    $normalizedOutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\') + '\'
    Get-Process -Name 'wristload' -ErrorAction SilentlyContinue |
      Where-Object {
        try {
          $_.Path.StartsWith($normalizedOutputRoot, [StringComparison]::OrdinalIgnoreCase) -and
            -not $_.Path.Equals($finalExe, [StringComparison]::OrdinalIgnoreCase)
        } catch {
          $false
        }
      } | Stop-Process -Force
    $finalProcess = Start-Process -FilePath $finalExe -WorkingDirectory $versionDirectory -PassThru
    Start-Sleep -Milliseconds 500
    if ($finalProcess.HasExited) {
      throw "Extracted beta application exited immediately with code $($finalProcess.ExitCode)."
    }
  }

  Write-Host "Beta version: $betaVersion"
  Write-Host "Extracted directory: $versionDirectory"
  if ($null -ne $finalProcess) {
    Write-Host "Final process ID: $($finalProcess.Id)"
  } else {
    Write-Host 'Final process: not started'
  }
  Write-Host "ZIP: $zipPath"
  Write-Host "SHA-256: $zipHash"
} finally {
  if ($temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot -PathType Container)) {
    $tempRootPath = [IO.Path]::GetFullPath($temporaryRoot).TrimEnd('\')
    $tempBasePath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ($tempRootPath.StartsWith($tempBasePath, [StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  Pop-Location
}
