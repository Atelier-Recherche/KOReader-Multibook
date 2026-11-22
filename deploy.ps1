#Requires -Version 5.1
<#
.SYNOPSIS
  Pousse le plugin sur l'appareil connecté en ADB (fichiers .lua uniquement).
#>
param(
  [string]$AdbDevice = '',
  [string]$RemotePluginsDir = '',
  [string]$PluginDirName = 'multibook.koplugin',
  [switch]$Build
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot

if (-not (Get-Command adb -EA SilentlyContinue)) {
  throw 'adb introuvable dans le PATH'
}

if ($Build) {
  & (Join-Path $Root 'build.ps1') | Out-Null
}

$luaFiles = @(Get-ChildItem -Path $Root -File -Filter '*.lua')
if ($luaFiles.Count -eq 0) { throw 'Aucun fichier .lua à déployer' }

$adbArgs = @()
if ($AdbDevice) { $adbArgs += @('-s', $AdbDevice) }

$devices = & adb @adbArgs devices | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' }
if (-not $devices) {
  throw 'Aucun appareil ADB en état device (câble / autorisation USB ?)'
}

if (-not $RemotePluginsDir) {
  $probe = & adb @adbArgs shell "if [ -d /mnt/onboard ]; then echo kobo; fi" 2>$null
  $isKobo = if ($null -ne $probe) { "$probe".Trim() } else { '' }
  if ($isKobo -eq 'kobo') {
    $RemotePluginsDir = '/mnt/onboard/.adds/koreader/plugins'
  } else {
    $RemotePluginsDir = '/sdcard/koreader/plugins'
  }
  Write-Host "==> Plugins dir détecté: $RemotePluginsDir"
}

$remote = ($RemotePluginsDir.TrimEnd('/') + '/' + $PluginDirName)

Write-Host "==> adb shell mkdir -p $remote"
& adb @adbArgs shell "mkdir -p '$remote'"
if ($LASTEXITCODE -ne 0) { throw 'adb mkdir a échoué' }

foreach ($f in $luaFiles) {
  $dest = "$remote/$($f.Name)"
  Write-Host "==> adb push $($f.Name) -> $dest"
  & adb @adbArgs push $f.FullName $dest
  if ($LASTEXITCODE -ne 0) { throw "adb push a échoué pour $($f.Name)" }
}

Write-Host "==> Deploy terminé ($($luaFiles.Count) fichiers → $remote)" -ForegroundColor Green
