"""
ResQNet — Bluetooth Mesh DTN Simulation
=========================================
Monte Carlo simulation of Delay-Tolerant Network
store-and-forward over BLE in a disaster scenario.

Models:
  - Survivors randomly distributed across disaster zone
  - Each phone has BLE range of 100m
  - Epidemic routing with max 3 hops
  - Rescuer team enters from edge of zone
  - Measures delivery probability and latency

Run:
  pip install numpy matplotlib scipy pandas
  python bluetooth_mesh_simulation.py

Outputs:
  Figure_BLE_1_delivery_vs_density.png
  Figure_BLE_2_hops_distribution.png
  Figure_BLE_3_delivery_vs_time.png
  Figure_BLE_4_coverage_vs_devices.png
  Figure_BLE_5_no_mesh_comparison.png
  ble_simulation_results.csv
"""

import numpy as np
import matplotlib.pyplot as plt
import matplotlib.patches as patches
from matplotlib.animation import FuncAnimation
import pandas as pd
from scipy.spatial import distance_matrix
import os

np.random.seed(42)

# ── Simulation parameters ──────────────────────────────────────
ZONE_SIZE_M      = 1000     # 1km × 1km disaster zone
BLE_RANGE_M      = 100      # BLE 5.0 range in metres
MAX_HOPS         = 3        # maximum relay hops
SCAN_INTERVAL_S  = 15       # seconds between BLE scans
RESCUER_SPEED    = 1.4      # m/s walking speed
SIM_DURATION_MIN = 60       # total simulation time
N_MONTE_CARLO    = 200      # Monte Carlo runs per scenario
OUTPUT_DIR       = '.'

# Survivor densities to test (devices per km²)
DENSITIES = [1, 2, 5, 10, 20, 30, 50, 75, 100]

plt.rcParams.update({
    'figure.facecolor': '#0F0F1A',
    'axes.facecolor':   '#1A1A2E',
    'axes.edgecolor':   '#333355',
    'axes.labelcolor':  '#AAAAAA',
    'xtick.color':      '#666666',
    'ytick.color':      '#666666',
    'grid.color':       '#333355',
    'grid.linewidth':   0.5,
    'text.color':       '#EEEEEE',
    'font.family':      'monospace',
})

print("ResQNet — Bluetooth Mesh DTN Simulation")
print("=" * 55)


