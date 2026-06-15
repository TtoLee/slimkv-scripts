import argparse
import math
import os
import re
from datetime import datetime, timedelta
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", "/tmp/matplotlib")

import matplotlib as mpl
import matplotlib.pyplot as plt

from plot_ops_triple import (
    AXIS_LINEWIDTH,
    COMBINED_FIGSIZE,
    GLOBAL_FONT_FALLBACKS,
    GLOBAL_FONT_FAMILY,
    GLOBAL_FONT_SIZE,
    LINE_COLORS,
    LINE_WIDTH,
    PLOT_FIGSIZE,
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
    build_compact_y_axis,
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


def parse_leading_timestamp(line: str, run_date: datetime | None = None) -> datetime | None:
    candidates = []
    candidates.extend(re.findall(r"^\s*(\d{4}[-/]\d{2}[-/]\d{2}\s+\d{2}:\d{2}:\d{2})", line))
    candidates.extend(
        re.findall(r"^\s*(\d{1,2}/\d{1,2}/\d{2,4}\s+\d{2}:\d{2}:\d{2}(?:\s+[AP]M)?)", line)
    )
    candidates.extend(re.findall(r"^\s*(\d{2}:\d{2}:\d{2}(?:\s+[AP]M)?)", line))
    for candidate in candidates:
        parsed = parse_datetime_text(candidate, run_date)
        if parsed is not None:
            return parsed
    return None


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

            parsed_ts = parse_leading_timestamp(line, run_start)
            if parsed_ts is not None and "Device" not in line:
                current_ts = align_time_only_to_run(parsed_ts, run_start)
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

            ts = parse_leading_timestamp(line, run_start)
            if ts is None:
                continue
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


def smooth_samples(samples, value_index: int, window: int):
    secs = [int(math.floor(row[0])) for row in samples]
    values = [row[value_index] for row in samples]
    return average_window(secs, values, window)


def write_iostat_tsv(path: Path, rows):
    with path.open("w") as f:
        f.write("rel_sec\ttimestamp\twkB_per_sec\tw_await_ms\n")
        for rel_sec, ts, wkb, await_ms in rows:
            f.write(f"{rel_sec:.3f}\t{ts:%Y-%m-%d %H:%M:%S}\t{wkb:.6f}\t{await_ms:.6f}\n")


def write_flush_tsv(path: Path, rows_by_kind):
    with path.open("w") as f:
        f.write("rel_sec\ttimestamp\tkind\tflushes\tlatency_us\n")
        for kind in ("primary", "backup"):
            for rel_sec, ts, flushes, latency_us in rows_by_kind[kind]:
                f.write(f"{rel_sec:.3f}\t{ts:%Y-%m-%d %H:%M:%S}\t{kind}\t{flushes}\t{latency_us:.6f}\n")


def plot_series(output_path: Path, series, y_label: str):
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
        color = LINE_COLORS[idx % len(LINE_COLORS)]
        plotted_series.append(
            {
                "label": item["label"],
                "times": item["times"],
                "values": item["values"],
                "color": color,
                "avg_value": None,
            }
        )
        ax.plot(item["times"], item["values"], color=color, linewidth=LINE_WIDTH, label=item["label"])

    all_values = [v for item in plotted_series for v in item["values"]]
    all_times = [t for item in plotted_series for t in item["times"]]
    max_value = max(all_values) if all_values else 0.0
    max_time = max(all_times) if all_times else 0.0

    y_ticks, y_top = build_compact_y_axis(max_value, Y_AXIS_TARGET_TICKS)
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

    draw_custom_legend(legend_ax, plotted_series, show_avg=False)
    apply_output_font(fig)
    fig.subplots_adjust(left=0.13, right=0.97, bottom=0.2, top=0.97)
    fig.savefig(output_path, dpi=300)
    plt.close(fig)
    print(f"Plot saved to {output_path}")


def require_rows(rows, name: str):
    if not rows:
        raise ValueError(f"No samples left for {name} after applying the ops-derived time window")


def main():
    parser = argparse.ArgumentParser(
        description="Plot iostat write metrics and tebis flush latency in the style of plot_ops_triple.py"
    )
    parser.add_argument("--ops-file", required=True, type=Path)
    parser.add_argument("--iostat-file", required=True, type=Path)
    parser.add_argument("--server-log", required=True, type=Path)
    parser.add_argument("--device", required=True)
    parser.add_argument("--run-date", required=True, help="Date for ops Start time, YYYY-MM-DD")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--label", default="elect")
    parser.add_argument("--window", type=int, default=1)
    parser.add_argument("--ops-lower-threshold", type=float, required=True)
    parser.add_argument("--ops-higher-threshold", type=float, required=True)
    args = parser.parse_args()

    if args.window <= 0:
        raise ValueError("--window must be positive")

    run_date = datetime.strptime(args.run_date, "%Y-%m-%d")
    start_ts, end_ts, start_sec, end_sec = parse_ops_window(
        args.ops_file,
        run_date,
        args.ops_lower_threshold,
        args.ops_higher_threshold,
    )
    args.output_dir.mkdir(parents=True, exist_ok=True)

    iostat_rows = filter_and_rebase(
        parse_iostat(args.iostat_file, args.device, start_ts),
        start_ts,
        end_ts,
        value_indexes=(1, 2),
    )
    require_rows(iostat_rows, "iostat")
    write_iostat_tsv(args.output_dir / "iostat_filtered.tsv", iostat_rows)

    wkb_times, wkb_values = smooth_samples(iostat_rows, 2, args.window)
    await_times, await_values = smooth_samples(iostat_rows, 3, args.window)
    plot_series(
        args.output_dir / "disk_write_throughput.pdf",
        [{"label": args.label, "times": wkb_times, "values": wkb_values}],
        "wkB/s",
    )
    plot_series(
        args.output_dir / "disk_write_await.pdf",
        [{"label": args.label, "times": await_times, "values": await_values}],
        "w_await (ms)",
    )

    flush_by_kind = parse_flush_log(args.server_log, start_ts)
    filtered_flush = {
        kind: filter_and_rebase(rows, start_ts, end_ts, value_indexes=(1, 2))
        for kind, rows in flush_by_kind.items()
    }
    write_flush_tsv(args.output_dir / "flush_latency_filtered.tsv", filtered_flush)

    flush_series = []
    for kind, label in (("primary", "primary pwrite"), ("backup", "backup pwrite")):
        if not filtered_flush[kind]:
            continue
        times, values = smooth_samples(filtered_flush[kind], 3, args.window)
        flush_series.append({"label": label, "times": times, "values": values})

    require_rows(flush_series, "server flush latency")
    plot_series(args.output_dir / "pwrite_flush_latency.pdf", flush_series, "Lat. (us)")

    with (args.output_dir / "plot_window.tsv").open("w") as f:
        f.write("start_sec\tend_sec\tstart_timestamp\tend_timestamp\n")
        f.write(f"{start_sec}\t{end_sec}\t{start_ts:%Y-%m-%d %H:%M:%S}\t{end_ts:%Y-%m-%d %H:%M:%S}\n")


if __name__ == "__main__":
    main()
