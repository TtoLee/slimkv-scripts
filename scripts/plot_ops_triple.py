import argparse
import matplotlib.pyplot as plt
import re
import math
from pathlib import Path

tebis_color = "#9AC9DB"
elect_color = "#BB9727"
slimkv_color = "#C82423"
LINE_COLORS = [tebis_color, elect_color, slimkv_color]

PANEL_FIGSIZE = (8, 5)
PLOT_FIGSIZE = (PANEL_FIGSIZE[0] * 2.0, PANEL_FIGSIZE[1])
LEGEND_FIGSIZE = (PANEL_FIGSIZE[0] * 2.0, 1.0)

GLOBAL_FONT_FAMILY = "Arial"
GLOBAL_FONT_FALLBACKS = ["Arial"]
GLOBAL_FONT_SIZE = 34.0
AXIS_LINEWIDTH = 1.5
TICK_LINEWIDTH = 1.5
LINE_WIDTH = 4.5
Y_AXIS_TARGET_TICKS = 5
Y_AXIS_MAX_TICKS = 6
Y_LABEL_X = -0.11
Y_LABEL_Y = 0.45
X_LABEL_PAD = 10


def load_series(
    base_dir: str,
    ops_lower_threshold: float | None = None,
    ops_higher_threshold: float | None = None,
    rebase_time_to_zero: bool = True,
):
    base = Path(base_dir)
    input_file = None
    preferred_candidates = [base / "run_a" / "ops.txt", base / "run_load" / "ops.txt"]
    for candidate in preferred_candidates:
        if candidate.exists():
            input_file = candidate
            break

    if input_file is None:
        generic_candidates = sorted(base.glob("run_*/ops.txt"))
        if len(generic_candidates) == 1:
            input_file = generic_candidates[0]

    if input_file is None:
        raise FileNotFoundError(f"Missing input file under {base}: expected run_*/ops.txt")

    data = []
    with input_file.open() as f:
        for line in f:
            m = re.match(r"(\d+) sec ([\deE.+-]+) operations ([\deE.+-]+) ops/sec", line)
            if m:
                sec = int(m.group(1))
                ops_raw = float(m.group(2))
                ops = ops_raw / 1000.0
                throughput = float(m.group(3)) / 1000.0
                data.append((sec, ops_raw, ops, throughput))
    if not data:
        raise ValueError(f"No data found in {input_file}")

    if ops_lower_threshold is not None or ops_higher_threshold is not None:
        filtered = []
        for sec, ops_raw, ops, throughput in data:
            # Thresholds are interpreted in raw cumulative operations (same unit as ops.txt).
            if ops_lower_threshold is not None and not (ops_raw > ops_lower_threshold):
                continue
            if ops_higher_threshold is not None and not (ops_raw <= ops_higher_threshold):
                continue
            filtered.append((sec, ops_raw, ops, throughput))
        data = filtered

    if not data:
        raise ValueError(
            "No data points left after ops threshold filtering "
            f"in {input_file} (lower={ops_lower_threshold}, higher={ops_higher_threshold})"
        )

    if rebase_time_to_zero:
        first_sec = data[0][0]
        data = [(sec - first_sec, ops_raw, ops, throughput) for sec, ops_raw, ops, throughput in data]

    secs, _, ops, throughputs = zip(*data)
    return secs, throughputs


