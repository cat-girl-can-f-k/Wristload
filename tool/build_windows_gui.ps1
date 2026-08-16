[CmdletBinding()]
param(
  [switch]$NoGui
)

# Wristload 编译 GUI：flutter build windows --debug -> 打包 zip -> 移入发布包 -> 解压到 beta0.1.N
# 无 analyze / 无测试 / 无自动启动。
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool\build_windows_gui.ps1   （GUI）
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool\build_windows_gui.ps1 -NoGui （命令行同步模式，便于调试）

$ErrorActionPreference = 'Stop'

$script:projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:outputRoot = Join-Path (Split-Path (Split-Path $script:projectRoot -Parent) -Parent) '发布包'
$script:flutterRoot = 'C:\src\flutter'
$script:job = $null
$script:timer = $null
$script:startBtn = $null
$script:logBox = $null

# ---- 核心流程（在 Job / 命令行模式下运行）----
$buildJobScript = {
  param($FlutterRoot, $ProjectRoot, $OutputRoot)

  $ErrorActionPreference = 'Stop'
  try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
  } catch { }

  # Start-Job 的新进程工作目录是用户主目录；必须切到项目目录，
  # 否则 flutter pub get / build 会在错误位置运行。
  Push-Location $ProjectRoot
  try {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProjectRoot 'tool\generate_page_registry.ps1')
  if ($LASTEXITCODE -ne 0) {
    throw '页面注册表生成失败'
  }

  $flutter = Join-Path $FlutterRoot 'bin\flutter.bat'
  if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
    throw "未找到 Flutter: $flutter"
  }

  function Invoke-Checked {
    param(
      [Parameter(Mandatory)] [string]$FilePath,
      [Parameter(Mandatory)] [string[]]$Arguments
    )
    # PS 5.1 会把 native stderr 行包装成 ErrorRecord；在 Stop 模式下会误终止。
    # 这里临时降为 Continue，并把 stderr 行转成普通日志输出。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & $FilePath @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
          Write-Output $_.ToString()
        } else {
          Write-Output $_
        }
      }
    } finally {
      $ErrorActionPreference = $prevEap
    }
    if ($LASTEXITCODE -ne 0) {
      throw "命令失败 (exit $LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
  }

  Write-Output '== 依赖 =='
  Invoke-Checked $flutter @('pub', 'get')

  Write-Output '== Windows debug 编译（无测试） =='
  Invoke-Checked $flutter @('build', 'windows', '--debug')

  $buildDir = Join-Path $ProjectRoot 'build\windows\x64\runner\Debug'
  foreach ($p in @('wristload.exe', 'flutter_windows.dll', 'data\icudtl.dat', 'data\flutter_assets\kernel_blob.bin')) {
    $full = Join-Path $buildDir $p
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
      throw "缺少编译产物: $p"
    }
  }

  # 依据发布包内已有 beta0.1.N 目录自动递增版本号
  $betas = @(
    Get-ChildItem -LiteralPath $OutputRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object {
        if ($_.Name -match '^beta(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') {
          [pscustomobject]@{ Name = $_.Name; major = [int]$Matches.major; minor = [int]$Matches.minor; patch = [int]$Matches.patch }
        }
      }
  )
  if ($betas.Count -eq 0) {
    $beta = 'beta0.1.0'
  } else {
    $last = $betas | Sort-Object major, minor, patch | Select-Object -Last 1
    $beta = "beta$($last.major).$($last.minor).$($last.patch + 1)"
  }
  $versionDir = Join-Path $OutputRoot $beta
  if (Test-Path -LiteralPath $versionDir) {
    throw "版本目录已存在，拒绝覆盖: $versionDir"
  }

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $zipName = "Wristload-$beta-windows-x64-debug-test-$stamp.zip"
  $zipFinal = Join-Path $OutputRoot $zipName
  if (Test-Path -LiteralPath $zipFinal) {
    throw "ZIP 已存在，拒绝覆盖: $zipName"
  }
  $zipTemp = Join-Path ([IO.Path]::GetTempPath()) $zipName

  Write-Output "== 打包 $zipName =="
  Compress-Archive -Path (Join-Path $buildDir '*') -DestinationPath $zipTemp -CompressionLevel Optimal

  Write-Output '== 移动 ZIP 到发布包 =='
  Move-Item -LiteralPath $zipTemp -Destination $zipFinal -Force

  Write-Output "== 解压到 $versionDir =="
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

  Write-Output "DONE|$beta|$zipFinal|$versionDir"
  } finally {
    Pop-Location
  }
}

