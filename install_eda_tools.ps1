# ============================================================================
# Open Source EDA & RTL-to-GDSII Toolchain Installer for Windows
# ============================================================================
# This script automates the downloading and installation of the open-source
# hardware design ecosystem into D:\softwares.
#
# Tools included:
# 1. OSS CAD Suite:
#    - Yosys (Synthesis)
#    - Icarus Verilog & Verilator (Simulation)
#    - GTKWave (Waveform Viewer)
#    - NextPNR (FPGA Place & Route)
#    - OpenFPGALoader (FPGA flashing)
# 2. xPack RISC-V GNU Toolchain:
#    - gcc, objdump, gdb (For compiling the RISC-V control plane firmware)
# 3. KLayout:
#    - High-performance GDSII/OASIS layout viewer and editor
#
# Note: A full ASIC RTL-to-GDSII flow (like OpenLane) heavily relies on Linux
# tools (Magic, OpenROAD). OSS CAD Suite provides the core RTL tools for Windows natively.
# If you need full ASIC tapeout flow on Windows, running OpenLane via Docker/WSL2
# is highly recommended.
# ============================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue' # Speeds up Invoke-WebRequest significantly

$InstallDir = "D:\softwares"
if (!(Test-Path $InstallDir)) {
    Write-Host "Creating directory $InstallDir..."
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Installing EDA Tools to $InstallDir" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan

# --- 1. OSS CAD Suite (Yosys, Icarus, Verilator, GTKWave, etc.) ---
Write-Host "`n[1/3] Fetching OSS CAD Suite latest release..." -ForegroundColor Yellow
try {
    # Using GitHub API to dynamically find the latest Windows release
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases?per_page=10"
    $ossAsset = $null
    foreach ($r in $releases) {
        $ossAsset = $r.assets | Where-Object { $_.name -match "windows-x64.*\.exe$" } | Select-Object -First 1
        if ($ossAsset) { break }
    }
    
    if ($ossAsset) {
        $ossUrl = $ossAsset.browser_download_url
        $ossFile = Join-Path $InstallDir $ossAsset.name
        
        Write-Host "  -> Downloading $($ossAsset.name) ($([math]::Round($ossAsset.size / 1MB, 2)) MB)..."
        Invoke-WebRequest -Uri $ossUrl -OutFile $ossFile
        
        Write-Host "  -> Extracting OSS CAD Suite (running self-extractor)..."
        Push-Location $InstallDir
        # The .exe is a 7zip self-extractor. -y accepts all prompts.
        $process = Start-Process -FilePath $ossFile -ArgumentList "-y" -Wait -NoNewWindow -PassThru
        Pop-Location
        
        if ($process.ExitCode -eq 0) {
            Write-Host "  -> OSS CAD Suite installed successfully." -ForegroundColor Green
            # Clean up installer
            Remove-Item $ossFile -Force
        } else {
            Write-Host "  -> Warning: Extractor exited with code $($process.ExitCode)" -ForegroundColor Red
        }
    } else {
        Write-Host "  -> Could not find OSS CAD Suite Windows asset." -ForegroundColor Red
    }
} catch {
    Write-Host "  -> Failed to install OSS CAD Suite: $_" -ForegroundColor Red
}

# --- 2. xPack RISC-V Toolchain ---
Write-Host "`n[2/3] Fetching xPack RISC-V GCC latest release..." -ForegroundColor Yellow
try {
    $rvRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/latest"
    $rvAsset = $rvRelease.assets | Where-Object { $_.name -match "win32-x64\.zip$" } | Select-Object -First 1
    
    if ($rvAsset) {
        $rvUrl = $rvAsset.browser_download_url
        $rvFile = Join-Path $InstallDir $rvAsset.name
        
        Write-Host "  -> Downloading $($rvAsset.name) ($([math]::Round($rvAsset.size / 1MB, 2)) MB)..."
        Invoke-WebRequest -Uri $rvUrl -OutFile $rvFile
        
        Write-Host "  -> Extracting RISC-V Toolchain..."
        Expand-Archive -Path $rvFile -DestinationPath $InstallDir -Force
        
        Write-Host "  -> RISC-V Toolchain installed successfully." -ForegroundColor Green
        Remove-Item $rvFile -Force
    } else {
        Write-Host "  -> Could not find RISC-V Windows asset." -ForegroundColor Red
    }
} catch {
    Write-Host "  -> Failed to install RISC-V Toolchain: $_" -ForegroundColor Red
}

# --- 3. KLayout ---
Write-Host "`n[3/3] Fetching KLayout (GDSII Viewer/Editor)..." -ForegroundColor Yellow
try {
    # We will use the latest stable version 0.30.9
    $klVersion = "0.30.9"
    $klUrl = "https://www.klayout.org/downloads/Windows/klayout-$klVersion-win64.zip"
    $klFile = Join-Path $InstallDir "klayout-$klVersion-win64.zip"
    $klDest = Join-Path $InstallDir "klayout"
    
    Write-Host "  -> Downloading KLayout v$klVersion..."
    Invoke-WebRequest -Uri $klUrl -OutFile $klFile
    
    Write-Host "  -> Extracting KLayout..."
    if (Test-Path $klDest) { Remove-Item -Recurse -Force $klDest }
    Expand-Archive -Path $klFile -DestinationPath $klDest -Force
    
    Write-Host "  -> KLayout installed successfully." -ForegroundColor Green
    Remove-Item $klFile -Force
} catch {
    Write-Host "  -> Failed to install KLayout: $_" -ForegroundColor Red
}

# --- 4. Add to PATH Environment Variable ---
Write-Host "`nSetting up Environment Variables..." -ForegroundColor Yellow
$UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
$PathsToAdd = @()

# Add OSS CAD Suite bin paths
$ossBin = Join-Path $InstallDir "oss-cad-suite\bin"
$ossPyBin = Join-Path $InstallDir "oss-cad-suite\py3bin"
if (Test-Path $ossBin) { $PathsToAdd += $ossBin }
if (Test-Path $ossPyBin) { $PathsToAdd += $ossPyBin }

# Add RISC-V Toolchain bin path
$rvBinDir = Get-ChildItem -Path $InstallDir -Filter "xpack-riscv-none-elf-gcc-*" -Directory | Select-Object -First 1
if ($rvBinDir) {
    $PathsToAdd += Join-Path $rvBinDir.FullName "bin"
}

# Add KLayout path
$klBin = Join-Path $InstallDir "klayout"
if (Test-Path $klBin) { $PathsToAdd += $klBin }

$PathModified = $false
foreach ($p in $PathsToAdd) {
    if ($UserPath -notmatch [regex]::Escape($p)) {
        $UserPath += ";$p"
        $PathModified = $true
    }
}

if ($PathModified) {
    [Environment]::SetEnvironmentVariable("PATH", $UserPath, "User")
    Write-Host "  -> Added tools to User PATH." -ForegroundColor Green
    Write-Host "  -> IMPORTANT: You MUST restart your terminal (or VS Code) for the new PATH to take effect!" -ForegroundColor Red
} else {
    Write-Host "  -> PATH already contains the tool directories. No changes made." -ForegroundColor Green
}

Write-Host "`n════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Installation Complete!" -ForegroundColor Cyan
Write-Host " You now have Yosys, Icarus Verilog, Verilator, GTKWave,"
Write-Host " the RISC-V GCC Toolchain, and KLayout installed in $InstallDir"
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
