param(
  [Parameter(Mandatory)] [string]$GameDir,
  [string]$OutDir = "$PSScriptRoot\out",
  [string]$PfxPassword = "sfpa-dev",
  [switch]$Install
)
$ErrorActionPreference = "Stop"
$Subject = "CN=SFPADev"

if (-not (Test-Path (Join-Path $GameDir "SFPA.exe"))) { throw "SFPA.exe not found in '$GameDir'" }

$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory |
       Where-Object Name -match '^10\.' | Sort-Object Name -Descending
$makeappx = $sdk | ForEach-Object { Join-Path $_.FullName "x64\makeappx.exe" } | Where-Object { Test-Path $_ } | Select-Object -First 1
$signtool = $sdk | ForEach-Object { Join-Path $_.FullName "x64\signtool.exe" }  | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $makeappx -or -not $signtool) { throw "Windows SDK not found." }

$stage = Join-Path $OutDir "stage"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item $stage -ItemType Directory -Force | Out-Null

robocopy $GameDir $stage /E /XD "SFPA.app" /XF "*.fla" /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }

Copy-Item "$PSScriptRoot\AppxManifest.xml" $stage -Force

# --- make logos straight into the package folder ---
Add-Type -AssemblyName System.Drawing
$assets = Join-Path $stage "Assets"
New-Item $assets -ItemType Directory -Force | Out-Null
$src = [System.Drawing.Image]::FromFile((Join-Path $GameDir "icons\Icon-128.png"))
function Save-Logo($name, $w, $h, $s) {
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.DrawImage($src, [int](($w-$s)/2), [int](($h-$s)/2), $s, $s)
  $g.Dispose()
  $bmp.Save((Join-Path $assets $name), [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}
Save-Logo "StoreLogo.png" 50 50 50
Save-Logo "Square44x44Logo.png" 44 44 44
Save-Logo "Square150x150Logo.png" 150 150 150
Save-Logo "Wide310x150Logo.png" 310 150 130
$src.Dispose()
Write-Host "Assets in package:"; Get-ChildItem $assets | ForEach-Object { Write-Host "  $($_.Name)" }

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

$msix = Join-Path $OutDir "SuperFancyPantsAdventure.msix"
if (Test-Path $msix) { Remove-Item $msix -Force }
& $makeappx pack /d $stage /p $msix /o
if ($LASTEXITCODE) { throw "makeappx failed" }
& $signtool sign /fd SHA256 /f $pfx /p $PfxPassword $msix
if ($LASTEXITCODE) { throw "signtool failed" }
Write-Host "Built: $msix"

if ($Install) {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole("Administrator")
  if (-not $isAdmin) { throw "Re-run as Administrator to use -Install." }
  Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
  Add-AppxPackage $msix
  Write-Host "Installed."
}
