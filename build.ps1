# ============================================================================
# SmartNIC Simulation Runner (PowerShell)
# ============================================================================
# Usage:
#   .\build.ps1 parser        Run Packet Parser testbench
#   .\build.ps1 classifier    Run Flow Classifier testbench
#   .\build.ps1 queue         Run Queue Manager testbench
#   .\build.ps1 scheduler     Run Scheduler testbench (includes Queue Manager)
#   .\build.ps1 all           Run all testbenches
#   .\build.ps1 clean         Remove simulation artifacts
#   .\build.ps1 genpackets    Generate test packets via Python
#
# Prerequisites: Icarus Verilog (iverilog.exe, vvp.exe) must be on PATH
#   Install: https://bleyer.org/icarus/  (Windows installer)
# ============================================================================

param(
    [Parameter(Position=0)]
    [ValidateSet("parser", "classifier", "queue", "scheduler", "pipeline", "all", "clean", "genpackets")]
    [string]$Target = "all"
)

$ErrorActionPreference = "Stop"

# Directories
$RTL_DIR    = "rtl"
$TB_DIR     = "tb"
$SIM_DIR    = "sim"
$SCRIPT_DIR = "scripts"

# Include path
$INC_FLAGS = "-I$RTL_DIR\common"

# Ensure sim directory exists
if (!(Test-Path $SIM_DIR)) { New-Item -ItemType Directory -Path $SIM_DIR | Out-Null }

function Run-Sim {
    param(
        [string]$Name,
        [string[]]$Sources,
        [string]$OutputVvp
    )

    Write-Host ""
    Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Running: $Name" -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan

    $allSources = $Sources -join " "
    $compileCmd = "iverilog -g2012 -o $OutputVvp $INC_FLAGS $allSources"
    Write-Host "  Compile: $compileCmd" -ForegroundColor DarkGray

    try {
        Invoke-Expression $compileCmd
        if ($LASTEXITCODE -ne 0) { throw "Compilation failed" }
    } catch {
        Write-Host "  ERROR: Compilation failed!" -ForegroundColor Red
        Write-Host "  Make sure Icarus Verilog is installed:" -ForegroundColor Yellow
        Write-Host "  https://bleyer.org/icarus/" -ForegroundColor Yellow
        return $false
    }

    Write-Host "  Simulate: vvp $OutputVvp" -ForegroundColor DarkGray
    Push-Location $SIM_DIR
    try {
        $vvpFile = Split-Path $OutputVvp -Leaf
        vvp $vvpFile
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed" }
    } finally {
        Pop-Location
    }

    return $true
}

switch ($Target) {
    "parser" {
        Run-Sim -Name "Packet Parser" `
            -Sources @("$RTL_DIR\parser\packet_parser.v", "$TB_DIR\parser\tb_packet_parser.v") `
            -OutputVvp "$SIM_DIR\parser_sim.vvp"
    }

    "classifier" {
        Run-Sim -Name "Flow Classifier" `
            -Sources @("$RTL_DIR\classifier\flow_classifier.v", "$TB_DIR\classifier\tb_flow_classifier.v") `
            -OutputVvp "$SIM_DIR\classifier_sim.vvp"
    }

    "queue" {
        Run-Sim -Name "Queue Manager" `
            -Sources @("$RTL_DIR\queue\queue_manager.v", "$TB_DIR\queue\tb_queue_manager.v") `
            -OutputVvp "$SIM_DIR\queue_sim.vvp"
    }

    "scheduler" {
        Run-Sim -Name "Priority Scheduler" `
            -Sources @(
                "$RTL_DIR\queue\queue_manager.v",
                "$RTL_DIR\scheduler\priority_scheduler.v",
                "$TB_DIR\scheduler\tb_priority_scheduler.v"
            ) `
            -OutputVvp "$SIM_DIR\scheduler_sim.vvp"
    }

    "pipeline" {
        Run-Sim -Name "Full Pipeline" `
            -Sources @(
                "$RTL_DIR\parser\packet_parser.v",
                "$RTL_DIR\classifier\flow_classifier.v",
                "$RTL_DIR\queue\queue_manager.v",
                "$RTL_DIR\scheduler\priority_scheduler.v",
                "$TB_DIR\integration\tb_smartnic_pipeline.v"
            ) `
            -OutputVvp "$SIM_DIR\pipeline_sim.vvp"
    }

    "all" {
        $results = @()
        foreach ($t in @("parser", "classifier", "queue", "scheduler")) {
            & $PSCommandPath $t
        }
    }

    "clean" {
        Write-Host "Cleaning simulation artifacts..."
        Get-ChildItem $SIM_DIR -Include *.vvp, *.vcd -Recurse | Remove-Item -Force
        Write-Host "Done."
    }

    "genpackets" {
        python $SCRIPT_DIR\gen_packets.py --output $SIM_DIR --count 20
    }
}
