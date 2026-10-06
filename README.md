# Zebra ZD421 Label Printer Install

Silent, re-runnable RMM install of a networked Zebra ZD421 (300 dpi, ZPL) label
printer and the ZebraDesigner 3 label design software. Written for the SuperOps agent
running as `SYSTEM`, but it is plain PowerShell and works from any RMM.

## What it does

1. Skips all driver work if the driver is already installed.
2. Downloads a plain ZDesigner driver zip from a web server **you host** (see
   [Hosting the driver zip](#hosting-the-driver-zip)) and checks its SHA256.
3. Stages the driver with `pnputil` and registers it with `Add-PrinterDriver`.
4. Creates a Standard TCP/IP port (RAW, 9100) and the printer for each entry in
   `$Printers`. Ports and printers that already exist are left alone.
5. Installs ZebraDesigner 3 with Chocolatey (`choco install zebradesigner`), unless
   ZebraDesigner is already installed.

Exit code is `0` on success and `1` on any failure, with the reason written to the
script output so the RMM shows it.

## Why the driver comes from your own server

Zebra's driver download cannot be used directly from a script:

- Zebra's download links are signed and expire about an hour after they are issued.
- The download is an installer (`zddriver-v...-certified.exe`), not driver files that
  `pnputil` can stage.

So the driver is repackaged once into a plain driver zip (`ZDesigner.inf` and the
catalogs at the root, with `Common\`, `Win32\`, `Win64\` and `ARM64\` beneath) and
hosted somewhere your endpoints can reach.

The driver zip is **not** included in this repository. It is Zebra's software; get it
from Zebra and host your own copy.

## Hosting the driver zip

The script ships pointing at the author's copy. **Replace that URL with your own** -
do not depend on someone else's web server for your deployments.

1. **Download the driver from Zebra.** Go to the ZD421 support page on zebra.com and
   download the "ZDesigner Windows Printer Driver" (v10). You get
   `zddriver-v<version>-certified.zip`, which contains the installer `.exe`.

2. **Build the plain driver zip.** On a PC with [7-Zip](https://www.7-zip.org/)
   installed, run the helper in this repo. It unpacks the installer without running
   it; nothing is installed on that PC.

   ```powershell
   .\Build-ZDesignerDriverZip.ps1 -InstallerPath .\zddriver-v1062628275-certified.zip
   ```

   It writes `ZDesigner_v<version>_driver.zip` to the current folder and prints the
   three settings you need, for example:

   ```
   $DriverSha256 = 'DC2AE02C...'
   $PackageName  = 'ZDesigner_v10.6.26.28275_driver'
   ```

   The SHA256 is different every time the zip is built, even from the same installer,
   so always use the value printed for the zip you are actually going to host.

3. **Upload the zip** to a web server your endpoints can reach over HTTPS with no
   login: your own website, a storage bucket with a public link, or similar. Wait for
   the upload to finish before testing - a partial upload fails the hash check.

4. **Edit the `Settings` block** at the top of `Install-ZebraLabelPrinter.ps1`:

   ```powershell
   $DriverUrl    = 'https://your-server.example.com/downloads/ZDesigner_v10.6.26.28275_driver.zip'
   $DriverSha256 = '<value printed by the helper>'
   $PackageName  = 'ZDesigner_v10.6.26.28275_driver'
   ```

5. **Confirm the hosted file** matches before you deploy:

   ```powershell
   Invoke-WebRequest '<your URL>' -OutFile "$env:TEMP\zd.zip" -UseBasicParsing
   (Get-FileHash "$env:TEMP\zd.zip" -Algorithm SHA256).Hash
   ```

   The result must equal `$DriverSha256`.

Repeat steps 1 to 5 whenever you move the file or update to a newer driver version.

## Set the printer IP address first

The script ships with a placeholder where the label printer's IP address goes. It
stops with an error until you replace it, so nothing is installed against a wrong
address.

1. Find the printer's IPv4 address: print a configuration label at the printer, or look
   it up in your DHCP server. Make the address static on the printer, or reserve it in
   DHCP, so it never changes.
2. Open `Install-ZebraLabelPrinter.ps1` and find this line in the `Settings` block:

   ```powershell
   $LabelPrinterIP = 'LABEL-PRINTER-IP'
   ```

3. Replace only the text between the quotes with the address. Keep the quotes.
4. In the `$Printers` list, change `Name` to what users should see and `PortName` to
   any label you like for the port (the printer's host name works well). Leave
   `IP = $LabelPrinterIP` as it is.

To add a second label printer, add a variable for its address and a matching line in
`$Printers`:

```powershell
$LabelPrinter2IP = 'LABEL-PRINTER-2-IP'

$Printers = @(
    @{ Name = 'Zebra Cas labels';   PortName = 'ZEBRA-LAN-LOT-LAB'; IP = $LabelPrinterIP }
    @{ Name = 'Zebra Shipping';     PortName = 'ZEBRA-SHIPPING';    IP = $LabelPrinter2IP }
)
```

Set the real address only in the copy of the script you paste into your RMM. Do not
commit it to a public copy of this repository.

## Configuration

Everything is in the `Settings` block at the top of `Install-ZebraLabelPrinter.ps1`.

| Setting | Meaning |
|---|---|
| `$SupportDir` | Working folder on the endpoint. Default `C:\Support`. |
| `$DriverUrl` | Where **you** host the plain driver zip. |
| `$DriverSha256` | SHA256 of that zip. Set to `''` to skip the check (not recommended). |
| `$PackageName` | The zip file name without `.zip`. Also used as the unpack folder name. |
| `$DriverName` | Driver name exactly as written in `ZDesigner.inf`. |
| `$LabelPrinterIP` | IP address of the label printer. **Placeholder - you must replace it.** |
| `$Printers` | One entry per printer: display `Name`, `PortName`, and `IP`. |
| `$ChocoPackage` | Chocolatey package for ZebraDesigner. Default `zebradesigner`. |
| `$InstallChocoIfMissing` | `$true` installs Chocolatey when it is absent; `$false` fails instead. |

Printer IP addresses must be static or DHCP-reserved.

### Other Zebra models

The same driver zip covers the whole ZDesigner v10 family. Change `$DriverName` to the
model string from `ZDesigner.inf`, for example `ZDesigner ZD621-300dpi ZPL` or
`ZDesigner ZT411-203dpi ZPL`.

The name a Zebra printer reports about itself starts with `ZTC` (for example
`ZTC ZD421-300dpi ZPL`). That is not the driver name. The driver name starts with
`ZDesigner`.

## Deployment

Add it as a SuperOps custom script and run it as `SYSTEM`. SuperOps injects
`$SuperOpsModule` at runtime, which the first line imports. On another RMM, delete
that `Import-Module` line.

## Troubleshooting

- **`Printer IP for '<name>' is not set`:** the placeholder is still in the `Settings`
  block, or the value is not a valid IPv4 address. See
  [Set the printer IP address first](#set-the-printer-ip-address-first).
- **`Hash mismatch`:** the hosted zip is not the one `$DriverSha256` was taken from.
  Usual causes are an upload that had not finished, or a rebuilt zip without an
  updated hash.
- **`No INF under ... defines '<name>'`:** `$DriverName` does not match
  `ZDesigner.inf`, or the zip does not have the INF at its root.
- **`choco install ... failed`:** run `choco install zebradesigner -y` by hand on the
  endpoint to see Chocolatey's own error.

## Requirements

- Windows 10 / 11, Windows PowerShell 5.1
- Run elevated (`SYSTEM` or an administrator)
- Outbound HTTPS to your driver host and to `community.chocolatey.org` / `zebra.com`
- 7-Zip, only on the PC where you build the driver zip