# ── Core simulation ────────────────────────────────────────────
class MeshSimulation:
    """
    Simulates BLE mesh propagation across a disaster zone.

    Devices: randomly placed survivors with ResQNet phones
    Source:  one victim who triggered distress (centre)
    Rescuer: enters from edge, moves toward centre
    """

    def __init__(self, n_devices, zone_size=ZONE_SIZE_M,
                 ble_range=BLE_RANGE_M, max_hops=MAX_HOPS):
        self.n_devices  = n_devices
        self.zone_size  = zone_size
        self.ble_range  = ble_range
        self.max_hops   = max_hops

        # Place devices randomly
        self.positions = np.random.uniform(0, zone_size, (n_devices, 2))

        # Victim is at centre (worst case — furthest from edge)
        victim_pos = np.array([[zone_size/2, zone_size/2]])
        self.positions = np.vstack([victim_pos, self.positions])
        self.n_devices += 1

        # Alert state: -1=unknown, 0=has alert, hop count if received
        self.alert_state  = np.full(self.n_devices, -1)
        self.alert_state[0] = 0   # victim has alert at hop 0

        # Track when each device received the alert
        self.received_time = np.full(self.n_devices, np.inf)
        self.received_time[0] = 0.0

        # Rescuer starts at edge (bottom left)
        self.rescuer_pos  = np.array([0.0, 0.0])
        self.rescuer_speed = RESCUER_SPEED

        # Target: move toward victim
        self.rescuer_target = victim_pos[0].copy()

        # Results
        self.delivery_time    = None
        self.delivery_hops    = None
        self.n_hops_used      = []
        self.rescuer_received = False
        self.time_steps       = []
        self.coverage_pct     = []

    def run(self, duration_s=SIM_DURATION_MIN*60):
        """Run simulation for given duration."""
        dt = SCAN_INTERVAL_S  # time step = scan interval

        for t in range(0, duration_s, dt):
            # Update rescuer position
            direction = self.rescuer_target - self.rescuer_pos
            dist      = np.linalg.norm(direction)
            if dist > 0:
                self.rescuer_pos += (direction / dist) * self.rescuer_speed * dt

            # Propagate alerts between devices
            self._propagate_alerts(t)

            # Check if rescuer is within range of any alerted device
            if not self.rescuer_received:
                self._check_rescuer(t)

            # Track coverage
            n_alerted = np.sum(self.alert_state >= 0)
            self.coverage_pct.append(n_alerted / self.n_devices * 100)
            self.time_steps.append(t)

            # Early exit if rescuer received
            if self.rescuer_received:
                break

        return self.rescuer_received

    def _propagate_alerts(self, t):
        """Epidemic routing: any alerted device broadcasts to neighbours."""
        alerted_idx = np.where(
            (self.alert_state >= 0) &
            (self.alert_state < self.max_hops)
        )[0]

        if len(alerted_idx) == 0:
            return

        for src in alerted_idx:
            src_pos  = self.positions[src]
            src_hop  = self.alert_state[src]

            # Find unalerted devices within BLE range
            dists = np.linalg.norm(
                self.positions - src_pos, axis=1)

            neighbours = np.where(
                (dists <= self.ble_range) &
                (self.alert_state == -1)
            )[0]

            for dst in neighbours:
                self.alert_state[dst]  = src_hop + 1
                self.received_time[dst] = t
                self.n_hops_used.append(src_hop + 1)

    def _check_rescuer(self, t):
        """Check if rescuer is within BLE range of any alerted device."""
        alerted_positions = self.positions[self.alert_state >= 0]

        if len(alerted_positions) == 0:
            return

        dists = np.linalg.norm(
            alerted_positions - self.rescuer_pos, axis=1)

        if np.any(dists <= self.ble_range):
            self.rescuer_received = True
            self.delivery_time    = t
            closest_device_idx    = np.where(self.alert_state >= 0)[0][
                np.argmin(dists)]
            self.delivery_hops = self.alert_state[closest_device_idx]
            print(f"    Rescuer received alert at t={t}s "
                  f"via {self.delivery_hops} hops")


# ── Monte Carlo experiments ────────────────────────────────────
def run_experiments():
    """Run Monte Carlo simulation for all density levels."""
    print("\nRunning Monte Carlo simulation...")
    print(f"  {N_MONTE_CARLO} runs × {len(DENSITIES)} densities = "
          f"{N_MONTE_CARLO * len(DENSITIES)} total simulations\n")

    results = []

    for density in DENSITIES:
        n_devices = int(density * (ZONE_SIZE_M/1000)**2)
        n_devices = max(n_devices, 1)

        delivery_times  = []
        delivery_hops_all = []
        delivered_count = 0

        print(f"  Density {density:>4}/km²  ({n_devices} devices)", end='')

        for run in range(N_MONTE_CARLO):
            sim     = MeshSimulation(n_devices)
            success = sim.run()

            if success:
                delivered_count    += 1
                delivery_times.append(sim.delivery_time)
                if sim.delivery_hops is not None:
                    delivery_hops_all.append(sim.delivery_hops)

        prob     = delivered_count / N_MONTE_CARLO
        avg_time = np.mean(delivery_times) if delivery_times else np.inf
        avg_hops = np.mean(delivery_hops_all) if delivery_hops_all else 0

        # No-mesh baseline: rescuer must physically reach victim
        # Time to walk from edge to centre
        no_mesh_time = (ZONE_SIZE_M * np.sqrt(2) / 2) / RESCUER_SPEED
        no_mesh_prob = min(1.0, SIM_DURATION_MIN * 60 / no_mesh_time)

        results.append({
            'density':        density,
            'n_devices':      n_devices,
            'delivery_prob':  prob,
            'avg_time_s':     avg_time,
            'avg_hops':       avg_hops,
            'no_mesh_prob':   no_mesh_prob,
            'no_mesh_time_s': no_mesh_time,
            'improvement':    prob - no_mesh_prob,
        })

        print(f"  → Delivery: {prob*100:.0f}%  "
              f"Avg time: {avg_time:.0f}s  "
              f"Avg hops: {avg_hops:.1f}")

    df = pd.DataFrame(results)
    df.to_csv(f'{OUTPUT_DIR}/ble_simulation_results.csv', index=False)
    print(f"\n  Results saved to ble_simulation_results.csv")
    return df


