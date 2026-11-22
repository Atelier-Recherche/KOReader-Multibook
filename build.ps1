#Requires -Version 5.1
<#
.SYNOPSIS
  Build local : zip propre du plugin (uniquement les .lua nécessaires à KOReader).
.OUTPUTS
  Chemin du zip créé (aussi écrit sur stdout).
#>
param(
  [string]$OutDir = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$slug = 'ATmultibook.koplugin'

function Get-PluginVersion {
  $versionFile = Join-Path $Root 'VERSION'
  if (Test-Path $versionFile) {
    $v = (Get-Content $versionFile -Raw).Trim()
    if ($v) { return $v }
  }
  return '0.0.0'
}

function Get-PluginLuaFiles {
  Get-ChildItem -Path $Root -File -Filter '*.lua' | Sort-Object Name
}

$version = Get-PluginVersion
if ($OutDir -eq '') { $OutDir = $Root }
if (-not (Test-Path $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$luaFiles = @(Get-PluginLuaFiles)
if ($luaFiles.Count -eq 0) { throw 'Aucun fichier .lua trouvé à la racine du plugin' }

$zipName = "$slug-$version.zip"
$zipPath = Join-Path $OutDir $zipName
$stage = Join-Path $Root ('_stage_' + $slug)
$dest = Join-Path $stage $slug

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $dest -Force | Out-Null

foreach ($f in $luaFiles) {
  Copy-Item $f.FullName (Join-Path $dest $f.Name) -Force
  Write-Host "  + $($f.Name)"
}

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -Force
Remove-Item $stage -Recurse -Force

Write-Host "==> Build local: $zipPath" -ForegroundColor Green
Write-Output $zipPath
