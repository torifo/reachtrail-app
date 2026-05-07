#!/usr/bin/env pwsh

$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = (Resolve-Path (Join-Path $ScriptDir ".." "..")).Path
$ExeDir     = Join-Path $RepoRoot "build" "windows" "x64" "runner" "Release"
$OutputDir  = Join-Path $RepoRoot "build" "windows-dist"
$ZipPath    = Join-Path $OutputDir "reachtrail-windows.zip"

Set-Location $RepoRoot

if (-not (Test-Path (Join-Path $ExeDir "ReachTrail.exe"))) {
    Write-Error "ReachTrail.exe not found at: $ExeDir"
    Write-Error "Run 'flutter build windows --release ...' first."
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
if (Test-Path $ZipPath) { Remove-Item $ZipPath }

Compress-Archive -Path "$ExeDir\*" -DestinationPath $ZipPath

Write-Host "Created: $ZipPath"
