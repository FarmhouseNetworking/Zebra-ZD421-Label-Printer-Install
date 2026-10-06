# Zebra ZD421 label printer + ZebraDesigner 3 - silent install for RMM
# Run as SYSTEM from SuperOps. Safe to re-run: anything already present is skipped.

Import-Module $SuperOpsModule

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # progress bar makes Invoke-WebRequest very slow in PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- Settings ---------------------------------------------------------------
$SupportDir = 'C:\Support'

# ZDesigner v10.6.26.28275 driver, repackaged from Zebra's installer as a plain driver folder
# (ZDesigner.inf + .cat at the root, Common\ Win32\ Win64\ ARM64\ beneath).
# REPLACE this URL with a copy you host yourself - see "Hosting the driver zip" in README.md.
$DriverUrl    = 'https://www.farmhousenetworking.com/downloads/ZDesigner_v10.6.26.28275_driver.zip'
$DriverSha256 = 'DC2AE02CFAAA2A7C55647B1179F12344893797F5346BBB1FBE8ECE244FE5DBD5'
$PackageName  = 'ZDesigner_v10.6.26.28275_driver'
$DriverName   = 'ZDesigner ZD421-300dpi ZPL'      # driver name exactly as written in ZDesigner.inf

# Printer IP address - REPLACE the placeholder below with the label printer's IPv4 address.
# Change only the text between the quotes and keep the quotes. The address must be
# static on the printer or reserved in DHCP. The script stops with an error while the
# placeholder is still in place. See "Set the printer IP address first" in README.md.
$LabelPrinterIP = 'LABEL-PRINTER-IP'

# One line per printer. Name is what users see; PortName is the label Windows gives the port.
$Printers = @(
    @{ Name = 'Zebra Cas labels'; PortName = 'ZEBRA-LAN-LOT-LAB'; IP = $LabelPrinterIP }
)

# ZebraDesigner 3 comes from Chocolatey
$ChocoPackage          = 'zebradesigner'
$InstallChocoIfMissing = $true                    # $false = fail instead of installing Chocolatey
# -----------------------------------------------------------------------------

function Get-ChocoPath {
    $cmd = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $default = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
    if (Test-Path $default) { return $default }
    return $null
}

try {
    # ---- Stop early if a printer IP placeholder was not replaced ----
    foreach ($p in $Printers) {
        $parsedIp = $null
        if ($p.IP -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [System.Net.IPAddress]::TryParse($p.IP, [ref]$parsedIp)) {
            throw "Printer IP for '$($p.Name)' is not set. Replace the placeholder '$($p.IP)' in the Settings block with that printer's IP address."
        }
    }

    # ---- Driver (skipped if already installed) ----
    if (Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue) {
        Write-Output "Driver '$DriverName' already installed - skipping download."
    }
    else {
        if ($DriverUrl -notmatch '^https?://') { throw 'Driver download URL has not been set.' }
        if (-not (Test-Path $SupportDir)) { New-Item -Path $SupportDir -ItemType Directory -Force | Out-Null }

        $zip = Join-Path $SupportDir "$PackageName.zip"
        $dir = Join-Path $SupportDir $PackageName

        Write-Output "Downloading $DriverUrl"
        Invoke-WebRequest -Uri $DriverUrl -OutFile $zip -UseBasicParsing

        if ($DriverSha256) {
            $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
            if ($actual -ne $DriverSha256) { throw "Hash mismatch on $zip. Expected $DriverSha256, got $actual." }
        }

        Expand-Archive -Path $zip -DestinationPath $dir -Force

        $hit = Get-ChildItem -Path $dir -Recurse -Filter *.inf |
            Select-String -SimpleMatch -Pattern "`"$DriverName`"" -List |
            Select-Object -First 1
        if (-not $hit) { throw "No INF under $dir defines '$DriverName'." }

        Write-Output "Staging driver from $($hit.Path)"
        & pnputil.exe /add-driver $hit.Path /install | Out-String | Write-Output
        # 0 = added, 259 = already in the driver store, 3010 = added, reboot pending
        if ($LASTEXITCODE -notin 0, 259, 3010) { throw "pnputil failed with exit code $LASTEXITCODE" }

        Add-PrinterDriver -Name $DriverName
        Write-Output "Driver '$DriverName' installed."
        Remove-Item -Path $zip -Force -ErrorAction SilentlyContinue
    }

    # ---- Port and printer (each skipped if already present) ----
    $failed = 0
    foreach ($p in $Printers) {
        try {
            if (-not (Get-PrinterPort -Name $p.PortName -ErrorAction SilentlyContinue)) {
                Add-PrinterPort -Name $p.PortName -PrinterHostAddress $p.IP -PortNumber 9100
            }

            if (Get-Printer -Name $p.Name -ErrorAction SilentlyContinue) {
                Write-Output "Printer '$($p.Name)' already exists - skipping."
            }
            else {
                Add-Printer -Name $p.Name -DriverName $DriverName -PortName $p.PortName
                Write-Output "Printer '$($p.Name)' added on $($p.IP)."
            }
        }
        catch {
            $failed++
            Write-Output "FAILED: '$($p.Name)' ($($p.IP)) - $($_.Exception.Message)"
        }
    }
    if ($failed) { throw "$failed of $($Printers.Count) printers failed." }

    # ---- ZebraDesigner 3 via Chocolatey (skipped if already installed) ----
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $installed = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'ZebraDesigner*' } |
        Select-Object -First 1

    if ($installed) {
        Write-Output "$($installed.DisplayName) $($installed.DisplayVersion) already installed - skipping."
    }
    else {
        $choco = Get-ChocoPath
        if (-not $choco) {
            if (-not $InstallChocoIfMissing) { throw 'Chocolatey is not installed on this machine.' }

            Write-Output 'Chocolatey not found - installing it.'
            Set-ExecutionPolicy Bypass -Scope Process -Force
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) |
                Out-String | Write-Output
            $choco = Get-ChocoPath
            if (-not $choco) { throw 'Chocolatey install did not produce choco.exe.' }
        }

        Write-Output "Installing $ChocoPackage with Chocolatey..."
        & $choco install $ChocoPackage -y --no-progress | Out-String | Write-Output
        # 0 = installed, 1641 / 3010 = installed, reboot initiated / pending
        if ($LASTEXITCODE -notin 0, 1641, 3010) { throw "choco install $ChocoPackage failed with exit code $LASTEXITCODE" }
        Write-Output 'ZebraDesigner installed.'
    }

    Write-Output 'Done.'
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 1
}
