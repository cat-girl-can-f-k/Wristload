[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pageRoot = Join-Path $projectRoot 'lib\presentation\pages'
$output = Join-Path $projectRoot 'lib\presentation\generated_page_registry.dart'

# Primary pages opt in by declaring the standard module constant. Dialogs and
# helpers do not participate in navigation merely because they are Dart files.
$pages = @(
  Get-ChildItem -LiteralPath $pageRoot -Filter '*.dart' -File |
    Where-Object {
      (Get-Content -LiteralPath $_.FullName -Raw) -match
        'const\s+wristloadPage\s*=\s*WristloadPageModule'
    } |
    Sort-Object Name
)

$imports = [System.Collections.Generic.List[string]]::new()
$entries = [System.Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $pages.Count; $index++) {
  $alias = "page$index"
  $imports.Add("import 'pages/$($pages[$index].Name)' as $alias;")
  $entries.Add("  $alias.wristloadPage,")
}

$importsText = $imports.ToArray() -join [Environment]::NewLine
$entriesText = $entries.ToArray() -join [Environment]::NewLine
$content = @(
  '// GENERATED CODE - DO NOT EDIT.',
  '// Run tool/generate_page_registry.ps1 after adding or removing a page module.',
  "import 'page_module.dart';",
  $importsText,
  '',
  'const generatedPageModules = <WristloadPageModule>[',
  $entriesText,
  '];',
  ''
) -join [Environment]::NewLine

Set-Content -LiteralPath $output -Value $content -Encoding utf8
Write-Output "Generated page registry with $($pages.Count) module(s)."
