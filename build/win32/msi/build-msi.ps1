<#
.SYNOPSIS
  Builds a native Windows MSI for Void (win32 x64 or arm64) using WiX v4.

.DESCRIPTION
  Harvests the packaged app produced by `npm run gulp vscode-win32-<arch>-min`
  (located at ../VSCode-win32-<arch> next to the repo), generates a
  components.wxs with one component per directory, and compiles a full MSI
  with the actual app files, Start Menu + desktop shortcuts and the void://
  URL protocol handler.

.PARAMETER Arch
  Target architecture: x64 or arm64.

.PARAMETER RepoDir
  Path to the repository root. Defaults to this script's repo root.

.PARAMETER WixTool
  Path to the `wix` executable. Defaults to `wix` on PATH.

.EXAMPLE
  .\build-win32-msi.ps1 -Arch arm64
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Arch,
    [string]$RepoDir = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))),
    [string]$WixTool = 'wix'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command $WixTool -ErrorAction SilentlyContinue)) {
    throw "WiX CLI '$WixTool' not found. Install it with: dotnet tool install --global wix"
}

$appDir = Join-Path (Split-Path -Parent $RepoDir) "VSCode-win32-$Arch"
if (-not (Test-Path $appDir)) {
    throw "App directory not found: $appDir (run npm run gulp vscode-win32-$Arch-ci first)"
}
if (-not (Test-Path (Join-Path $appDir 'Void.exe'))) {
    throw "Expected main executable not found: $(Join-Path $appDir 'Void.exe')"
}

$product = Get-Content -Raw (Join-Path $RepoDir 'product.json') | ConvertFrom-Json
$package = Get-Content -Raw (Join-Path $RepoDir 'package.json') | ConvertFrom-Json
$version = $package.version
$upgradeCode = "$($product.win32arm64AppId)" # arm64 default
if ($Arch -eq 'x64') { $upgradeCode = "$($product.win32x64AppId)" }
$upgradeCode = $upgradeCode -replace '[\{\}\s]', ''

$outDir = Join-Path $RepoDir '.build\msi'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$scriptDir = Split-Path -Parent $PSScriptRoot   # build\win32\msi
$productWxs = Join-Path $scriptDir 'product.wxs'
$componentsWxs = Join-Path $outDir "components-$Arch.wxs"
$outMsi = Join-Path $outDir "VoidSetup-$Arch-$version.msi"

Write-Host "Harvesting $appDir"
$dirCounter = 0
$fileCounter = 0
$compCounter = 0
$componentRefs = [System.Collections.Generic.List[string]]::new()
$dirElements = [System.Collections.Generic.List[string]]::new()
$componentElements = [System.Collections.Generic.List[string]]::new()

function Get-DirPathIdMap([string]$rel, [string]$parentId) {
    # Returns the WiX directory ID for $rel, creating a Directory entry on the fly.
    $script:dirCounter++
    $id = 'd{0}' -f $script:dirCounter
    $name = Split-Path -Leaf $rel
    $escName = $name.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    $script:dirElements.Add("<DirectoryRef Id=`"$parentId`"><Directory Id=`"$id`" Name=`"$escName`" /></DirectoryRef>")
    return $id
}

function Add-Component([string]$dirId, [string]$relSrcDir) {
    $script:compCounter++
    $compId = 'c{0}' -f $script:compCounter
    $sb = [System.Collections.Generic.List[string]]::new()
    $sb.Add("<DirectoryRef Id=`"$dirId`">")
    $sb.Add("  <Component Id=`"$compId`" Guid=`"*`">")
    Get-ChildItem -LiteralPath (Join-Path $appDir $relSrcDir) -File -Force | ForEach-Object {
        $script:fileCounter++
        $fileId = 'f{0}' -f $script:fileCounter
        $relPath = (Join-Path $relSrcDir $_.Name) -replace '\\', '/'
        $sb.Add("    <File Id=`"$fileId`" Source=`"`$(var.VoidDir)/$relPath`" />")
    }
    $sb.Add("  </Component>")
    $sb.Add("</DirectoryRef>")
    $script:componentElements.Add(($sb -join [Environment]::NewLine))
    $script:componentRefs.Add($compId)
}

# Walk directories: first pass creates Directory tree, second pass fills components.
$rootId = 'INSTALLFOLDER'
$pending = [System.Collections.Generic.Stack[string]]::new()
$pending.Push('')
$idOfRel = @{ '' = $rootId }

while ($pending.Count -gt 0) {
    $rel = $pending.Pop()
    $abs = if ($rel -eq '') { $appDir } else { Join-Path $appDir $rel }
    $thisId = $idOfRel[$rel]

    $subDirs = Get-ChildItem -LiteralPath $abs -Directory -Force
    foreach ($sub in $subDirs) {
        # Skip Windows junction/reparse points that could cause infinite recursion.
        if ($sub.LinkType) { continue }
        $subRel = if ($rel -eq '') { $sub.Name } else { "$rel\$($sub.Name)" }
        $id = Get-DirPathIdMap $subRel $thisId
        $idOfRel[$subRel] = $id
        $pending.Push($subRel)
    }

    $files = Get-ChildItem -LiteralPath $abs -File -Force
    if ($files.Count -gt 0 -and $rel -ne '') {
        Add-Component $thisId $rel
    }
}

# Root-level files (e.g. Void.exe, LICENSE.txt, resources ...) live in INSTALLFOLDER.
$rootFiles = Get-ChildItem -LiteralPath $appDir -File -Force
if ($rootFiles.Count -gt 0) {
    Add-Component $rootId ''
}

$wixNs = 'http://wixtoolset.org/schemas/v4/wxs'
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
[void]$sb.AppendLine("<Wix xmlns=`"$wixNs`">")
[void]$sb.AppendLine('  <Fragment>')
foreach ($d in $dirElements) { [void]$sb.AppendLine("$($d -replace '^','    ')") }
foreach ($c in $componentElements) {
    foreach ($line in ($c -split "`r?`n")) {
        if ($line.Trim().Length -eq 0) { [void]$sb.AppendLine('') }
        else { [void]$sb.AppendLine("    $line") }
    }
}
[void]$sb.AppendLine('    <ComponentGroup Id="VoidComponents">')
foreach ($ref in $componentRefs) { [void]$sb.AppendLine("      <ComponentRef Id=`"$ref`" />") }
[void]$sb.AppendLine('    </ComponentGroup>')
[void]$sb.AppendLine('  </Fragment>')
[void]$sb.AppendLine('</Wix>')

Set-Content -LiteralPath $componentsWxs -Value $sb.ToString() -Encoding utf8
Write-Host "Generated $componentsWxs ($($componentRefs.Count) components, $fileCounter files)"

# Invoke WiX. Preprocessor vars must use forward slashes for cross-path tokens.
$voidDir = ($appDir -replace '\\', '/')
$repoDir = ($RepoDir -replace '\\', '/')
$args = @(
    'build',
    $productWxs,
    $componentsWxs,
    '-arch', $Arch,
    "-d", "VoidVersion=$version",
    "-d", "UpgradeCode=$upgradeCode",
    "-d", "RepoDir=$repoDir",
    "-d", "VoidDir=$voidDir",
    '-o', $outMsi
)

Write-Host "Running: wix $(($args -join ' ') -replace $voidDir, '<appdir>')"
& $WixTool @args
if ($LASTEXITCODE -ne 0) {
    throw "wix build failed with exit code $LASTEXITCODE"
}

Write-Host "MSI created: $outMsi"
Get-Item -LiteralPath $outMsi | Select-Object FullName, Length