# ── Figure 1: Delivery probability vs density ─────────────────
def plot_delivery_vs_density(df):
    print("\nGenerating Figure 1: Delivery probability vs density...")

    fig, ax = plt.subplots(figsize=(10, 6))

    # ResQNet mesh
    ax.plot(df['density'], df['delivery_prob'] * 100,
            color='#1D9E75', linewidth=2.5, marker='o',
            markersize=6, label='ResQNet BLE Mesh (3-hop DTN)')

    # No-mesh baseline
    ax.plot(df['density'], df['no_mesh_prob'] * 100,
            color='#E24B4A', linewidth=1.5, linestyle='--',
            marker='s', markersize=5,
            label='No mesh (physical search only)')

    # Shade improvement area
    ax.fill_between(df['density'],
                    df['no_mesh_prob'] * 100,
                    df['delivery_prob'] * 100,
                    alpha=0.12, color='#1D9E75',
                    label='Mesh improvement')

    # Mark 80% threshold
    ax.axhline(80, color='#FAC775', linewidth=1,
               linestyle=':', alpha=0.7, label='80% delivery threshold')

    # Find density where 80% is achieved
    above_80 = df[df['delivery_prob'] >= 0.8]
    if len(above_80) > 0:
        threshold_density = above_80.iloc[0]['density']
        ax.axvline(threshold_density, color='#FAC775',
                   linewidth=1, linestyle=':', alpha=0.7)
        ax.annotate(f'{threshold_density}/km²\nachieves 80%',
                    xy=(threshold_density, 80),
                    xytext=(threshold_density + 5, 65),
                    color='#FAC775', fontsize=9,
                    arrowprops=dict(arrowstyle='->', color='#FAC775',
                                    lw=1))

    ax.set_xlabel('Device Density (phones per km²)', fontsize=11)
    ax.set_ylabel('Alert Delivery Probability (%)', fontsize=11)
    ax.set_title('ResQNet Mesh: Alert Delivery Probability vs Device Density\n'
                 f'Zone: {ZONE_SIZE_M}m × {ZONE_SIZE_M}m  |  '
                 f'BLE Range: {BLE_RANGE_M}m  |  '
                 f'Max Hops: {MAX_HOPS}',
                 fontsize=12, fontweight='bold')
    ax.legend(facecolor='#1A1A2E', labelcolor='white', fontsize=9)
    ax.set_ylim(0, 105)
    ax.set_xlim(0, max(DENSITIES) + 5)
    ax.grid(True, alpha=0.4)

    plt.tight_layout()
    path = f'{OUTPUT_DIR}/Figure_BLE_1_delivery_vs_density.png'
    plt.savefig(path, dpi=150, bbox_inches='tight',
                facecolor='#0F0F1A')
    plt.close()
    print(f"  Saved: {path}")


