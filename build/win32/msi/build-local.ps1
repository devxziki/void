<#
.SYNOPSIS
  Builds a Void Windows MSI entirely on the local (Windows) machine.
  No GitHub Actions required.

.DESCRIPTION
  Runs the full pipeline on this Windows machine:
    npm ci -> buildreact -> compile (non-mangled) -> extensions -> bundle
    -> package VSCode-win32-<arch> -> Inno updater -> WiX -> MSI.

  Prerequisites (install once):
    - Node.js 20.x         https://nodejs.org (matches .nvmrc)
    - Git for Windows      https://git-scm.com
    - Python 3.x           https://python.org (node-gyp needs it)
    - .NET SDK 8           https://dotnet.microsoft.com (for WiX v7)
    - Build Tools for Visual Studio 2022 with "Desktop development with C++"
      (node-gyp native modules require MSVC)

.PARAMETER Arch
  Target architecture: x64 (default) or arm64. arm64 requires the ARM64
  MSVC toolset (VS2022 installer: Individual components -> MSVC v143 - VS
  2022 C++ ARM64 build tools).

.PARAMETER SkipCompile
  If the repo was already compiled (out-vscode + .build/extensions exist),
  skip the slow compile steps and only repackage + build the MSI.

.EXAMPLE
  .\build-local.ps1 -Arch x64

.EXAMPLE
  .\build-local.ps1 -Arch arm64 -SkipCompile
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
$root = (Get-Item (Resolve-Path "$PSScriptRoot\..\..\..")).FullName
Set-Location $root

Write-Host "==> Void local MSI build ($Arch) in $root" -ForegroundColor Cyan

# ---- Platform sanity check -------------------------------------------------
if (-not $IsWindows) {
    throw "This script must run on a real Windows machine (native modules + WiX require Windows)."
}

# ---- Tool checks -----------------------------------------------------------
$node = (node --version) 2>&1
if ($LASTEXITCODE -ne 0) { throw "Node.js not found. Install Node 20.x from https://nodejs.org" }
Write-Host "   Node: $node"

dotnet --version | Out-Null
if ($LASTEXITCODE -ne 0) { throw ".NET SDK not found. Install from https://dotnet.microsoft.com (required by WiX v7)." }

# ---- WiX v7 ----------------------------------------------------------------
$wix = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wix) {
    Write-Host "==> Installing WiX v7 (dotnet tool)..." -ForegroundColor Yellow
    dotnet tool install --global wix --version 7.0.0
    $env:PATH = "$env:USERPROFILE\.dotnet\tools;$env:PATH"
    $wix = Get-Command wix
    if (-not $wix) { throw "WiX install failed. Add %USERPROFILE%\.dotnet\tools to PATH and re-run." }
}
Write-Host "   WiX: $((& $wix.Source --version))"

# ---- Install dependencies (Windows native modules for $Arch) --------------
$env:npm_config_arch = $Arch
$env:npm_config_runtime = 'electron'
$env:npm_config_target = '34.3.2'
$env:npm_config_foreground_scripts = 'true'

if (-not (Test-Path "$root\node_modules\gulp\bin\gulp.js")) {
    Write-Host "==> npm ci (this takes ~10-20 min; downloads Electron $Arch headers + compiles native modules)..." -ForegroundColor Yellow
    npm ci
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed. See the output above." }
} else {
    Write-Host "==> node_modules present; skipping npm ci (remove node_modules to force reinstall)" -ForegroundColor Yellow
}

# ---- Compile (platform-neutral TypeScript -> out-build -> out-vscode) ------
if (-not $SkipCompile) {
    Write-Host "==> buildreact (Void React components)..." -ForegroundColor Yellow
    npm run buildreact
    if ($LASTEXITCODE -ne 0) { throw "buildreact failed." }

    Write-Host "==> gulp compile-build-without-mangling (non-mangled: mangler crashes on Void deps)..." -ForegroundColor Yellow
    npm run gulp compile-build-without-mangling
    if ($LASTEXITCODE -ne 0) { throw "compile failed." }

    Write-Host "==> gulp extensions-ci..." -ForegroundColor Yellow
    npm run gulp extensions-ci
    if ($LASTEXITCODE -ne 0) { throw "extensions compile failed." }

    Write-Host "==> gulp bundle-vscode..." -ForegroundColor Yellow
    npm run gulp bundle-vscode
    if ($LASTEXITCODE -ne 0) { throw "bundle failed." }
}

# ---- Package app into ../VSCode-win32-$Arch --------------------------------
Write-Host "==> gulp vscode-win32-$Arch-ci (packages the app)..." -ForegroundColor Yellow
npm run gulp "vscode-win32-$Arch-ci"
if ($LASTEXITCODE -ne 0) { throw "package failed." }

Write-Host "==> gulp vscode-win32-$Arch-inno-updater..." -ForegroundColor Yellow
npm run gulp "vscode-win32-$Arch-inno-updater"
if ($LASTEXITCODE -ne 0) { throw "inno-updater failed." }

# ---- MSI --------------------------------------------------------------------
Write-Host "==> Building MSI with WiX v7..." -ForegroundColor Yellow
& "$root\build\win32\msi\build-msi.ps1" -Arch $Arch -RepoDir $root -WixTool $wix.Source
if ($LASTEXITCODE -ne 0) { throw "MSI build failed." }

$msi = Get-ChildItem "$root\.build\msi\VoidSetup-$Arch-*.msi" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Host ""
Write-Host "SUCCESS: $($msi.FullName)" -ForegroundColor Green
Write-Host "Install it by double-clicking (signed? no -- Windows SmartScreen will warn; choose 'More info -> Run anyway')."
