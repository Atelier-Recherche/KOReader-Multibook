#Requires -Version 5.1
<#
.SYNOPSIS
  Bump de version, build d'un zip propre, tag git et GitHub Release.
#>
param(
  [ValidateSet('Patch', 'Minor', 'Major')]
  [string]$BumpKind = 'Patch',
  [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
Set-Location $Root
$slug = 'ATmultibook.koplugin'

foreach ($c in @('git', 'gh')) {
  if (-not (Get-Command $c -EA SilentlyContinue)) {
    throw "Commande introuvable: $c"
  }
}

$dirty = (git status --porcelain | Out-String).Trim()
if ($dirty) {
  throw "Arbre Git non propre.`n$dirty"
}

$versionFile = Join-Path $Root 'VERSION'
$current = '0.0.0'
if (Test-Path $versionFile) {
  $current = (Get-Content $versionFile -Raw).Trim()
}
if ($current -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
  throw "Version non semver: $current"
}

$maj = [int]$Matches[1]
$min = [int]$Matches[2]
$pat = [int]$Matches[3]
switch ($BumpKind) {
  'Major' { $new = "$($maj + 1).0.0" }
  'Minor' { $new = "$maj.$($min + 1).0" }
  default { $new = "$maj.$min.$($pat + 1)" }
}

Write-Host "==> Release $slug $current -> $new"
if ($DryRun) {
  Write-Host '(DryRun) aucun changement' -ForegroundColor Yellow
  return
}

$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($versionFile, $new, $utf8)

$zipPath = & (Join-Path $Root 'build.ps1') | Select-Object -Last 1
if (-not $zipPath -or -not (Test-Path $zipPath)) {
  throw 'Zip introuvable après build'
}

git add VERSION
# Inclure le zip seulement s'il est suivi ; sinon rester hors dépôt
git commit -m "release: v$new"
git tag "v$new"
git push origin HEAD
git push origin "v$new"

gh release create "v$new" $zipPath --title "v$new" --generate-notes

Write-Host "==> Release v$new publiée" -ForegroundColor Green
Write-Host "    Asset: $zipPath"