# ── Figure 2: Hop count distribution ──────────────────────────
def plot_hop_distribution():
    print("Generating Figure 2: Hop count distribution...")

    # Run a representative simulation and collect hop data
    all_hops = []
    density  = 20  # use 20 devices/km² as representative case
    n_dev    = int(density * (ZONE_SIZE_M/1000)**2)

    for _ in range(50):
        sim = MeshSimulation(n_dev)
        sim.run()
        all_hops.extend(sim.n_hops_used)

    if not all_hops:
        print("  No hop data — skipping")
        return

    fig, ax = plt.subplots(figsize=(8, 5))

    hop_counts = [all_hops.count(h) for h in range(1, MAX_HOPS+1)]
    total      = sum(hop_counts)
    hop_pcts   = [c/total*100 for c in hop_counts] if total > 0 else [0]*MAX_HOPS

    colors = ['#1D9E75', '#4895EF', '#E24B4A']
    bars   = ax.bar(range(1, MAX_HOPS+1), hop_pcts,
                    color=colors[:MAX_HOPS], alpha=0.8,
                    edgecolor='white', linewidth=0.5)

    for bar, pct in zip(bars, hop_pcts):
        ax.text(bar.get_x() + bar.get_width()/2,
                bar.get_height() + 0.5,
                f'{pct:.1f}%', ha='center', va='bottom',
                color='white', fontsize=10, fontweight='bold')

    ax.set_xlabel('Number of Hops', fontsize=11)
    ax.set_ylabel('Percentage of Deliveries (%)', fontsize=11)
    ax.set_title(f'Alert Delivery by Hop Count\n'
                 f'Density: {density} devices/km²  |  '
                 f'BLE Range: {BLE_RANGE_M}m',
                 fontsize=12, fontweight='bold')
    ax.set_xticks(range(1, MAX_HOPS+1))
    ax.set_xticklabels([f'Hop {i}' for i in range(1, MAX_HOPS+1)])
    ax.set_ylim(0, 110)
    ax.grid(True, axis='y', alpha=0.4)

    plt.tight_layout()
    path = f'{OUTPUT_DIR}/Figure_BLE_2_hops_distribution.png'
    plt.savefig(path, dpi=150, bbox_inches='tight',
                facecolor='#0F0F1A')
    plt.close()
    print(f"  Saved: {path}")


# ── Figure 3: Delivery time vs density ────────────────────────
def plot_delivery_time(df):
    print("Generating Figure 3: Delivery time vs density...")

    valid = df[df['avg_time_s'] != np.inf]
    if valid.empty:
        print("  No delivery data — skipping")
        return

    fig, ax = plt.subplots(figsize=(10, 6))

    ax.plot(valid['density'], valid['avg_time_s'] / 60,
            color='#CBA6F7', linewidth=2.5,
            marker='D', markersize=6,
            label='Avg delivery time (mesh)')

    # No-mesh baseline
    ax.axhline(valid['no_mesh_time_s'].iloc[0] / 60,
               color='#E24B4A', linewidth=1.5, linestyle='--',
               label=f'No mesh (physical: '
                     f'{valid["no_mesh_time_s"].iloc[0]/60:.0f} min)')

    ax.set_xlabel('Device Density (phones per km²)', fontsize=11)
    ax.set_ylabel('Average Alert Delivery Time (minutes)', fontsize=11)
    ax.set_title('Alert Delivery Time vs Device Density\n'
                 f'Simulation Duration: {SIM_DURATION_MIN} min',
                 fontsize=12, fontweight='bold')
    ax.legend(facecolor='#1A1A2E', labelcolor='white', fontsize=9)
    ax.grid(True, alpha=0.4)

    plt.tight_layout()
    path = f'{OUTPUT_DIR}/Figure_BLE_3_delivery_vs_time.png'
    plt.savefig(path, dpi=150, bbox_inches='tight',
                facecolor='#0F0F1A')
    plt.close()
    print(f"  Saved: {path}")


