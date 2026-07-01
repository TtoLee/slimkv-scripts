import argparse
import matplotlib as mpl

mpl.rcParams.update(
    {
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
        "pdf.use14corefonts": False,
        "text.usetex": False,
    }
)

import matplotlib.pyplot as plt
import re
import math
from pathlib import Path
from matplotlib.lines import Line2D
from matplotlib.legend_handler import HandlerBase
from matplotlib import font_manager

tebis_color = "#9AC9DB"
elect_color = "#BB9727"
slimkv_color = "#C82423"
LINE_COLORS = [tebis_color, elect_color, slimkv_color]

PANEL_FIGSIZE = (8, 5)
PLOT_FIGSIZE = (PANEL_FIGSIZE[0] * 2.0, PANEL_FIGSIZE[1])
LEGEND_FIGSIZE = (PANEL_FIGSIZE[0] * 2.0, 1.0)
COMBINED_FIGSIZE = (PLOT_FIGSIZE[0], PLOT_FIGSIZE[1] + LEGEND_FIGSIZE[1])

ARIAL_FONT_PATH = Path("/usr/local/share/fonts/arial/ARIAL.TTF")
GLOBAL_FONT_PROPERTIES = None
if ARIAL_FONT_PATH.exists():
    font_manager.fontManager.addfont(str(ARIAL_FONT_PATH))
    GLOBAL_FONT_PROPERTIES = font_manager.FontProperties(fname=str(ARIAL_FONT_PATH))

GLOBAL_FONT_FAMILY = "Arial"
GLOBAL_FONT_FALLBACKS = ["Arial"]
GLOBAL_FONT_SIZE = 34.0
GLOBAL_VALUE_FONT_SIZE = 34.0
AXIS_LINEWIDTH = 1.5
TICK_LINEWIDTH = 1.5
LINE_WIDTH = 4.5
Y_AXIS_TARGET_TICKS = 9
Y_AXIS_MAX_TICKS = 10
Y_LABEL_X = -0.095
Y_LABEL_Y = 0.5
X_LABEL_PAD = 10
X_AXIS_TICK_TARGET = 18
X_AXIS_MIN_RIGHT_MARGIN = 1
AVG_LABEL_Y_OFFSET = 4
RIGHT_LABEL_X_OFFSET = -10
LEGEND_LINE_X_SPAN = 0.06
LEGEND_LABEL_GAP = 0.03
LEGEND_ITEM_Y_TOP = 0.85
LEGEND_ITEM_Y_BOTTOM = 0.15
RIGHT_LABEL_EXTRA_MINOR_TICKS = 1


def apply_output_font(fig):
    """Bind all figure text to the configured TTF file, avoiding font-cache surprises."""
    if GLOBAL_FONT_PROPERTIES is None:
        return

    for text in fig.findobj(match=mpl.text.Text):
        fontsize = text.get_fontsize()
        fontweight = text.get_fontweight()
        fontstyle = text.get_fontstyle()
        text.set_fontproperties(GLOBAL_FONT_PROPERTIES)
        text.set_fontsize(fontsize)
        text.set_fontweight(fontweight)
        text.set_fontstyle(fontstyle)


class HandlerStackedLines(HandlerBase):
    """Draw solid and dashed legend samples stacked vertically in one legend slot."""

    def create_artists(
        self,
        legend,
        orig_handle,
        xdescent,
        ydescent,
        width,
        height,
        fontsize,
        trans,
    ):
        solid_handle, dashed_handle = orig_handle
        x0 = xdescent
        x1 = xdescent + width
        show_dashed = dashed_handle.get_visible() and dashed_handle.get_linewidth() > 0
        if show_dashed:
            y_top = ydescent + height * LEGEND_ITEM_Y_TOP
            y_bottom = ydescent + height * LEGEND_ITEM_Y_BOTTOM
        else:
            y_top = ydescent + height * 0.5
            y_bottom = y_top

        solid = Line2D([x0, x1], [y_top, y_top])
        dashed = Line2D([x0, x1], [y_bottom, y_bottom])
        self.update_prop(solid, solid_handle, legend)
        self.update_prop(dashed, dashed_handle, legend)
        solid.set_solid_capstyle("butt")
        dashed.set_dash_capstyle("butt")
        solid.set_transform(trans)
        dashed.set_transform(trans)
        return [solid, dashed]


