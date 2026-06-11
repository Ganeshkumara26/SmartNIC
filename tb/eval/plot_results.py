#!/usr/bin/env python3
"""
Performance Evaluation Framework Visualizer
-------------------------------------------
Reads the generated CSV files and plots the benchmark results.
"""

import os
import sys
try:
    import pandas as pd
    import matplotlib.pyplot as plt
    import numpy as np
except ImportError:
    print("WARNING: pandas and matplotlib are required for visualization.")
    print("Please run: pip install pandas matplotlib")
    sys.exit(1)

def calc_fairness(dequeues):
    # Jain's Fairness Index
    # f(x) = (Sum xi)^2 / (N * Sum xi^2)
    s = sum(dequeues)
    if s == 0:
        return 0
    sq_s = sum(x*x for x in dequeues)
    return (s * s) / (len(dequeues) * sq_s)

def plot_fairness_comparison():
    if not os.path.exists("results_1_sp_starvation.csv") or not os.path.exists("results_2_wrr_fairness.csv"):
        print("Missing data for fairness comparison")
        return

    df_sp = pd.read_csv("results_1_sp_starvation.csv")
    df_wrr = pd.read_csv("results_2_wrr_fairness.csv")

    labels = ['Q0 (URLLC)', 'Q1 (eMBB)', 'Q2 (IoT)', 'Q3 (Default)']
    x = np.arange(len(labels))
    width = 0.35

    fig, ax = plt.subplots(figsize=(10, 6))
    rects1 = ax.bar(x - width/2, df_sp['dequeued'], width, label='Strict Priority')
    rects2 = ax.bar(x + width/2, df_wrr['dequeued'], width, label='Weighted Round Robin')

    ax.set_ylabel('Packets Dequeued')
    ax.set_title('QoS Scheduler Output Distribution: SP vs WRR')
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.legend()

    # Calculate Fairness
    sp_f = calc_fairness(df_sp['dequeued'])
    wrr_f = calc_fairness(df_wrr['dequeued'])
    ax.text(0.5, -0.15, f"Jain's Fairness Index -> SP: {sp_f:.2f} | WRR: {wrr_f:.2f}", 
            horizontalalignment='center', verticalalignment='center', transform=ax.transAxes, fontsize=12)

    fig.tight_layout()
    plt.savefig("benchmark_1_qos_fairness.png")
    print("Saved benchmark_1_qos_fairness.png")

def plot_rss_load_balancing():
    if not os.path.exists("results_2_wrr_fairness.csv") or not os.path.exists("results_3_rss_on_load.csv"):
        print("Missing data for RSS comparison")
        return

    df_off = pd.read_csv("results_2_wrr_fairness.csv")
    df_on = pd.read_csv("results_3_rss_on_load.csv")

    labels = ['Q0', 'Q1', 'Q2', 'Q3']
    x = np.arange(len(labels))
    width = 0.35

    fig, ax = plt.subplots(figsize=(10, 6))
    rects1 = ax.bar(x - width/2, df_off['dequeued'], width, label='RSS OFF (WRR only)')
    rects2 = ax.bar(x + width/2, df_on['dequeued'], width, label='RSS ON (WRR + RSS)')

    ax.set_ylabel('Packets Handled')
    ax.set_title('Load Balancing via Receive-Side Scaling (RSS)')
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.legend()

    fig.tight_layout()
    plt.savefig("benchmark_2_rss_load_balancing.png")
    print("Saved benchmark_2_rss_load_balancing.png")

def plot_token_bucket_policing():
    if not os.path.exists("timeseries_log_4_token_bucket.csv"):
        print("Missing data for Token Bucket comparison")
        return

    df = pd.read_csv("timeseries_log_4_token_bucket.csv")
    
    fig, ax = plt.subplots(figsize=(10, 6))
    ax.plot(df['time_ns'], df['q3_deq'], label='Cumulative IoT Output (Policed)', linewidth=2, color='red')
    
    # Calculate unpoliced theoretical line
    # If 20% of 100Gbps = 20Gbps. But limit is 4Gbps. 
    # Just plotting the actual output curve which will be a straight strict line
    
    ax.set_xlabel('Simulation Time (ns)')
    ax.set_ylabel('Cumulative Packets Dequeued')
    ax.set_title('Experiment 3: Token Bucket Traffic Policing (4 Gbps CIR)')
    ax.grid(True)
    ax.legend()
    
    fig.tight_layout()
    plt.savefig("benchmark_3_token_bucket.png")
    print("Saved benchmark_3_token_bucket.png")

def plot_mixed_traffic_latency():
    if not os.path.exists("latency_log_5_mixed_5g.csv"):
        print("Missing data for Mixed Traffic Latency comparison")
        return

    df = pd.read_csv("latency_log_5_mixed_5g.csv")
    
    if df.empty or len(df) < 2:
        print("Latency log is empty — no packets reached egress. Generating summary from results CSV instead.")
        # Fallback: plot the final counter summary
        if os.path.exists("results_5_mixed_5g.csv"):
            df_r = pd.read_csv("results_5_mixed_5g.csv")
            labels = ['Q0 (URLLC)', 'Q1 (eMBB)', 'Q2 (Reserve)', 'Q3 (IoT)']
            fig, ax = plt.subplots(figsize=(10, 6))
            x = np.arange(len(labels))
            w = 0.25
            ax.bar(x - w, df_r['enqueued'], w, label='Enqueued')
            ax.bar(x, df_r['dropped'], w, label='Dropped')
            ax.bar(x + w, df_r['dequeued'], w, label='Dequeued')
            ax.set_xticks(x)
            ax.set_xticklabels(labels)
            ax.set_ylabel('Packets')
            ax.set_title('Experiment 4: Mixed 5G Traffic — Enqueue/Drop/Dequeue')
            ax.legend()
            fig.tight_layout()
            plt.savefig("benchmark_4_mixed_latency.png")
            print("Saved benchmark_4_mixed_latency.png")
        return
    
    # Map Slice ID to Names
    slice_map = {0: 'URLLC', 1: 'eMBB', 3: 'IoT'}
    df['SliceName'] = df['slice_id'].map(slice_map)
    df = df.dropna()
    
    if df.empty:
        print("No valid slice mappings found in latency log")
        return
    
    fig, ax = plt.subplots(figsize=(10, 6))
    
    # Use matplotlib boxplot directly for robustness
    groups = df.groupby('SliceName')['latency_ns'].apply(list).to_dict()
    labels = list(groups.keys())
    data = list(groups.values())
    
    ax.boxplot(data, labels=labels)
    ax.set_ylabel('Latency (ns)')
    ax.set_xlabel('Network Slice')
    ax.set_title('Experiment 4: Mixed 5G Real-World Traffic Latency Distribution')
    
    fig.tight_layout()
    plt.savefig("benchmark_4_mixed_latency.png")
    print("Saved benchmark_4_mixed_latency.png")

def main():
    plot_fairness_comparison()
    plot_rss_load_balancing()
    plot_token_bucket_policing()
    plot_mixed_traffic_latency()
    print("All plots generated!")

if __name__ == "__main__":
    main()
