[CmdletBinding()]
param()

# Wristload 编译工具（TUI 版）
# 终端交互界面：菜单选择 -> 编译 -> 打包 zip -> 移入发布包 -> 解压到 beta0.1.N
# 无 analyze / 无测试 / 无自动启动。

$ErrorActionPreference = 'Stop'

$script:projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:outputRoot = Join-Path (Split-Path (Split-Path $script:projectRoot -Parent) -Parent) '发布包'
$script:flutterRoot = 'C:\src\flutter'

function Get-NextBeta {
  $betas = @(
    Get-ChildItem -LiteralPath $script:outputRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object {
        if ($_.Name -match '^beta(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') {
          [pscustomobject]@{ major = [int]$Matches.major; minor = [int]$Matches.minor; patch = [int]$Matches.patch }
        }
      }
  )
  if ($betas.Count -eq 0) { return 'beta0.1.0' }
  $last = $betas | Sort-Object major, minor, patch | Select-Object -Last 1
  return "beta$($last.major).$($last.minor).$($last.patch + 1)"
}

function Invoke-Build {
  Write-Host ''
  Write-Host '===== 开始编译 =====' -ForegroundColor Cyan
  $flutter = Join-Path $script:flutterRoot 'bin\flutter.bat'
  if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
    Write-Host "未找到 Flutter: $flutter" -ForegroundColor Red
    return
  }

  Push-Location $script:projectRoot
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:projectRoot 'tool\generate_page_registry.ps1')
    if ($LASTEXITCODE -ne 0) { throw '页面注册表生成失败' }

    Write-Host '== 依赖 ==' -ForegroundColor Cyan
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "pub get 失败 (exit $LASTEXITCODE)" }

    Write-Host '== Windows debug 编译（无测试） ==' -ForegroundColor Cyan
    & $flutter build windows --debug
    if ($LASTEXITCODE -ne 0) { throw "编译失败 (exit $LASTEXITCODE)" }

    $buildDir = Join-Path $script:projectRoot 'build\windows\x64\runner\Debug'
    foreach ($p in @('wristload.exe', 'flutter_windows.dll', 'data\icudtl.dat', 'data\flutter_assets\kernel_blob.bin')) {
      $full = Join-Path $buildDir $p
      if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "缺少编译产物: $p" }
    }

    $beta = Get-NextBeta
    $versionDir = Join-Path $script:outputRoot $beta
    if (Test-Path -LiteralPath $versionDir) { throw "版本目录已存在，拒绝覆盖: $versionDir" }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $zipName = "Wristload-$beta-windows-x64-debug-test-$stamp.zip"
    $zipFinal = Join-Path $script:outputRoot $zipName
    if (Test-Path -LiteralPath $zipFinal) { throw "ZIP 已存在，拒绝覆盖: $zipName" }
    $zipTemp = Join-Path ([IO.Path]::GetTempPath()) $zipName

    Write-Host "== 打包 $zipName ==" -ForegroundColor Cyan
    Compress-Archive -Path (Join-Path $buildDir '*') -DestinationPath $zipTemp -CompressionLevel Optimal

    Write-Host '== 移动 ZIP 到发布包 ==' -ForegroundColor Cyan
    Move-Item -LiteralPath $zipTemp -Destination $zipFinal -Force

    Write-Host "== 解压到 $versionDir ==" -ForegroundColor Cyan
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "Wristload-extract-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
      Expand-Archive -LiteralPath $zipFinal -DestinationPath $tempRoot -Force
      New-Item -ItemType Directory -Path $versionDir -Force | Out-Null
      Get-ChildItem -Force -LiteralPath $tempRoot | ForEach-Object {
        Move-Item -LiteralPath $_.FullName -Destination $versionDir -Force
      }
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath (Join-Path $versionDir 'wristload.exe') -PathType Leaf)) {
      throw '解压后缺少 wristload.exe'
    }

    Write-Host ''
    Write-Host "===== 编译完成：版本 $beta =====" -ForegroundColor Green
    Write-Host "ZIP：$zipFinal" -ForegroundColor Green
    Write-Host "解压目录：$versionDir" -ForegroundColor Green
  } catch {
    Write-Host ''
    Write-Host "===== 编译失败：$($_.Exception.Message) =====" -ForegroundColor Red
  } finally {
    Pop-Location
  }
}

# ---- 主菜单循环 ----
$exit = $false
while (-not $exit) {
  [Console]::Clear()
  Write-Host '============================================' -ForegroundColor Cyan
  Write-Host '         Wristload 编译工具 (TUI)' -ForegroundColor White
  Write-Host '============================================' -ForegroundColor Cyan
  Write-Host ("项目目录：$script:projectRoot") -ForegroundColor Gray
  Write-Host ("发布目录：$script:outputRoot") -ForegroundColor Gray
  Write-Host ("Flutter：$script:flutterRoot") -ForegroundColor Gray
  Write-Host ("下一个版本：$(Get-NextBeta)") -ForegroundColor Yellow
  Write-Host ''
  Write-Host '  [1] 开始编译（debug 构建 -> zip -> 发布包 -> 解压）' -ForegroundColor White
  Write-Host '  [2] 退出' -ForegroundColor White
  Write-Host ''
  $key = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
  switch ($key.Character.ToString().ToLower()) {
    '1' {
      Invoke-Build
      Write-Host ''
      Write-Host '按任意键返回菜单...' -ForegroundColor DarkGray
      $null = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    '2' { $exit = $true }
    default { }
  }
}
