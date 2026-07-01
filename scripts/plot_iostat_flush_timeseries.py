import argparse
import math
import re
from datetime import datetime, timedelta
from pathlib import Path

import matplotlib as mpl
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

from plot_ops_triple import (
    AXIS_LINEWIDTH,
    COMBINED_FIGSIZE,
    GLOBAL_FONT_FALLBACKS,
    GLOBAL_FONT_FAMILY,
    GLOBAL_FONT_SIZE,
    LINE_COLORS,
    LINE_WIDTH,
    PLOT_FIGSIZE,
    HandlerStackedLines,
    LEGEND_FIGSIZE,
    TICK_LINEWIDTH,
    X_AXIS_TICK_TARGET,
    X_LABEL_PAD,
    Y_AXIS_TARGET_TICKS,
    Y_LABEL_X,
    Y_LABEL_Y,
    apply_output_font,
    average_window,
    build_alternating_y_tick_labels,
    build_integer_x_axis,
    draw_custom_legend,
    extend_x_ticks_for_right_margin,
)


OPS_LINE_RE = re.compile(
    r"^\s*(\d+)\s+sec\s+([\deE.+-]+)\s+operations\s+([\deE.+-]+)\s+ops/sec"
)
START_TIME_RE = re.compile(r"Start time:\s*(.+?)\s*$")
FLUSH_RE = re.compile(
    r"Average\s+(primary|backup)\s+flush\s+time\s+for\s+log\s+segment\s+after\s+"
    r"(\d+)\s+flushes\s+is\s+(\d+)\s+ns"
)


def parse_datetime_text(text: str, run_date: datetime | None = None) -> datetime | None:
    text = text.strip()
    formats = [
        "%Y-%m-%d %H:%M:%S",
        "%Y/%m/%d %H:%M:%S",
        "%m/%d/%Y %I:%M:%S %p",
        "%m/%d/%y %I:%M:%S %p",
        "%m/%d/%Y %H:%M:%S",
        "%m/%d/%y %H:%M:%S",
    ]
    for fmt in formats:
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            pass

    if run_date is not None:
        for fmt in ("%I:%M:%S %p", "%H:%M:%S"):
            try:
                parsed = datetime.strptime(text, fmt)
                return datetime.combine(run_date.date(), parsed.time())
            except ValueError:
                pass

    return None


def parse_leading_timestamp_info(
    line: str,
    run_date: datetime | None = None,
) -> tuple[datetime | None, bool]:
    candidates = []
    for candidate in re.findall(r"^\s*(\d{4}[-/]\d{2}[-/]\d{2}\s+\d{2}:\d{2}:\d{2})", line):
        candidates.append((candidate, True))
    for candidate in re.findall(
        r"^\s*(\d{1,2}/\d{1,2}/\d{2,4}\s+\d{2}:\d{2}:\d{2}(?:\s+[AP]M)?)",
        line,
    ):
        candidates.append((candidate, True))
    for candidate in re.findall(r"^\s*(\d{2}:\d{2}:\d{2}(?:\s+[AP]M)?)", line):
        candidates.append((candidate, False))

    for candidate, has_date in candidates:
        parsed = parse_datetime_text(candidate, run_date)
        if parsed is not None:
            return parsed, has_date
    return None, False


def parse_leading_timestamp(line: str, run_date: datetime | None = None) -> datetime | None:
    parsed, _ = parse_leading_timestamp_info(line, run_date)
    return parsed


def align_time_only_to_run(ts: datetime, run_start: datetime) -> datetime:
    if ts < run_start - timedelta(hours=12):
        ts += timedelta(days=1)
    elif ts > run_start + timedelta(hours=12):
        ts -= timedelta(days=1)
    return ts