# ---- 命令行模式 ----
if ($NoGui) {
  & $buildJobScript $script:flutterRoot $script:projectRoot $script:outputRoot
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  exit 0
}

# ---- GUI 模式 ----
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Add-Log([string]$text) {
  if (-not $script:logBox) { return }
  $script:logBox.AppendText("$text`r`n")
  $script:logBox.SelectionStart = $script:logBox.TextLength
  $script:logBox.ScrollToCaret()
  [System.Windows.Forms.Application]::DoEvents()
}

function Update-Job {
  $j = $script:job
  if (-not $j) { return }
  $lines = @(Receive-Job $j -Keep)
  foreach ($line in $lines) { Add-Log ([string]$line) }

  if ($j.State -ne 'Running') {
    $script:timer.Stop()
    $all = @(Receive-Job $j)
    $done = $all | Where-Object { $_ -is [string] -and $_ -match '^DONE\|' } | Select-Object -Last 1
    if ($done) {
      $parts = $done -split '\|'
      Add-Log ''
      Add-Log "===== 编译完成：版本 $($parts[1]) ====="
      Add-Log "ZIP：$($parts[2])"
      Add-Log "解压目录：$($parts[3])"
      [System.Windows.Forms.MessageBox]::Show(
        "编译完成`n版本：$($parts[1])`nZIP：$($parts[2])`n解压目录：$($parts[3])",
        '完成', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    } else {
      Add-Log ''
      Add-Log '===== 编译失败，请查看上方日志 ====='
      $errTexts = @($j.Error | ForEach-Object { $_.Exception.Message } | Where-Object { $_ })
      if ($errTexts.Count -gt 0) {
        Add-Log ('错误详情：' + ($errTexts -join ' | '))
      }
      [System.Windows.Forms.MessageBox]::Show(
        '编译失败，请查看日志。',
        '失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    Remove-Job $j -Force
    $script:job = $null
    $script:startBtn.Enabled = $true
  }
}

function Start-Build {
  if ($script:job -and $script:job.State -eq 'Running') {
    Add-Log '编译已在进行中。'
    return
  }
  $script:startBtn.Enabled = $false
  Add-Log '===== 开始编译 ====='
  $script:job = Start-Job -ScriptBlock $buildJobScript -ArgumentList $script:flutterRoot, $script:projectRoot, $script:outputRoot
  $script:timer = New-Object System.Windows.Forms.Timer
  $script:timer.Interval = 400
  $script:timer.Add_Tick({ Update-Job })
  $script:timer.Start()
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Wristload 编译工具'
$form.Size = New-Object System.Drawing.Size(780, 560)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(640, 420)

$label = New-Object System.Windows.Forms.Label
$label.Text = "发布目录：$script:outputRoot`n版本命名：按发布包内已有 beta0.1.N 自动递增（beta0.1.32、beta0.1.33 …）"
$label.Location = New-Object System.Drawing.Point(12, 10)
$label.Size = New-Object System.Drawing.Size(740, 36)
$label.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.Controls.Add($label)

$script:logBox = New-Object System.Windows.Forms.TextBox
$script:logBox.Multiline = $true
$script:logBox.ReadOnly = $true
$script:logBox.ScrollBars = 'Vertical'
$script:logBox.Location = New-Object System.Drawing.Point(12, 52)
$script:logBox.Size = New-Object System.Drawing.Size(740, 420)
$script:logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($script:logBox)

$script:startBtn = New-Object System.Windows.Forms.Button
$script:startBtn.Text = '开始编译'
$script:startBtn.Location = New-Object System.Drawing.Point(12, 482)
$script:startBtn.Size = New-Object System.Drawing.Size(120, 36)
$script:startBtn.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$script:startBtn.Add_Click({ Start-Build })
$form.Controls.Add($script:startBtn)

$closeBtn = New-Object System.Windows.Forms.Button
$closeBtn.Text = '退出'
$closeBtn.Location = New-Object System.Drawing.Point(142, 482)
$closeBtn.Size = New-Object System.Drawing.Size(90, 36)
$closeBtn.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$closeBtn.Add_Click({ $form.Close() })
$form.Controls.Add($closeBtn)

$form.Add_FormClosing({
  if ($script:job -and $script:job.State -eq 'Running') {
    $r = [System.Windows.Forms.MessageBox]::Show(
      '编译仍在进行中，确定退出？（将终止编译）',
      '确认', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
      Stop-Job $script:job -ErrorAction SilentlyContinue
      Remove-Job $script:job -Force -ErrorAction SilentlyContinue
      $script:job = $null
    } else {
      $_.Cancel = $true
    }
  }
})

[System.Windows.Forms.Application]::Run($form)