# ── Figure 4: Network coverage growth ─────────────────────────
def plot_coverage_growth():
    print("Generating Figure 4: Network coverage growth...")

    fig, ax = plt.subplots(figsize=(10, 6))

    densities_to_plot = [5, 10, 20, 50]
    colors_plot = ['#E24B4A', '#F4A261', '#4895EF', '#1D9E75']

    for density, color in zip(densities_to_plot, colors_plot):
        n_dev = int(density * (ZONE_SIZE_M/1000)**2)
        all_coverage = []

        for _ in range(20):
            sim = MeshSimulation(n_dev)
            sim.run(duration_s=600)  # 10 minutes
            if sim.coverage_pct:
                all_coverage.append(sim.coverage_pct)

        if not all_coverage:
            continue

        # Pad to same length
        max_len  = max(len(c) for c in all_coverage)
        padded   = [c + [c[-1]] * (max_len - len(c))
                    for c in all_coverage]
        avg_cov  = np.mean(padded, axis=0)
        time_min = np.arange(len(avg_cov)) * SCAN_INTERVAL_S / 60

        ax.plot(time_min, avg_cov, color=color, linewidth=2,
                label=f'{density} devices/km² ({n_dev} devices)')

    ax.set_xlabel('Time (minutes)', fontsize=11)
    ax.set_ylabel('Network Coverage (%)', fontsize=11)
    ax.set_title('BLE Mesh Network Coverage Growth Over Time\n'
                 f'Zone: {ZONE_SIZE_M}m × {ZONE_SIZE_M}m',
                 fontsize=12, fontweight='bold')
    ax.legend(facecolor='#1A1A2E', labelcolor='white', fontsize=9)
    ax.set_ylim(0, 105)
    ax.grid(True, alpha=0.4)

    plt.tight_layout()
    path = f'{OUTPUT_DIR}/Figure_BLE_4_coverage_vs_time.png'
    plt.savefig(path, dpi=150, bbox_inches='tight',
                facecolor='#0F0F1A')
    plt.close()
    print(f"  Saved: {path}")