def load_filtered_samples(
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

    return data


def load_series(
    base_dir: str,
    ops_lower_threshold: float | None = None,
    ops_higher_threshold: float | None = None,
    rebase_time_to_zero: bool = True,
):
    data = load_filtered_samples(
        base_dir,
        ops_lower_threshold=ops_lower_threshold,
        ops_higher_threshold=ops_higher_threshold,
        rebase_time_to_zero=rebase_time_to_zero,
    )
    secs, _, _, throughputs = zip(*data)
    return secs, throughputs


def compute_average_throughput_kops(
    base_dir: str,
    ops_lower_threshold: float | None = None,
    ops_higher_threshold: float | None = None,
    rebase_time_to_zero: bool = True,
):
    data = load_filtered_samples(
        base_dir,
        ops_lower_threshold=ops_lower_threshold,
        ops_higher_threshold=ops_higher_threshold,
        rebase_time_to_zero=rebase_time_to_zero,
    )

    start_sec, start_ops_raw, _, _ = data[0]
    end_sec, end_ops_raw, _, _ = data[-1]
    elapsed_sec = end_sec - start_sec
    if elapsed_sec <= 0:
        raise ValueError(f"Non-positive elapsed time after filtering in {base_dir}")

    avg_kops = (end_ops_raw - start_ops_raw) / elapsed_sec / 1000.0
    return avg_kops


def average_window(secs, values, window: int):
    """Aggregate values into non-overlapping time buckets of `window` seconds."""
    if window <= 0:
        raise ValueError("window must be positive")
    buckets = {}
    counts = {}
    bucket_end_times = {}
    for s, v in zip(secs, values):
        bucket = (s // window) * window  # bucket start time
        buckets[bucket] = buckets.get(bucket, 0.0) + v
        counts[bucket] = counts.get(bucket, 0) + 1
        bucket_end_times[bucket] = max(bucket_end_times.get(bucket, s), s)

    bucket_keys = sorted(buckets.keys())
    avg_values = [buckets[b] / counts[b] for b in bucket_keys]
    plot_times = list(bucket_keys)
    if plot_times:
        plot_times[0] = 0
        plot_times[-1] = bucket_end_times[bucket_keys[-1]]
    return plot_times, avg_values


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
    label1 = series_a["label"]
    times1 = series_a["times"]
    values1 = series_a["values"]
    label2 = series_b["label"]
    times2 = series_b["times"]
    values2 = series_b["values"]

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
        fontsize=GLOBAL_VALUE_FONT_SIZE,
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

def build_compact_y_axis(max_value: float, target_ticks: int):
    """Build denser y ticks so the top tick is just above data max."""
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


def format_tick_value(value: float) -> str:
    if math.isclose(value, round(value), rel_tol=0.0, abs_tol=1e-9):
        return str(int(round(value)))
    return f"{value:g}"


def build_alternating_y_tick_labels(y_ticks):
    labels = []
    for idx, tick in enumerate(y_ticks):
        labels.append(format_tick_value(tick) if idx % 2 == 0 else "")
    return labels


def build_integer_x_axis(max_time: float, target_ticks: int):
    """Build major and minor integer x ticks with a top tick above max_time."""
    if max_time <= 0:
        return [0, 1], [0.5], 1

    raw_step = max_time / max(1, target_ticks - 1)
    magnitude = 10 ** math.floor(math.log10(raw_step))
    normalized = raw_step / magnitude

    if normalized <= 1:
        nice_base = 1
    elif normalized <= 2:
        nice_base = 2
    elif normalized <= 2.5:
        nice_base = 2.5
    elif normalized <= 5:
        nice_base = 5
    else:
        nice_base = 10

    step = int(nice_base * magnitude)
    step = max(1, step)
    top_tick = int((math.floor(max_time / step) + 1) * step)
    x_ticks = list(range(0, top_tick + step, step))
    x_minor_ticks = []
    if step >= 2:
        x_minor_ticks = [tick + step / 2 for tick in x_ticks[:-1]]

    x_right = x_ticks[-1] + X_AXIS_MIN_RIGHT_MARGIN
    return x_ticks, x_minor_ticks, x_right


def expand_x_right_for_avg_labels(x_ticks, x_right: float, plotted_series, show_avg: bool):
    """Add roughly one extra minor-tick span of right-side whitespace for average labels."""
    if not show_avg:
        return x_right

    if not any(series["avg_value"] is not None for series in plotted_series):
        return x_right

    major_step = x_ticks[1] - x_ticks[0] if len(x_ticks) >= 2 else max(1.0, x_right)
    minor_step = major_step / 2 if major_step >= 2 else major_step
    extra_margin = max(
        X_AXIS_MIN_RIGHT_MARGIN,
        float(minor_step) * RIGHT_LABEL_EXTRA_MINOR_TICKS,
    )
    return max(x_right, x_ticks[-1] + extra_margin)


def extend_x_ticks_for_right_margin(x_ticks, x_minor_ticks, x_right: float):
    """Extend visible tick marks into the right-side whitespace and label major ticks normally."""
    if not x_ticks:
        return x_ticks, [], x_minor_ticks

    major_step = x_ticks[1] - x_ticks[0] if len(x_ticks) >= 2 else max(1.0, x_right)
    extended_ticks = list(x_ticks)

    next_tick = x_ticks[-1] + major_step
    while next_tick <= x_right + 1e-9:
        extended_ticks.append(next_tick)
        next_tick += major_step

    x_tick_labels = [format_tick_value(tick) for tick in extended_ticks]

    extended_minor_ticks = [tick for tick in x_minor_ticks if tick <= x_right + 1e-9]
    if major_step >= 2:
        for idx in range(len(extended_ticks) - 1):
            midpoint = extended_ticks[idx] + major_step / 2
            if midpoint <= x_right + 1e-9 and midpoint not in extended_minor_ticks:
                extended_minor_ticks.append(midpoint)
        extended_minor_ticks.sort()

    return extended_ticks, x_tick_labels, extended_minor_ticks


def annotate_series_averages(ax, plotted_series, show_avg: bool, x_right: float):
    """Label each series average throughput near the right edge."""
    if not plotted_series:
        return

    if not show_avg:
        return

    for series in plotted_series:
        if series["avg_value"] is None:
            continue
        ax.annotate(
            f"{int(round(series['avg_value']))}",
            xy=(x_right, series["avg_value"]),
            xytext=(RIGHT_LABEL_X_OFFSET, AVG_LABEL_Y_OFFSET),
            textcoords="offset points",
            ha="right",
            va="bottom",
            color=series["color"],
            fontsize=GLOBAL_VALUE_FONT_SIZE,
        )


def draw_custom_legend(legend_ax, plotted_series, show_avg: bool):
    legend_ax.axis("off")

    if not plotted_series:
        return

    handles = []
    for series in plotted_series:
        solid = Line2D([], [], color=series["color"], linewidth=LINE_WIDTH)
        if show_avg:
            dashed = Line2D([], [], color=series["color"], linewidth=LINE_WIDTH, linestyle="--")
        else:
            dashed = Line2D([], [], color=series["color"], linewidth=0, alpha=0.0)
            dashed.set_visible(False)
        handles.append((solid, dashed))

    legend = legend_ax.legend(
        handles,
        [series["label"] for series in plotted_series],
        frameon=False,
        loc="center",
        ncol=max(1, len(handles)),
        fontsize=GLOBAL_FONT_SIZE,
        handler_map={tuple: HandlerStackedLines()},
        handlelength=1.8,
    )

    for legend_handle in legend.legend_handles:
        if hasattr(legend_handle, "set_linewidth"):
            legend_handle.set_linewidth(LINE_WIDTH * 1.5)


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
    parser.add_argument(
        "--window",
        nargs="?",
        const=5,
        default=5,
        type=int,
        help="Averaging window in seconds; defaults to 5 when the option is present without a value",
    )
    parser.add_argument(
        "--avg",
        action="store_true",
        help="Plot average throughput as a same-color dashed line computed from filtered start/end ops",
    )
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

    mpl.rcParams.update(
        {
            "font.size": GLOBAL_FONT_SIZE,
            "font.family": GLOBAL_FONT_FAMILY,
            "font.sans-serif": GLOBAL_FONT_FALLBACKS,
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
            "pdf.use14corefonts": False,
            "text.usetex": False,
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

    fig = plt.figure(figsize=COMBINED_FIGSIZE)
    grid = fig.add_gridspec(
        2,
        1,
        height_ratios=[LEGEND_FIGSIZE[1], PLOT_FIGSIZE[1]],
        hspace=0.0,
    )
    legend_ax = fig.add_subplot(grid[0])
    ax = fig.add_subplot(grid[1])

    colors = LINE_COLORS
    plotted_series = []
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
        avg_value = None
        if args.avg:
            avg_runs = [
                compute_average_throughput_kops(
                    base_dir,
                    ops_lower_threshold=args.ops_lower_threshold,
                    ops_higher_threshold=args.ops_higher_threshold,
                    rebase_time_to_zero=not args.keep_original_time,
                )
                for base_dir in base_dirs
            ]
            avg_value = sum(avg_runs) / len(avg_runs)

        plotted_series.append(
            {
                "label": label,
                "times": mean_times,
                "values": mean_values,
                "color": color,
                "avg_value": avg_value,
            }
        )
        ax.plot(
            mean_times,
            mean_values,
            color=color,
            linewidth=LINE_WIDTH,
            label=label,
        )

    all_values = [v for series in plotted_series for v in series["values"]]
    if args.avg:
        all_values.extend(
            series["avg_value"] for series in plotted_series if series["avg_value"] is not None
        )
    all_times = [t for series in plotted_series for t in series["times"]]
    max_value = max(all_values) if all_values else 0.0
    max_time = max(all_times) if all_times else 0.0
    y_ticks, y_top = build_compact_y_axis(max_value, Y_AXIS_TARGET_TICKS)
    y_tick_labels = build_alternating_y_tick_labels(y_ticks)
    x_ticks, x_minor_ticks, x_right = build_integer_x_axis(max_time, X_AXIS_TICK_TARGET)
    x_right = expand_x_right_for_avg_labels(x_ticks, x_right, plotted_series, args.avg)
    x_ticks, x_tick_labels, x_minor_ticks = extend_x_ticks_for_right_margin(
        x_ticks,
        x_minor_ticks,
        x_right,
    )

    max_change_summary = None
    if len(groups) == 2:
        max_change_summary = annotate_max_change_two_series(
            ax,
            plotted_series[0],
            plotted_series[1],
        )

    if args.avg:
        for series in plotted_series:
            avg_value = series["avg_value"]
            if avg_value is None or not series["times"]:
                continue
            ax.hlines(
                avg_value,
                xmin=min(series["times"]),
                xmax=x_right,
                colors=series["color"],
                linestyles="--",
                linewidth=LINE_WIDTH,
                alpha=0.95,
            )

    ax.set_xlabel("Time (s)", labelpad=X_LABEL_PAD)
    ax.set_ylabel("Thpt. (kops/s)", labelpad=8)
    ax.yaxis.set_label_coords(Y_LABEL_X, Y_LABEL_Y)
    ax.set_xlim(left=0, right=x_right)
    ax.set_xticks(x_ticks)
    ax.set_xticklabels(x_tick_labels)
    # ax.set_xticks(x_minor_ticks, minor=True)
    ax.set_ylim(bottom=0, top=y_top)
    ax.set_yticks(y_ticks)
    ax.set_yticklabels(y_tick_labels)
    ax.grid(False)
    annotate_series_averages(ax, plotted_series, args.avg, x_right)
    ax.tick_params(axis="x", width=TICK_LINEWIDTH)
    # ax.tick_params(axis="x", which="minor", width=TICK_LINEWIDTH, length=4, labelbottom=False)
    ax.tick_params(axis="y", width=TICK_LINEWIDTH)
    for spine in ax.spines.values():
        spine.set_linewidth(AXIS_LINEWIDTH)

    draw_custom_legend(legend_ax, plotted_series, args.avg)
    apply_output_font(fig)

    fig.subplots_adjust(left=0.13, right=0.97, bottom=0.2, top=0.97)

    fig.savefig(output_path, dpi=300)
    plt.close(fig)

    if max_change_summary:
        print(max_change_summary)
    print(f"Plot saved to {output_path}")


if __name__ == "__main__":
    main()