def parse_ops_window(
    ops_file: Path,
    run_date: datetime,
    ops_lower_threshold: float,
    ops_higher_threshold: float,
) -> tuple[datetime, datetime, int, int]:
    start_clock = None
    samples = []

    with ops_file.open() as f:
        for line in f:
            start_match = START_TIME_RE.search(line)
            if start_match:
                start_clock = start_match.group(1)
                continue

            ops_match = OPS_LINE_RE.match(line)
            if ops_match:
                samples.append((int(ops_match.group(1)), float(ops_match.group(2))))

    if start_clock is None:
        raise ValueError(f"Missing 'Start time:' in {ops_file}")
    if not samples:
        raise ValueError(f"No ops samples found in {ops_file}")

    run_start = parse_datetime_text(start_clock, run_date)
    if run_start is None:
        raise ValueError(f"Cannot parse Start time in {ops_file}: {start_clock}")

    start_sec = None
    end_sec = None
    for sec, operations in samples:
        if start_sec is None and operations > ops_lower_threshold:
            start_sec = sec
        if start_sec is not None and operations > ops_higher_threshold:
            end_sec = sec
            break

    if start_sec is None:
        raise ValueError(
            f"No ops sample is greater than lower threshold {ops_lower_threshold:g} in {ops_file}"
        )
    if end_sec is None:
        eligible = [sec for sec, operations in samples if operations > ops_lower_threshold]
        end_sec = eligible[-1]

    if end_sec <= start_sec:
        raise ValueError(f"Non-positive plot window from ops file: {start_sec}s..{end_sec}s")

    return run_start + timedelta(seconds=start_sec), run_start + timedelta(seconds=end_sec), start_sec, end_sec


def parse_iostat(iostat_file: Path, device: str, run_start: datetime) -> list[tuple[datetime, float, float]]:
    samples = []
    current_ts = None
    columns = None

    with iostat_file.open(errors="replace") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line:
                continue

            parsed_ts, has_date = parse_leading_timestamp_info(line, run_start)
            if parsed_ts is not None and "Device" not in line:
                current_ts = parsed_ts if has_date else align_time_only_to_run(parsed_ts, run_start)
                continue

            parts = line.split()
            if not parts:
                continue
            if parts[0] == "Device":
                columns = parts
                continue
            if parts[0] != device or columns is None or current_ts is None:
                continue
            if "wkB/s" not in columns or "w_await" not in columns:
                raise ValueError(f"iostat output is missing wkB/s or w_await columns in {iostat_file}")

            by_name = dict(zip(columns, parts))
            samples.append((current_ts, float(by_name["wkB/s"]), float(by_name["w_await"])))

    if not samples:
        raise ValueError(f"No iostat samples for device {device} in {iostat_file}")

    return samples


def parse_flush_log(server_log: Path, run_start: datetime) -> dict[str, list[tuple[datetime, int, float]]]:
    by_kind = {"primary": [], "backup": []}

    with server_log.open(errors="replace") as f:
        for line in f:
            flush_match = FLUSH_RE.search(line)
            if not flush_match:
                continue

            ts, has_date = parse_leading_timestamp_info(line, run_start)
            if ts is None:
                continue
            if not has_date:
                ts = align_time_only_to_run(ts, run_start)
            kind = flush_match.group(1)
            flushes = int(flush_match.group(2))
            latency_us = int(flush_match.group(3)) / 1000.0
            by_kind[kind].append((ts, flushes, latency_us))

    return by_kind


def filter_and_rebase(samples, start_ts: datetime, end_ts: datetime, value_indexes):
    rebased = []
    for sample in samples:
        ts = sample[0]
        if ts < start_ts or ts > end_ts:
            continue
        rel_sec = (ts - start_ts).total_seconds()
        values = tuple(sample[idx] for idx in value_indexes)
        rebased.append((rel_sec, ts, *values))
    return rebased


def sample_range(samples):
    if not samples:
        return None, None
    timestamps = [sample[0] for sample in samples]
    return min(timestamps), max(timestamps)


def overlap_seconds(start_a: datetime, end_a: datetime, start_b: datetime, end_b: datetime) -> float:
    return max(0.0, (min(end_a, end_b) - max(start_a, start_b)).total_seconds())


def align_window_to_samples(
    start_ts: datetime,
    end_ts: datetime,
    samples,
    source_name: str,
) -> tuple[datetime, datetime]:
    sample_start, sample_end = sample_range(samples)
    if sample_start is None or sample_end is None:
        return start_ts, end_ts

    original_overlap = overlap_seconds(start_ts, end_ts, sample_start, sample_end)
    if original_overlap > 0:
        return start_ts, end_ts

    best_shift = timedelta(0)
    best_overlap = 0.0
    for day_shift in (-1, 0, 1):
        for hour_shift in (-12, 0, 12):
            shift = timedelta(days=day_shift, hours=hour_shift)
            shifted_start = start_ts + shift
            shifted_end = end_ts + shift
            score = overlap_seconds(shifted_start, shifted_end, sample_start, sample_end)
            if score > best_overlap:
                best_overlap = score
                best_shift = shift

    if best_overlap <= 0:
        return start_ts, end_ts

    shifted_start = start_ts + best_shift
    shifted_end = end_ts + best_shift
    print(
        "Adjusted ops-derived window by "
        f"{best_shift} to overlap {source_name} samples "
        f"({sample_start:%Y-%m-%d %H:%M:%S}..{sample_end:%Y-%m-%d %H:%M:%S})."
    )
    return shifted_start, shifted_end