# ── Figure 5: Mesh vs no-mesh comparison bar chart ─────────────
def plot_comparison(df):
    print("Generating Figure 5: Mesh vs no-mesh comparison...")

    fig, axes = plt.subplots(1, 2, figsize=(14, 6))

    # Left: delivery probability comparison
    ax = axes[0]
    x  = np.arange(len(df))
    w  = 0.35

    ax.bar(x - w/2, df['delivery_prob'] * 100,
           w, color='#1D9E75', alpha=0.8,
           edgecolor='white', linewidth=0.5,
           label='ResQNet BLE Mesh')
    ax.bar(x + w/2, df['no_mesh_prob'] * 100,
           w, color='#E24B4A', alpha=0.8,
           edgecolor='white', linewidth=0.5,
           label='No Mesh (physical search)')

    ax.set_xlabel('Device Density (per km²)', fontsize=10)
    ax.set_ylabel('Delivery Probability (%)', fontsize=10)
    ax.set_title('Delivery Probability\nMesh vs No-Mesh',
                 fontsize=11, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels(df['density'].astype(int), fontsize=8)
    ax.legend(facecolor='#1A1A2E', labelcolor='white', fontsize=8)
    ax.set_ylim(0, 115)
    ax.grid(True, axis='y', alpha=0.4)

    # Right: improvement chart
    ax2 = axes[1]
    colors = ['#1D9E75' if v > 0 else '#E24B4A'
              for v in df['improvement']]
    ax2.bar(x, df['improvement'] * 100,
            color=colors, alpha=0.8,
            edgecolor='white', linewidth=0.5)
    ax2.axhline(0, color='white', linewidth=0.8)

    ax2.set_xlabel('Device Density (per km²)', fontsize=10)
    ax2.set_ylabel('Improvement over No-Mesh (%)', fontsize=10)
    ax2.set_title('ResQNet Mesh Improvement\nover Physical Search',
                  fontsize=11, fontweight='bold')
    ax2.set_xticks(x)
    ax2.set_xticklabels(df['density'].astype(int), fontsize=8)
    ax2.grid(True, axis='y', alpha=0.4)

    fig.suptitle('ResQNet DTN Mesh — Performance Evaluation\n'
                 f'Monte Carlo: {N_MONTE_CARLO} runs per scenario  |  '
                 f'BLE Range: {BLE_RANGE_M}m  |  Max Hops: {MAX_HOPS}',
                 fontsize=12, fontweight='bold', y=1.02)

    plt.tight_layout()
    path = f'{OUTPUT_DIR}/Figure_BLE_5_mesh_vs_nomesh.png'
    plt.savefig(path, dpi=150, bbox_inches='tight',
                facecolor='#0F0F1A')
    plt.close()
    print(f"  Saved: {path}")


# ── Figure 6: Single simulation visualisation ──────────────────
def plot_single_simulation():
    print("Generating Figure 6: Single simulation snapshot...")

    n_dev = 30
    sim   = MeshSimulation(n_dev)
    sim.run()

    fig, ax = plt.subplots(figsize=(8, 8))
    ax.set_xlim(0, ZONE_SIZE_M)
    ax.set_ylim(0, ZONE_SIZE_M)
    ax.set_aspect('equal')

    # Draw BLE range circles for alerted devices
    for i, pos in enumerate(sim.positions):
        if sim.alert_state[i] >= 0:
            circle = plt.Circle(pos, BLE_RANGE_M,
                                color='#1D9E75', fill=False,
                                alpha=0.15, linewidth=0.5)
            ax.add_patch(circle)

    # Draw devices
    for i, pos in enumerate(sim.positions):
        state = sim.alert_state[i]
        if state == -1:
            color = '#333355'
            size  = 30
        elif state == 0:
            color = '#E24B4A'  # victim
            size  = 100
        elif state == 1:
            color = '#F4A261'  # hop 1
            size  = 60
        elif state == 2:
            color = '#4895EF'  # hop 2
            size  = 50
        else:
            color = '#1D9E75'  # hop 3
            size  = 40
        ax.scatter(*pos, c=color, s=size, zorder=3)

    # Draw rescuer
    ax.scatter(*sim.rescuer_pos,
               c='#FAC775', s=150, marker='*',
               zorder=5, label='Rescuer')

    # Legend
    from matplotlib.lines import Line2D
    legend_elements = [
        Line2D([0],[0], marker='o', color='w',
               markerfacecolor='#E24B4A', markersize=10,
               label='Victim (hop 0)'),
        Line2D([0],[0], marker='o', color='w',
               markerfacecolor='#F4A261', markersize=8,
               label='Relay hop 1'),
        Line2D([0],[0], marker='o', color='w',
               markerfacecolor='#4895EF', markersize=7,
               label='Relay hop 2'),
        Line2D([0],[0], marker='o', color='w',
               markerfacecolor='#1D9E75', markersize=6,
               label='Relay hop 3'),
        Line2D([0],[0], marker='o', color='w',
               markerfacecolor='#333355', markersize=5,
               label='Unreached device'),
        Line2D([0],[0], marker='*', color='w',
               markerfacecolor='#FAC775', markersize=12,
               label='Rescuer'),
    ]
    ax.legend(handles=legend_elements,
              facecolor='#1A1A2E', labelcolor='white',
              fontsize=9, loc='upper right')

    delivered = sim.rescuer_received
    hops      = sim.delivery_hops if sim.delivery_hops else 'N/A'
    time_s    = sim.delivery_time if sim.delivery_time else 'N/A'

    ax.set_title(f'ResQNet Mesh — Single Simulation ({n_dev} devices)\n'
                 f'Delivered: {delivered}  |  '
                 f'Hops: {hops}  |  '
                 f'Time: {time_s}s',
                 fontsize=11, fontweight='bold')
    ax.set_xlabel('X Position (metres)', fontsize=10)
    ax.set_ylabel('Y Position (metres)', fontsize=10)
    ax.grid(True, alpha=0.2)

    plt.tight_layout()
    path = f'{OUTPUT_DIR}/Figure_BLE_6_single_simulation.png'
    plt.savefig(path, dpi=150, bbox_inches='tight',
                facecolor='#0F0F1A')
    plt.close()
    print(f"  Saved: {path}")


# ── Print thesis results table ─────────────────────────────────
def print_thesis_table(df):
    print("\n" + "=" * 65)
    print("  THESIS RESULTS TABLE — Copy into Chapter 5")
    print("=" * 65)
    print(f"\n  {'Density':>10} {'Devices':>8} {'Delivery':>10} "
          f"{'Avg Time':>10} {'Avg Hops':>10}")
    print("  " + "-" * 55)
    for _, row in df.iterrows():
        time_str = (f"{row['avg_time_s']/60:.1f} min"
                    if row['avg_time_s'] != np.inf else "N/A")
        print(f"  {row['density']:>8.0f}/km² "
              f"{row['n_devices']:>8.0f} "
              f"{row['delivery_prob']*100:>9.1f}% "
              f"{time_str:>10} "
              f"{row['avg_hops']:>9.1f}")

    print("\n  Key findings:")
    best    = df[df['delivery_prob'] == df['delivery_prob'].max()].iloc[0]
    good    = df[df['delivery_prob'] >= 0.8]
    thresh  = good.iloc[0]['density'] if not good.empty else 'N/A'
    print(f"  → Best delivery: {best['delivery_prob']*100:.1f}% "
          f"at {best['density']:.0f} devices/km²")
    print(f"  → 80% delivery threshold: {thresh} devices/km²")
    print(f"  → Max hops used: {MAX_HOPS}")
    print(f"  → BLE range: {BLE_RANGE_M}m per hop")
    print(f"  → Max coverage: {MAX_HOPS * BLE_RANGE_M}m without internet")
    print(f"\n  For thesis abstract:")
    print(f"  'At a survivor density of {thresh} devices/km², the")
    print(f"   ResQNet BLE mesh achieves 80%+ alert delivery")
    print(f"   probability using epidemic DTN routing with")
    print(f"   {MAX_HOPS}-hop maximum depth and {BLE_RANGE_M}m BLE range.'")
    print("=" * 65)


# ── Main ───────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"\nSimulation parameters:")
    print(f"  Zone:          {ZONE_SIZE_M}m × {ZONE_SIZE_M}m")
    print(f"  BLE range:     {BLE_RANGE_M}m")
    print(f"  Max hops:      {MAX_HOPS}")
    print(f"  Scan interval: {SCAN_INTERVAL_S}s")
    print(f"  Duration:      {SIM_DURATION_MIN} minutes")
    print(f"  Monte Carlo:   {N_MONTE_CARLO} runs per scenario")
    print(f"  Densities:     {DENSITIES} devices/km²\n")

    # Run experiments
    df = run_experiments()

    # Generate all figures
    print("\nGenerating thesis figures...")
    plot_delivery_vs_density(df)
    plot_hop_distribution()
    plot_delivery_time(df)
    plot_coverage_growth()
    plot_comparison(df)
    plot_single_simulation()

    # Print results table
    print_thesis_table(df)

    print(f"\n{'='*55}")
    print(f"  SIMULATION COMPLETE")
    print(f"{'='*55}")
    print(f"  Output files:")
    for f in sorted(os.listdir('.')):
        if f.startswith('Figure_BLE') or f == 'ble_simulation_results.csv':
            size = os.path.getsize(f) / 1024
            print(f"    {f} ({size:.0f} KB)")
    print(f"\n  Copy all Figure_BLE_*.png to your thesis")
    print(f"  Copy ble_simulation_results.csv to your results folder")
