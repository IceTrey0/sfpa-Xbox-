<#
  Packages the Super Fancy Pants Adventure Windows build as a sideloadable MSIX.
  Run in Windows PowerShell. Needs the Windows 10/11 SDK (makeappx.exe, signtool.exe).

  Usage:
    .\Build-SFPA-Msix.ps1 -GameDir "C:\Games\Super Fancy Pants Adventure"
    .\Build-SFPA-Msix.ps1 -GameDir "C:\Games\Super Fancy Pants Adventure" -Install   # run as Administrator
#>
param(
  [Parameter(Mandatory)] [string]$GameDir,
  [string]$OutDir = "$PSScriptRoot\out",
  [string]$PfxPassword = "sfpa-dev",
  [switch]$Install
)
$ErrorActionPreference = "Stop"
$Subject = "CN=SFPADev"   # must match Publisher in AppxManifest.xml

if (-not (Test-Path (Join-Path $GameDir "SFPA.exe"))) { throw "SFPA.exe not found in '$GameDir'" }

# --- locate SDK tools (newest SDK wins) ---
$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory |
       Where-Object Name -match '^10\.' | Sort-Object Name -Descending
$makeappx = $sdk | ForEach-Object { Join-Path $_.FullName "x64\makeappx.exe" } | Where-Object { Test-Path $_ } | Select-Object -First 1
$signtool = $sdk | ForEach-Object { Join-Path $_.FullName "x64\signtool.exe" }  | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $makeappx -or -not $signtool) { throw "Windows SDK not found. Install it (Visual Studio Installer > Windows SDK)." }

# --- stage the package contents ---
$stage = Join-Path $OutDir "stage"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item $stage -ItemType Directory -Force | Out-Null

# Skip the macOS bundle and the .fla level sources; they're dead weight on Windows.
robocopy $GameDir $stage /E /XD "SFPA.app" /XF "*.fla" /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }

Copy-Item "$PSScriptRoot\AppxManifest.xml" $stage -Force
Copy-Item "$PSScriptRoot\Assets" (Join-Path $stage "Assets") -Recurse -Force

# --- self-signed dev cert ---
$pfx = Join-Path $OutDir "SFPADev.pfx"
$cer = Join-Path $OutDir "SFPADev.cer"
if (-not (Test-Path $pfx)) {
  $cert = New-SelfSignedCertificate -Type Custom -Subject $Subject -KeyUsage DigitalSignature `
          -FriendlyName "SFPA Dev" -CertStoreLocation "Cert:\CurrentUser\My" `
          -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
  $pw = ConvertTo-SecureString $PfxPassword -AsPlainText -Force
  Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pw | Out-Null
  Export-Certificate    -Cert $cert -FilePath $cer | Out-Null
}

# --- pack + sign ---
$msix = Join-Path $OutDir "SuperFancyPantsAdventure.msix"
if (Test-Path $msix) { Remove-Item $msix -Force }
& $makeappx pack /d $stage /p $msix /o
if ($LASTEXITCODE) { throw "makeappx failed" }
& $signtool sign /fd SHA256 /f $pfx /p $PfxPassword $msix
if ($LASTEXITCODE) { throw "signtool failed" }
Write-Host "Built: $msix"

# --- optional install (needs admin to trust the cert) ---
if ($Install) {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole("Administrator")
  if (-not $isAdmin) { throw "Re-run as Administrator to use -Install." }
  Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
  Add-AppxPackage $msix
  Write-Host "Installed. Launch 'Super Fancy Pants Adventure' from the Start menu."
}