def average_window(secs, values, window: int):
    """Aggregate values into non-overlapping time buckets of `window` seconds."""
    if window <= 0:
        raise ValueError("window must be positive")
    buckets = {}
    counts = {}
    for s, v in zip(secs, values):
        bucket = (s // window) * window  # bucket start time
        buckets[bucket] = buckets.get(bucket, 0.0) + v
        counts[bucket] = counts.get(bucket, 0) + 1
    bucket_times = sorted(buckets.keys())
    avg_values = [buckets[b] / counts[b] for b in bucket_times]
    return bucket_times, avg_values


def load_smoothed_group(
    base_dirs,
    window: int,
    ops_lower_threshold: float | None = None,
    ops_higher_threshold: float | None = None,
    rebase_time_to_zero: bool = True,
):
    """Load and smooth multiple runs for one series label."""
    smoothed = []
    for d in base_dirs:
        secs, thr = load_series(
            d,
            ops_lower_threshold=ops_lower_threshold,
            ops_higher_threshold=ops_higher_threshold,
            rebase_time_to_zero=rebase_time_to_zero,
        )
        smoothed.append(average_window(secs, thr, window))
    return smoothed


def mean_series(smoothed_runs):
    """Average by bucket time across multiple runs."""
    sums = {}
    counts = {}
    for times, values in smoothed_runs:
        for t, v in zip(times, values):
            sums[t] = sums.get(t, 0.0) + v
            counts[t] = counts.get(t, 0) + 1

    mean_times = sorted(sums.keys())
    mean_values = [sums[t] / counts[t] for t in mean_times]
    return mean_times, mean_values


def annotate_max_change_two_series(ax, series_a, series_b):
    """Add dual-style max-change annotation between two series and return summary string."""
    label1, times1, values1 = series_a
    label2, times2, values2 = series_b

    series1_map = {t: v for t, v in zip(times1, values1)}
    series2_map = {t: v for t, v in zip(times2, values2)}
    common_times = sorted(set(series1_map.keys()) & set(series2_map.keys()))
    if not common_times:
        raise ValueError("No overlapping time buckets between the two series")

    diffs = [(series1_map[t] - series2_map[t], t) for t in common_times]
    max_diff, max_t = max(diffs, key=lambda x: x[0])
    delta = series2_map[max_t] - series1_map[max_t]
    base = series1_map[max_t]
    pct = (delta / base * 100.0) if base != 0 else float("inf")

    if pct == float("inf"):
        annotation_text = f"{label2} vs {label1}: base=0"
    else:
        annotation_text = f"{pct:+.1f}%"

    y_target = series2_map[max_t]
    y_offset = series1_map[max_t]
    y_text = y_offset
    lower_end = min(y_target, y_offset)
    ax.annotate(
        annotation_text,
        xy=(max_t, lower_end),
        xytext=(0, -14),
        textcoords="offset points",
        ha="center",
        va="top",
    )
    ax.annotate(
        "",
        xy=(max_t, y_target),
        xytext=(max_t, y_text),
        arrowprops=dict(facecolor="red", shrink=0.05, width=1, headwidth=6),
        ha="center",
    )

    if pct == float("inf"):
        return f"Max change ({label2} vs {label1}) at {max_t}s: base=0"
    return f"Max change ({label2} vs {label1}) at {max_t}s: {pct:+.1f}%"


def build_legend_output_path(output: Path) -> Path:
    return output.with_name(f"{output.stem}_legend{output.suffix}")


def save_legend_figure(handles, labels, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    n_items = max(1, len(labels))
    fig = plt.figure(figsize=LEGEND_FIGSIZE)
    legend = fig.legend(
        handles,
        labels,
        frameon=False,
        loc="center",
        ncol=n_items,
        fontsize=GLOBAL_FONT_SIZE,
    )
    for legend_handle in legend.legend_handles:
        legend_handle.set_linewidth(LINE_WIDTH*1.5)
    fig.savefig(output, dpi=300, pad_inches=0.02)
    plt.close(fig)


def build_compact_y_axis(max_value: float, target_ticks: int):
    """Build y ticks so the top tick is just above data max with moderate density."""
    if max_value <= 0:
        return [0.0, 1.0], 1.0

    target_ticks = max(3, target_ticks)
    multipliers = [1.0, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]
    exponent = math.floor(math.log10(max_value))

    candidates = []
    for exp in range(exponent - 2, exponent + 3):
        base = 10 ** exp
        for mul in multipliers:
            step = mul * base
            if step <= 0:
                continue

            top_tick = (math.floor(max_value / step) + 1) * step
            if top_tick <= max_value:
                continue

            tick_count = int(round(top_tick / step)) + 1
            if tick_count < target_ticks or tick_count > Y_AXIS_MAX_TICKS:
                continue

            headroom_ratio = top_tick / max_value - 1.0
            density_penalty = 0.08 * abs(tick_count - target_ticks)
            score = headroom_ratio + density_penalty
            candidates.append((score, step, top_tick, tick_count))

    if not candidates:
        step = max_value
        top_tick = max_value * 1.1
        return [0.0, top_tick], top_tick

    _, step, top_tick, tick_count = min(candidates, key=lambda x: x[0])
    y_ticks = [i * step for i in range(tick_count)]
    y_top = max(top_tick * (1.0 + 1e-6), max_value * 1.0001)
    return y_ticks, y_top


def main():
    parser = argparse.ArgumentParser(description="Plot two or three throughput series on one chart")
    parser.add_argument(
        "--dir1",
        action="append",
        required=True,
        help="Directory containing first run_a/ops.txt (repeat this option for multiple epochs)",
    )
    parser.add_argument(
        "--dir2",
        action="append",
        required=True,
        help="Directory containing second run_a/ops.txt (repeat this option for multiple epochs)",
    )
    parser.add_argument(
        "--dir3",
        action="append",
        help="Directory containing third run_a/ops.txt (repeat this option for multiple epochs)",
    )
    parser.add_argument("--label1", default="Series 1", help="Legend label for first series")
    parser.add_argument("--label2", default="Series 2", help="Legend label for second series")
    parser.add_argument("--label3", default="Series 3", help="Legend label for third series")
    parser.add_argument("--output", default="run_ops_throughput_triple.pdf", help="Output image path")
    parser.add_argument("--window", type=int, default=5, help="Averaging window in seconds")
    parser.add_argument(
        "--ops-lower-threshold",
        type=float,
        default=None,
        help="Keep points whose cumulative operations (raw ops.txt value) are greater than this threshold",
    )
    parser.add_argument(
        "--ops-higher-threshold",
        type=float,
        default=None,
        help="Keep points whose cumulative operations (raw ops.txt value) are less than or equal to this threshold",
    )
    parser.add_argument(
        "--keep-original-time",
        action="store_true",
        help="Keep original time axis instead of rebasing each series to start at 0",
    )
    args = parser.parse_args()

    plt.rcParams.update(
        {
            "font.size": GLOBAL_FONT_SIZE,
            "font.family": "sans-serif",
            "font.sans-serif": GLOBAL_FONT_FALLBACKS,
            "axes.linewidth": AXIS_LINEWIDTH,
        }
    )

    groups = [
        (args.label1, args.dir1),
        (args.label2, args.dir2),
    ]
    if args.dir3:
        groups.append((args.label3, args.dir3))

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    fig, ax = plt.subplots(figsize=PLOT_FIGSIZE)

    colors = LINE_COLORS
    plotted_series = []
    legend_handles = []
    legend_labels = []

    for idx, (label, base_dirs) in enumerate(groups):
        color = colors[idx % len(colors)]
        smoothed_runs = load_smoothed_group(
            base_dirs,
            args.window,
            ops_lower_threshold=args.ops_lower_threshold,
            ops_higher_threshold=args.ops_higher_threshold,
            rebase_time_to_zero=not args.keep_original_time,
        )
        mean_times, mean_values = mean_series(smoothed_runs)
        plotted_series.append((label, mean_times, mean_values))
        line, = ax.plot(
            mean_times,
            mean_values,
            color=color,
            linewidth=LINE_WIDTH,
            label=label,
        )
        legend_handles.append(line)
        legend_labels.append(label)

    max_change_summary = None
    if len(groups) == 2:
        max_change_summary = annotate_max_change_two_series(ax, plotted_series[0], plotted_series[1])

    all_values = [v for _, _, series_values in plotted_series for v in series_values]
    max_value = max(all_values) if all_values else 0.0
    y_ticks, y_top = build_compact_y_axis(max_value, Y_AXIS_TARGET_TICKS)

    ax.set_xlabel("Time (s)", labelpad=X_LABEL_PAD)
    ax.set_ylabel("Throughput (kops/s)", labelpad=8)
    ax.yaxis.set_label_coords(Y_LABEL_X, Y_LABEL_Y)
    ax.set_xlim(left=0)
    ax.set_ylim(bottom=0, top=y_top)
    ax.set_yticks(y_ticks)
    ax.grid(False)
    ax.tick_params(axis="x", width=TICK_LINEWIDTH)
    ax.tick_params(axis="y", width=TICK_LINEWIDTH)
    for spine in ax.spines.values():
        spine.set_linewidth(AXIS_LINEWIDTH)
    fig.subplots_adjust(left=0.13, right=0.97, bottom=0.24, top=0.94)

    fig.savefig(output_path, dpi=300)
    plt.close(fig)

    legend_output_path = build_legend_output_path(output_path)
    save_legend_figure(legend_handles, legend_labels, legend_output_path)

    if max_change_summary:
        print(max_change_summary)
    print(f"Plot saved to {output_path}")
    print(f"Legend saved to {legend_output_path}")


if __name__ == "__main__":
    main()
