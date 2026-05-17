#!/usr/bin/env python3

import argparse
import math
import os
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import to_rgba
from matplotlib.ticker import AutoMinorLocator, FormatStrFormatter, NullFormatter

REGION_PATTERN = re.compile(r"region min key:\s*(.*)")
SEGMENT_PATTERN = re.compile(r"segment(?: index|_id):\s*(\d+),\s*valid_size:\s*(\d+),?")
DONE_MARKER = "Finished printing GC segment valid data for all regions"
SEGMENT_BYTES = 2 * 1024 * 1024
PERCENT_COLORS = ["#9AC9DB", "#BB9727", "#C82423", "#54B345"]
PLOT_FIGSIZE = (16, 5)
LEGEND_FIGSIZE = (16, 0.5)
LEGEND_COLUMN_SPACING = 0.8
LEGEND_HANDLE_TEXT_PAD = 0.4
LEGEND_MARKER_SIZE = 18
GLOBAL_FONT_FAMILY = "Arial"
GLOBAL_FONT_FALLBACKS = ["Arial"]
GLOBAL_FONT_SIZE = 34.0
AXIS_LINEWIDTH = 1.5
TICK_LINEWIDTH = 1.5
MAJOR_TICK_LENGTH = 7
MINOR_TICK_LENGTH = MAJOR_TICK_LENGTH
SCATTER_SIZE = 20
VALID_PERCENT_ALPHA = 1
NONZERO_COUNT_ALPHA = 1
X_AXIS_TARGET_TICKS = 11


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate GC segment scatter plots and TSV summaries from copied server logs."
    )
    parser.add_argument("--regions-file", required=True, type=Path)
    parser.add_argument(
        "--runs-root",
        type=Path,
        help=(
            "Directory containing per-run subdirectories. For each child directory, "
            "logs are read from child/server_logs, plots are written to child/plots, "
            "and the child directory name is used as the run label."
        ),
    )
    parser.add_argument("--logs-dir", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--run-label")
    parser.add_argument(
        "--valid-title",
        default="",
        help=(
            "Title template for valid-percent scatter plots. "
            "Supports {group_id}, {gc}, {run_time}, and {run_label}."
        ),
    )
    parser.add_argument(
        "--count-title",
        default="",
        help=(
            "Title template for non-zero-count scatter plots. "
            "Supports {group_id}, {gc}, {run_time}, and {run_label}."
        ),
    )
    parser.add_argument(
        "--legend-names",
        default="",
        help="Comma-separated legend names for the valid-percent scatter series.",
    )
    parser.add_argument(
        "--count-legend-name",
        default="non-zero count",
        help="Legend name for the non-zero-count scatter series.",
    )
    parser.add_argument(
        "--x-label",
        default="Stripe index",
        help="X-axis title for both scatter plots.",
    )
    parser.add_argument(
        "--x-max",
        type=int,
        help=(
            "Maximum visible X-axis tick/right edge for generated plots. "
            "This does not change data truncation or TSV output."
        ),
    )
    parser.add_argument(
        "--valid-y-label",
        default="Valid data (%)",
        help="Y-axis title for the valid-percent scatter plots.",
    )
    parser.add_argument(
        "--count-y-label",
        default="Non-zero region count",
        help="Y-axis title for the non-zero-count scatter plots.",
    )
    parser.add_argument(
        "--no-truncate",
        action="store_true",
        help=(
            "Do not truncate a group to the shortest region. "
            "Each region is plotted through its own last index."
        ),
    )
    args = parser.parse_args()
    if args.x_max is not None and args.x_max < 1:
        parser.error("--x-max must be at least 1")
    if args.runs_root is None:
        missing = [
            name
            for name, value in (
                ("--logs-dir", args.logs_dir),
                ("--output-dir", args.output_dir),
                ("--run-label", args.run_label),
            )
            if value is None
        ]
        if missing:
            parser.error(
                "--runs-root or all of --logs-dir, --output-dir, and --run-label are required; "
                f"missing {', '.join(missing)}"
            )
    return args


def parse_csv_list(value: str):
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_region_groups(path: Path):
    regions_by_id = {}
    coding_groups = []
    in_coding_section = False
    with path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line == "coding":
                in_coding_section = True
                continue
            if not line:
                continue

            parts = line.split()
            if not in_coding_section:
                if len(parts) < 3 or not parts[0].isdigit():
                    continue
                region_id = int(parts[0])
                regions_by_id[region_id] = {
                    "region_id": region_id,
                    "min_key": parts[1],
                    "max_key": parts[2],
                }
                continue

            if len(parts) < 2 or not parts[0].isdigit():
                continue

            group_entries = []
            for token in parts[1:]:
                if not token.isdigit():
                    continue
                region_id = int(token)
                if region_id not in regions_by_id:
                    raise RuntimeError(
                        f"Region id {region_id} referenced in coding section but not defined above"
                    )
                group_entries.append(regions_by_id[region_id])

            if group_entries:
                coding_groups.append(group_entries)

    if not coding_groups:
        raise RuntimeError(f"No coding groups found in {path}")

    return coding_groups


def parse_last_completed_cycle(path: Path):
    completed_cycles = []
    current_cycle = {}
    current_region = None

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            if DONE_MARKER in raw_line:
                if current_cycle:
                    completed_cycles.append(current_cycle)
                current_cycle = {}
                current_region = None
                continue

            region_match = REGION_PATTERN.search(raw_line)
            if region_match:
                current_region = region_match.group(1).strip()
                current_cycle.setdefault(current_region, {})
                continue

            segment_match = SEGMENT_PATTERN.search(raw_line)
            if segment_match and current_region is not None:
                index = int(segment_match.group(1))
                valid_size = int(segment_match.group(2))
                current_cycle.setdefault(current_region, {})[index] = valid_size

    if not completed_cycles:
        return {}
    return completed_cycles[-1]


def merge_region_data(logs_path: Path):
    merged = {}
    sources = {}
    log_files = sorted(logs_path.glob("*.log"))
    if not log_files:
        raise RuntimeError(f"No copied server logs found in {logs_path}")

    for log_file in log_files:
        cycle = parse_last_completed_cycle(log_file)
        if not cycle:
            continue
        for region_min_key, series in cycle.items():
            merged.setdefault(region_min_key, {})
            for index, valid_size in series.items():
                if index in merged[region_min_key] and merged[region_min_key][index] != valid_size:
                    raise RuntimeError(
                        f"Conflicting valid_size for region {region_min_key} index {index}: "
                        f"{merged[region_min_key][index]} vs {valid_size} from {log_file.name}"
                    )
                merged[region_min_key][index] = valid_size
            sources.setdefault(region_min_key, []).append(log_file.name)

    if not merged:
        raise RuntimeError(f"No completed GC valid-data cycle found in {logs_path}")

    return merged, sources


def make_nice_integer_step(raw_step: float) -> int:
    if raw_step <= 1:
        return 1

    magnitude = 10 ** math.floor(math.log10(raw_step))
    normalized = raw_step / magnitude
    if normalized <= 1:
        nice = 1
    elif normalized <= 2:
        nice = 2
    elif normalized <= 5:
        nice = 5
    else:
        nice = 10
    return max(1, int(nice * magnitude))


def make_x_ticks(max_x: int):
    if max_x <= 0:
        return [0, 1]

    target_intervals = max(1, min(X_AXIS_TARGET_TICKS - 1, max_x + 1))
    step = make_nice_integer_step((max_x + 1) / target_intervals)
    top_tick = ((max_x // step) + 1) * step
    if top_tick <= max_x:
        top_tick += step
    return list(range(0, top_tick + 1, step))


def make_x_ticks_for_axis_max(max_x: int):
    ticks = make_x_ticks(max_x)
    ticks = [tick for tick in ticks if tick <= max_x]
    if not ticks or ticks[-1] != max_x:
        ticks.append(max_x)
    return ticks


def render_scatter_plot(
    output_path: Path,
    title: str,
    data_x_max: int,
    y_max: float,
    y_ticks,
    series_list,
    x_label: str,
    y_label: str,
    x_tick_max=None,
):
    fig, ax = plt.subplots(figsize=PLOT_FIGSIZE, dpi=200)

    for series in series_list:
        if not series["points"]:
            continue
        if x_tick_max is None:
            visible_points = series["points"]
        else:
            visible_points = [point for point in series["points"] if point[0] <= x_tick_max]
        if not visible_points:
            continue
        xs = [point[0] for point in visible_points]
        ys = [point[1] for point in visible_points]
        marker_color = to_rgba(
            series["color"],
            series.get("alpha", NONZERO_COUNT_ALPHA),
        )
        ax.scatter(
            xs,
            ys,
            s=SCATTER_SIZE,
            facecolors=marker_color,
            edgecolors="none",
            linewidths=0,
            label=series["label"],
        )

    if title:
        ax.set_title(title)
    ax.set_xlabel(x_label)
    ax.set_ylabel(y_label, labelpad=12)
    ax.set_ylim(-0.5, y_max + 0.5)

    if x_tick_max is None:
        x_ticks = make_x_ticks(data_x_max)
        ax.set_xlim(0, x_ticks[-1])
    else:
        x_ticks = make_x_ticks_for_axis_max(x_tick_max)
        ax.set_xlim(0, x_tick_max)
    ax.set_xticks(x_ticks)
    ax.xaxis.set_major_formatter(FormatStrFormatter("%d"))
    ax.xaxis.set_minor_locator(AutoMinorLocator(2))
    ax.xaxis.set_minor_formatter(NullFormatter())

    ax.set_yticks(y_ticks)
    ax.grid(False)
    ax.tick_params(axis="both", which="major", width=TICK_LINEWIDTH, length=MAJOR_TICK_LENGTH)
    ax.tick_params(
        axis="both",
        which="minor",
        width=TICK_LINEWIDTH,
        length=MINOR_TICK_LENGTH,
        labelbottom=False,
        labelleft=False,
    )
    for spine in ax.spines.values():
        spine.set_linewidth(AXIS_LINEWIDTH)

    top_margin = 0.90 if title else 0.94
    fig.subplots_adjust(left=0.1, right=0.94, bottom=0.22, top=top_margin)
    fig.savefig(output_path)
    plt.close(fig)


def save_legend_figure(series_list, output_path: Path):
    output_path.parent.mkdir(parents=True, exist_ok=True)
    unique_series = []
    seen = set()
    for series in series_list:
        key = (series["label"], series["color"])
        if key in seen:
            continue
        seen.add(key)
        unique_series.append(series)

    if not unique_series:
        return

    handles = [
        plt.Line2D(
            [],
            [],
            color=to_rgba(series["color"], series.get("alpha", NONZERO_COUNT_ALPHA)),
            marker="o",
            markerfacecolor=to_rgba(series["color"], series.get("alpha", NONZERO_COUNT_ALPHA)),
            markeredgecolor="none",
            markeredgewidth=0,
            linestyle="None",
            markersize=LEGEND_MARKER_SIZE,
            label=series["label"],
        )
        for series in unique_series
    ]
    labels = [series["label"] for series in unique_series]

    fig = plt.figure(figsize=LEGEND_FIGSIZE)
    fig.legend(
        handles,
        labels,
        frameon=False,
        loc="center",
        ncol=max(1, len(labels)),
        fontsize=GLOBAL_FONT_SIZE,
        columnspacing=LEGEND_COLUMN_SPACING,
        handletextpad=LEGEND_HANDLE_TEXT_PAD,
    )
    fig.savefig(output_path, dpi=300)
    plt.close(fig)


def write_rows(path: Path, header, rows):
    with path.open("w", encoding="utf-8") as handle:
        handle.write("\t".join(header) + "\n")
        for row in rows:
            handle.write("\t".join(str(item) for item in row) + "\n")


def get_gc_title_label(label: str):
    lowered = label.lower()
    if "sync" in lowered:
        return "lazy"
    if "none" in lowered:
        return "no"
    return label


def get_run_time_label(label: str):
    match = re.search(r"(?:^|[_-])rt(\d+)(?:$|[_-])", label)
    if match:
        run_time = int(match.group(1))
        if run_time % 1_000_000 == 0:
            return f"{run_time // 1_000_000}M"
        return str(run_time)
    return label


def render_title(template: str, default_title: str, group_id: int, gc_label: str, run_time_label: str, run_label: str):
    if not template:
        return ""
    title_template = template
    return title_template.format(
        group_id=group_id,
        gc=gc_label,
        run_time=run_time_label,
        run_label=run_label,
    )


def configure_matplotlib():
    plt.rcParams.update(
        {
            "font.size": GLOBAL_FONT_SIZE,
            "font.family": "sans-serif",
            "font.sans-serif": GLOBAL_FONT_FALLBACKS,
            "axes.linewidth": AXIS_LINEWIDTH,
        }
    )


def iter_run_specs(args):
    if args.runs_root is None:
        yield args.logs_dir, args.output_dir, args.run_label
        return

    if not args.runs_root.is_dir():
        raise RuntimeError(f"Runs root does not exist or is not a directory: {args.runs_root}")

    processed = False
    for run_dir in sorted(args.runs_root.iterdir()):
        if not run_dir.is_dir():
            continue
        logs_dir = run_dir / "server_logs"
        if not logs_dir.is_dir():
            print(f"Skipping {run_dir}: missing server_logs")
            continue
        processed = True
        yield logs_dir, run_dir / "plots", run_dir.name

    if not processed:
        raise RuntimeError(f"No run subdirectories with server_logs found under {args.runs_root}")


def process_run(args, logs_dir: Path, output_dir: Path, run_label: str):
    output_dir.mkdir(parents=True, exist_ok=True)
    os.environ["MPLCONFIGDIR"] = str(output_dir / ".matplotlib")
    Path(os.environ["MPLCONFIGDIR"]).mkdir(parents=True, exist_ok=True)

    region_groups = parse_region_groups(args.regions_file)
    region_data, region_sources = merge_region_data(logs_dir)
    gc_title_label = get_gc_title_label(run_label)
    run_time_label = get_run_time_label(run_label)
    custom_legend_names = parse_csv_list(args.legend_names)

    raw_rows = []
    for region_min_key in sorted(region_data):
        for index in sorted(region_data[region_min_key]):
            raw_rows.append(
                (
                    region_min_key,
                    index,
                    region_data[region_min_key][index],
                    f"{region_data[region_min_key][index] * 100.0 / SEGMENT_BYTES:.6f}",
                    ",".join(region_sources.get(region_min_key, [])),
                )
            )
    write_rows(
        output_dir / "raw_region_valid_data.tsv",
        ["region_min_key", "index", "valid_size", "valid_percent", "source_logs"],
        raw_rows,
    )

    group_summary_rows = []
    processed_rows = []
    count_rows = []
    valid_legend_series = []
    count_legend_series = []

    for group_id, group in enumerate(region_groups):
        min_keys = [entry["min_key"] for entry in group]
        missing_regions = [min_key for min_key in min_keys if min_key not in region_data]
        if missing_regions:
            raise RuntimeError(
                f"Missing region data for group {group_id}: {', '.join(missing_regions)}"
            )

        empty_regions = [min_key for min_key in min_keys if not region_data[min_key]]
        if empty_regions:
            raise RuntimeError(
                f"Parsed no segment points for group {group_id}: {', '.join(empty_regions)}"
            )

        max_ids = {min_key: max(region_data[min_key]) for min_key in min_keys}
        common_cutoff = min(max_ids.values())
        if args.no_truncate:
            valid_cutoff = max(max_ids.values())
        else:
            valid_cutoff = common_cutoff
        common_x_values = list(range(1, common_cutoff + 1))

        percent_series = []
        non_zero_points = []

        group_data_rows = []
        group_count_rows = []

        if custom_legend_names and len(custom_legend_names) != len(min_keys):
            raise RuntimeError(
                f"--legend-names expects {len(min_keys)} items for group {group_id}, "
                f"got {len(custom_legend_names)}"
            )

        for region_offset, (color, min_key) in enumerate(zip(PERCENT_COLORS, min_keys)):
            points = []
            if args.no_truncate:
                region_x_values = list(range(1, max_ids[min_key] + 1))
            else:
                region_x_values = common_x_values
            for index in region_x_values:
                valid_size = region_data[min_key].get(index, 0)
                valid_percent = valid_size * 100.0 / SEGMENT_BYTES
                points.append((index, valid_percent))
                group_data_rows.append(
                    (group_id, min_key, index, valid_size, f"{valid_percent:.6f}")
                )
                processed_rows.append(
                    (group_id, min_key, index, valid_size, f"{valid_percent:.6f}")
                )
            if custom_legend_names:
                region_label = custom_legend_names[region_offset]
            else:
                region_label = rf"$d_{{{region_offset}}}$"
            percent_series.append({
                "color": color,
                "points": points,
                "label": region_label,
                "alpha": VALID_PERCENT_ALPHA,
            })

        for index in common_x_values:
            count = sum(1 for min_key in min_keys if region_data[min_key].get(index, 0) != 0)
            non_zero_points.append((index, count))
            group_count_rows.append((group_id, index, count))
            count_rows.append((group_id, index, count))

        group_summary_rows.append(
            (
                group_id,
                ", ".join(min_keys),
                common_cutoff,
                ",".join(f"{key}:{value}" for key, value in max_ids.items()),
            )
        )

        write_rows(
            output_dir / f"group_{group_id}_valid_percent.tsv",
            ["group_id", "region_min_key", "index", "valid_size", "valid_percent"],
            group_data_rows,
        )
        write_rows(
            output_dir / f"group_{group_id}_nonzero_count.tsv",
            ["group_id", "index", "nonzero_region_count"],
            group_count_rows,
        )

        count_series = [{
            "color": "#444444",
            "points": non_zero_points,
            "label": args.count_legend_name,
            "alpha": NONZERO_COUNT_ALPHA,
        }]
        if not valid_legend_series:
            valid_legend_series.extend({"color": s["color"], "label": s["label"]} for s in percent_series)
        if not count_legend_series:
            count_legend_series.extend({"color": s["color"], "label": s["label"]} for s in count_series)

        render_scatter_plot(
            output_dir / f"group_{group_id}_valid_percent_scatter.pdf",
            render_title(
                args.valid_title,
                "Valid data percent of segments in coding region {group_id} under {gc} GC. run {run_time}",
                group_id,
                gc_title_label,
                run_time_label,
                run_label,
            ),
            valid_cutoff,
            100.0,
            [0, 20, 40, 60, 80, 100],
            percent_series,
            args.x_label,
            args.valid_y_label,
            args.x_max,
        )

        render_scatter_plot(
            output_dir / f"group_{group_id}_nonzero_count_scatter.pdf",
            render_title(
                args.count_title,
                "Number of valid segment in stripe {group_id} under {gc} GC. run {run_time}",
                group_id,
                gc_title_label,
                run_time_label,
                run_label,
            ),
            common_cutoff,
            4.0,
            [0, 1, 2, 3, 4],
            count_series,
            args.x_label,
            args.count_y_label,
            args.x_max,
        )

    write_rows(
        output_dir / "group_summary.tsv",
        ["group_id", "group_min_keys", "cutoff_index", "region_max_ids"],
        group_summary_rows,
    )
    write_rows(
        output_dir / "processed_group_valid_data.tsv",
        ["group_id", "region_min_key", "index", "valid_size", "valid_percent"],
        processed_rows,
    )
    write_rows(
        output_dir / "processed_group_nonzero_count.tsv",
        ["group_id", "index", "nonzero_region_count"],
        count_rows,
    )
    save_legend_figure(valid_legend_series, output_dir / "valid_percent_legend.pdf")
    save_legend_figure(count_legend_series, output_dir / "nonzero_count_legend.pdf")

    print(f"Generated GC segment scatter plots for {run_label} in {output_dir}")


def main():
    args = parse_args()
    configure_matplotlib()

    for logs_dir, output_dir, run_label in iter_run_specs(args):
        process_run(args, logs_dir, output_dir, run_label)


if __name__ == "__main__":
    main()
