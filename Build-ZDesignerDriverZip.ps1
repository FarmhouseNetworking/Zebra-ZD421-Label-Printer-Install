<#
.SYNOPSIS
    Repackages Zebra's ZDesigner v10 driver installer as a plain driver zip that
    pnputil can stage (ZDesigner.inf + catalogs at the root, Common\ Win32\ Win64\ ARM64\).

.DESCRIPTION
    Unpacks the installer with 7-Zip - the installer is never run and nothing is
    installed on this PC. Writes ZDesigner_v<version>_driver.zip and prints the
    settings to paste into Install-ZebraLabelPrinter.ps1.

.EXAMPLE
    .\Build-ZDesignerDriverZip.ps1 -InstallerPath .\zddriver-v1062628275-certified.zip
#>
param(
    # Zebra's zddriver-v...-certified.exe, or the .zip Zebra ships it in
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [string]$OutputDir = (Get-Location).Path,
    [string]$SevenZip  = 'C:\Program Files\7-Zip\7z.exe'
)

$ErrorActionPreference = 'Stop'

function Get-PEArchitecture {
    param([string]$Path)
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $fs.Position = $br.ReadInt32() + 4
        switch ($br.ReadUInt16()) {
            0x014C  { 'Win32' }
            0x8664  { 'Win64' }
            0xAA64  { 'ARM64' }
            default { $null }
        }
    }
    finally { $fs.Dispose() }
}

if (-not (Test-Path $SevenZip))      { throw "7-Zip not found at $SevenZip. Install 7-Zip or pass -SevenZip." }
if (-not (Test-Path $InstallerPath)) { throw "Installer not found: $InstallerPath" }

$work = Join-Path ([IO.Path]::GetTempPath()) ("zdbuild_" + [Guid]::NewGuid().ToString('N'))
New-Item -Path $work -ItemType Directory | Out-Null

try {
    # Zebra ships the installer inside a zip
    $installer = (Resolve-Path $InstallerPath).Path
    if ([IO.Path]::GetExtension($installer) -eq '.zip') {
        Expand-Archive -Path $installer -DestinationPath (Join-Path $work 'zip')
        $inner = Get-ChildItem (Join-Path $work 'zip') -Recurse -Filter *.exe | Select-Object -First 1
        if (-not $inner) { throw "No .exe found inside $installer" }
        $installer = $inner.FullName
    }

    $raw = Join-Path $work 'raw'
    & $SevenZip x $installer "-o$raw" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip could not unpack $installer (exit code $LASTEXITCODE)" }

    $inf = Get-ChildItem $raw -Recurse -Filter ZDesigner.inf | Select-Object -First 1
    if (-not $inf) { throw 'ZDesigner.inf not found in the installer. Is this the ZDesigner v10 driver?' }
    $infText = Get-Content $inf.FullName

    $verLine = $infText | Where-Object { $_ -match '^\s*DriverVer\s*=' } | Select-Object -First 1
    if ($verLine -notmatch ',\s*([\d\.]+)') { throw 'Could not read DriverVer from ZDesigner.inf' }
    $version = $Matches[1]
    $name    = "ZDesigner_v${version}_driver"
    $pkg     = Join-Path $work $name
    New-Item -Path $pkg -ItemType Directory | Out-Null

    # INF and catalogs go at the root
    Copy-Item $inf.FullName $pkg
    $cats = $infText | Where-Object { $_ -match '^\s*CatalogFile[\.\w]*\s*=\s*(\S+)' } | ForEach-Object { $Matches[1] } | Sort-Object -Unique
    foreach ($cat in $cats) {
        $file = Get-ChildItem $raw -Recurse -Filter $cat | Select-Object -First 1
        if (-not $file) { throw "Catalog $cat not found in the installer" }
        Copy-Item $file.FullName $pkg
    }

    # [SourceDisksFiles]: "= 1" files live in Common\, "= 2" files in the per-architecture folder
    $inSection = $false; $commonFiles = @(); $archFiles = @()
    foreach ($line in $infText) {
        if ($line -match '^\s*\[(.+?)\]') { $inSection = ($Matches[1] -eq 'SourceDisksFiles'); continue }
        if ($inSection -and $line -match '^\s*([^;=]+?)\s*=\s*(\d+)') {
            if ($Matches[2] -eq '1') { $commonFiles += $Matches[1] }
            if ($Matches[2] -eq '2') { $archFiles   += $Matches[1] }
        }
    }
    if (-not $commonFiles -or -not $archFiles) { throw 'Could not read [SourceDisksFiles] from ZDesigner.inf' }

    $commonDir = Join-Path $pkg 'Common'
    New-Item -Path $commonDir -ItemType Directory | Out-Null
    $commonSource = (Get-ChildItem $raw -Recurse -Filter $commonFiles[0] | Select-Object -First 1).DirectoryName
    if (-not $commonSource) { throw "Common file $($commonFiles[0]) not found in the installer" }
    Copy-Item (Join-Path $commonSource '*') $commonDir
    foreach ($f in $commonFiles) {
        if (-not (Test-Path (Join-Path $commonDir $f))) { throw "Common file missing after copy: $f" }
    }

    # One folder per architecture, identified by the PE header of the driver DLL
    $found = @{}
    foreach ($dll in Get-ChildItem $raw -Recurse -Filter $archFiles[0]) {
        $arch = Get-PEArchitecture $dll.FullName
        if (-not $arch -or $found[$arch]) { continue }
        $found[$arch] = $true
        $dest = Join-Path $pkg $arch
        New-Item -Path $dest -ItemType Directory | Out-Null
        foreach ($f in $archFiles) {
            $src = Join-Path $dll.DirectoryName $f
            if (-not (Test-Path $src)) { throw "$arch file missing in the installer: $f" }
            Copy-Item $src $dest
        }
    }
    if (-not $found['Win64']) { throw 'No 64-bit driver files found in the installer' }

    $zip = Join-Path (Resolve-Path $OutputDir).Path "$name.zip"
    if (Test-Path $zip) { throw "$zip already exists. Move or delete it first." }
    Compress-Archive -Path (Join-Path $pkg '*') -DestinationPath $zip -CompressionLevel Optimal

    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
    Write-Output "Built $zip"
    Write-Output "Architectures: $(($found.Keys | Sort-Object) -join ', ')"
    Write-Output ''
    Write-Output 'Paste into the Settings block of Install-ZebraLabelPrinter.ps1:'
    Write-Output "`$DriverUrl    = '<the URL where you host $name.zip>'"
    Write-Output "`$DriverSha256 = '$hash'"
    Write-Output "`$PackageName  = '$name'"
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
