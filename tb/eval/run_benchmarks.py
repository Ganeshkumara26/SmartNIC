#!/usr/bin/env python3
"""
Performance Evaluation Framework Orchestrator
-------------------------------------------
Compiles the SmartNIC top-level evaluation testbench and loops through
the benchmark scenarios, saving the resulting CSV files for visualization.
"""

import os
import subprocess
import shutil

# Verilog source files required for the full datapath
RTL_COMMON = "../../rtl/common"
RTL_FILES = [
    "../../rtl/top/smartnic_top.v",
    "../../rtl/control/axilite_csr.v",
    "../../rtl/control/stats_engine.v",
    "../../rtl/parser/packet_parser.v",
    "../../rtl/classifier/flow_classifier.v",
    "../../rtl/classifier/rss_steer.v",
    "../../rtl/classifier/rss_hash.v",
    "../../rtl/queue/queue_manager.v",
    "../../rtl/scheduler/priority_scheduler.v",
    "../../rtl/scheduler/qos_scheduler.v",
    "../../rtl/scheduler/token_bucket.v",
    "../../rtl/host/qdma_h2c_bridge.v",
    "../../rtl/host/qdma_c2h_bridge.v",
    "tb_eval_top.sv"
]

SCENARIOS = {
    "1_sp_starvation":    "+pkts=500 +mode=0 +tb=0 +rss=0", # Strict Priority
    "2_wrr_fairness":     "+pkts=500 +mode=1 +tb=0 +rss=0", # WRR Mode
    "3_rss_on_load":      "+pkts=500 +mode=1 +tb=0 +rss=1", # RSS On
    "4_token_bucket":     "+pkts=500 +mode=1 +tb=1 +rss=0", # Token Bucket Policing
    "5_mixed_5g":         "+pkts=500 +mode=1 +tb=1 +rss=1"  # Mixed 5G Traffic Reality
}

def run_cmd(cmd):
    print(f"Running: {cmd}")
    result = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        print(f"Error executing command: {cmd}")
        print(result.stderr)
        exit(1)
    return result.stdout

def compile_verilog():
    print("Compiling SystemVerilog Testbench...")
    files_str = " ".join(RTL_FILES)
    cmd = f"iverilog -g2012 -I {RTL_COMMON} -o eval_top.vvp {files_str}"
    run_cmd(cmd)

def run_scenario(name, args):
    print(f"\n--- Running Scenario: {name} ---")
    cmd = f"vvp eval_top.vvp {args}"
    stdout = run_cmd(cmd)
    
    # Save the output logs for debug
    with open(f"log_{name}.txt", "w") as f:
        f.write(stdout)
    
    # Copy the results CSV
    if os.path.exists("results.csv"):
        shutil.copy("results.csv", f"results_{name}.csv")
        print(f"Saved results_{name}.csv")
    else:
        print(f"ERROR: results.csv not generated for {name}")

    if os.path.exists("latency_log.csv"):
        shutil.copy("latency_log.csv", f"latency_log_{name}.csv")
    
    if os.path.exists("timeseries_log.csv"):
        shutil.copy("timeseries_log.csv", f"timeseries_log_{name}.csv")

def main():
    if not os.path.exists("../../rtl/classifier/rss_hash.v"):
        print("ERROR: Run from tb/eval directory!")
        exit(1)

    compile_verilog()

    for name, args in SCENARIOS.items():
        run_scenario(name, args)

    print("\nAll Benchmarks Completed Successfully! Ready for Visualization.")

if __name__ == "__main__":
    main()