def smooth_samples(samples, value_index: int, window: int):
    secs = [int(math.floor(row[0])) for row in samples]
    values = [row[value_index] for row in samples]
    return average_window(secs, values, window)


def build_stable_y_axis(max_value: float, target_ticks: int):
    if not math.isfinite(max_value) or max_value <= 0:
        return [0.0, 1.0], 1.0

    target_ticks = max(5, target_ticks)
    max_ticks = max(target_ticks + 2, 10)
    multipliers = [1.0, 2.0, 2.5, 4.0, 5.0, 8.0, 10.0]
    raw_step = max_value / max(1, target_ticks - 1)
    exponent = math.floor(math.log10(raw_step))

    candidates = []
    for exp in range(exponent - 2, exponent + 3):
        base = 10 ** exp
        for mul in multipliers:
            step = mul * base
            if step <= 0:
                continue

            top_tick = math.ceil(max_value / step) * step
            if top_tick <= max_value:
                top_tick += step
            tick_count = int(round(top_tick / step)) + 1
            if tick_count < 4 or tick_count > max_ticks:
                continue

            headroom = top_tick / max_value - 1.0
            count_penalty = abs(tick_count - target_ticks) * 0.08
            candidates.append((count_penalty + headroom, step, top_tick, tick_count))

    if not candidates:
        step = 10 ** math.floor(math.log10(max_value))
        top_tick = math.ceil(max_value / step) * step
        if top_tick <= max_value:
            top_tick += step
        tick_count = int(round(top_tick / step)) + 1
    else:
        _, step, top_tick, tick_count = min(candidates, key=lambda item: item[0])

    y_ticks = [i * step for i in range(tick_count)]
    y_top = max(top_tick * (1.0 + 1e-6), max_value * 1.0001)
    return y_ticks, y_top


def write_iostat_tsv(path: Path, rows):
    with path.open("w") as f:
        f.write("rel_sec\ttimestamp\twrite_throughput_MB_per_sec\twrite_latency_us\n")
        for rel_sec, ts, throughput_mb, latency_us in rows:
            f.write(
                f"{rel_sec:.3f}\t{ts:%Y-%m-%d %H:%M:%S}\t"
                f"{throughput_mb:.6f}\t{latency_us:.6f}\n"
            )


def write_flush_tsv(path: Path, rows_by_kind):
    with path.open("w") as f:
        f.write("rel_sec\ttimestamp\tkind\tflushes\tlatency_us\n")
        for kind in ("primary", "backup"):
            for rel_sec, ts, flushes, latency_us in rows_by_kind[kind]:
                f.write(f"{rel_sec:.3f}\t{ts:%Y-%m-%d %H:%M:%S}\t{kind}\t{flushes}\t{latency_us:.6f}\n")


def sanitize_label(label: str) -> str:
    normalized = label.strip().replace("+", "plus")
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", normalized).strip("._-")
    return cleaned or "series"


def draw_line_style_legend(legend_ax, plotted_series):
    legend_ax.axis("off")

    if not plotted_series:
        return

    series_by_label = {}
    for series in plotted_series:
        series_by_label.setdefault(series["label"], []).append(series)

    handles = []
    labels = []
    for label, label_series in series_by_label.items():
        color = label_series[0]["color"]
        solid = Line2D([], [], color=color, linewidth=0, alpha=0.0)
        solid.set_visible(False)
        dashed = Line2D([], [], color=color, linewidth=0, alpha=0.0, linestyle="--")
        dashed.set_visible(False)

        for series in label_series:
            if series["linestyle"] == "--":
                dashed = Line2D([], [], color=series["color"], linewidth=LINE_WIDTH, linestyle="--")
            else:
                solid = Line2D([], [], color=series["color"], linewidth=LINE_WIDTH)

        handles.append((solid, dashed))
        labels.append(label)

    legend = legend_ax.legend(
        handles,
        labels,
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


def plot_series(
    output_path: Path,
    series,
    y_label: str,
    show_legend: bool = True,
    legend_style: str = "custom",
):
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

    plotted_series = []
    for idx, item in enumerate(series):
        color = item.get("color", LINE_COLORS[idx % len(LINE_COLORS)])
        linestyle = item.get("linestyle", "-")
        plotted_series.append(
            {
                "label": item["label"],
                "times": item["times"],
                "values": item["values"],
                "color": color,
                "linestyle": linestyle,
                "avg_value": None,
            }
        )
        ax.plot(
            item["times"],
            item["values"],
            color=color,
            linewidth=LINE_WIDTH,
            linestyle=linestyle,
            label=item["label"],
        )

    all_values = [
        v
        for item in plotted_series
        for v in item["values"]
        if math.isfinite(v)
    ]
    all_times = [t for item in plotted_series for t in item["times"]]
    max_value = max(all_values) if all_values else 0.0
    max_time = max(all_times) if all_times else 0.0

    y_ticks, y_top = build_stable_y_axis(max_value, Y_AXIS_TARGET_TICKS)
    y_tick_labels = build_alternating_y_tick_labels(y_ticks)
    x_ticks, x_minor_ticks, x_right = build_integer_x_axis(max_time, X_AXIS_TICK_TARGET)
    x_ticks, x_tick_labels, x_minor_ticks = extend_x_ticks_for_right_margin(
        x_ticks,
        x_minor_ticks,
        x_right,
    )

    ax.set_xlabel("Time (s)", labelpad=X_LABEL_PAD)
    ax.set_ylabel(y_label, labelpad=8)
    ax.yaxis.set_label_coords(Y_LABEL_X, Y_LABEL_Y)
    ax.set_xlim(left=0, right=x_right)
    ax.set_xticks(x_ticks)
    ax.set_xticklabels(x_tick_labels)
    ax.set_xticks(x_minor_ticks, minor=True)
    ax.set_ylim(bottom=0, top=y_top)
    ax.set_yticks(y_ticks)
    ax.set_yticklabels(y_tick_labels)
    ax.grid(False)
    ax.tick_params(axis="x", width=TICK_LINEWIDTH)
    ax.tick_params(axis="x", which="minor", width=TICK_LINEWIDTH, length=4, labelbottom=False)
    ax.tick_params(axis="y", width=TICK_LINEWIDTH)
    for spine in ax.spines.values():
        spine.set_linewidth(AXIS_LINEWIDTH)

    if show_legend:
        if legend_style == "line":
            draw_line_style_legend(legend_ax, plotted_series)
        else:
            draw_custom_legend(legend_ax, plotted_series, show_avg=False)
    else:
        legend_ax.axis("off")
    apply_output_font(fig)
    fig.subplots_adjust(left=0.13, right=0.97, bottom=0.2, top=0.97)
    fig.savefig(output_path, dpi=300)
    plt.close(fig)
    print(f"Plot saved to {output_path}")


def require_rows(rows, name: str):
    if not rows:
        raise ValueError(f"No samples left for {name} after applying the ops-derived time window")


def require_windowed_rows(rows, name: str, start_ts: datetime, end_ts: datetime, all_samples):
    if rows:
        return

    sample_start, sample_end = sample_range(all_samples)
    if sample_start is None:
        raise ValueError(f"No parsed {name} samples")

    raise ValueError(
        f"No samples left for {name} after applying the ops-derived time window. "
        f"window={start_ts:%Y-%m-%d %H:%M:%S}..{end_ts:%Y-%m-%d %H:%M:%S}, "
        f"{name}_range={sample_start:%Y-%m-%d %H:%M:%S}..{sample_end:%Y-%m-%d %H:%M:%S}. "
        "Check whether ops.txt Start time AM/PM, host clocks, or time zones differ."
    )


def validate_repeated_args(args):
    series_count = len(args.ops_file)
    if len(args.iostat_file) != series_count or len(args.server_log) != series_count:
        raise ValueError(
            "--ops-file, --iostat-file, and --server-log must be passed the same number of times"
        )
    if args.label is not None and len(args.label) != series_count:
        raise ValueError("--label must be passed once for each input series")


def build_labels(args, series_count: int):
    if args.label is not None:
        return args.label
    if series_count == 1:
        return ["elect"]
    return [f"series{i + 1}" for i in range(series_count)]


def process_dataset(args, run_date: datetime, label: str, index: int, series_count: int):
    start_ts, end_ts, start_sec, end_sec = parse_ops_window(
        args.ops_file[index],
        run_date,
        args.ops_lower_threshold,
        args.ops_higher_threshold,
    )

    iostat_samples = parse_iostat(args.iostat_file[index], args.device, start_ts)
    start_ts, end_ts = align_window_to_samples(start_ts, end_ts, iostat_samples, "iostat")

    iostat_rows_raw = filter_and_rebase(
        iostat_samples,
        start_ts,
        end_ts,
        value_indexes=(1, 2),
    )
    require_windowed_rows(iostat_rows_raw, f"{label} iostat", start_ts, end_ts, iostat_samples)
    iostat_rows = [
        (rel_sec, ts, wkb_per_sec / 1024.0, w_await_ms * 1000.0)
        for rel_sec, ts, wkb_per_sec, w_await_ms in iostat_rows_raw
    ]

    safe_label = sanitize_label(label)
    if series_count == 1:
        write_iostat_tsv(args.output_dir / "iostat_filtered.tsv", iostat_rows)
    write_iostat_tsv(args.output_dir / f"{safe_label}_iostat_filtered.tsv", iostat_rows)

    throughput_times, throughput_values = smooth_samples(iostat_rows, 2, args.window)
    latency_times, latency_values = smooth_samples(iostat_rows, 3, args.window)

    flush_by_kind = parse_flush_log(args.server_log[index], start_ts)
    filtered_flush = {
        kind: filter_and_rebase(rows, start_ts, end_ts, value_indexes=(1, 2))
        for kind, rows in flush_by_kind.items()
    }
    if series_count == 1:
        write_flush_tsv(args.output_dir / "flush_latency_filtered.tsv", filtered_flush)
    write_flush_tsv(args.output_dir / f"{safe_label}_flush_latency_filtered.tsv", filtered_flush)

    color = LINE_COLORS[index % len(LINE_COLORS)]
    flush_series = []
    for kind, linestyle in (
        ("primary", "-"),
        ("backup", "--"),
    ):
        if not filtered_flush[kind]:
            continue
        times, values = smooth_samples(filtered_flush[kind], 3, args.window)
        flush_series.append(
            {
                "label": label,
                "times": times,
                "values": values,
                "color": color,
                "linestyle": linestyle,
            }
        )

    return {
        "label": label,
        "throughput": {"label": label, "times": throughput_times, "values": throughput_values},
        "latency": {"label": label, "times": latency_times, "values": latency_values},
        "flush": flush_series,
        "window": (start_sec, end_sec, start_ts, end_ts),
    }


def main():
    parser = argparse.ArgumentParser(
        description="Plot iostat write metrics and tebis flush latency in the style of plot_ops_triple.py"
    )
    parser.add_argument("--ops-file", action="append", required=True, type=Path)
    parser.add_argument("--iostat-file", action="append", required=True, type=Path)
    parser.add_argument("--server-log", action="append", required=True, type=Path)
    parser.add_argument("--device", required=True)
    parser.add_argument("--run-date", required=True, help="Date for ops Start time, YYYY-MM-DD")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--label", action="append")
    parser.add_argument("--window", type=int, default=1)
    parser.add_argument("--ops-lower-threshold", type=float, required=True)
    parser.add_argument("--ops-higher-threshold", type=float, required=True)
    args = parser.parse_args()

    if args.window <= 0:
        raise ValueError("--window must be positive")

    validate_repeated_args(args)
    run_date = datetime.strptime(args.run_date, "%Y-%m-%d")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    labels = build_labels(args, len(args.ops_file))
    datasets = [
        process_dataset(args, run_date, label, index, len(args.ops_file))
        for index, label in enumerate(labels)
    ]

    plot_series(
        args.output_dir / "disk_write_throughput.pdf",
        [dataset["throughput"] for dataset in datasets],
        "Write thpt. (MB/s)",
        show_legend=len(datasets) > 1,
    )
    plot_series(
        args.output_dir / "disk_write_await.pdf",
        [dataset["latency"] for dataset in datasets],
        "Write lat. (us)",
        show_legend=len(datasets) > 1,
    )

    flush_series = []
    for dataset in datasets:
        flush_series.extend(dataset["flush"])

    require_rows(flush_series, "server flush latency")
    plot_series(
        args.output_dir / "pwrite_flush_latency.pdf",
        flush_series,
        "Lat. (us)",
        legend_style="line",
    )

    with (args.output_dir / "plot_window.tsv").open("w") as f:
        f.write("label\tstart_sec\tend_sec\tstart_timestamp\tend_timestamp\n")
        for dataset in datasets:
            start_sec, end_sec, start_ts, end_ts = dataset["window"]
            f.write(
                f"{dataset['label']}\t{start_sec}\t{end_sec}\t"
                f"{start_ts:%Y-%m-%d %H:%M:%S}\t{end_ts:%Y-%m-%d %H:%M:%S}\n"
            )


if __name__ == "__main__":
    main()
