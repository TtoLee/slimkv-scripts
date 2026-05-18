#!/usr/bin/env python3

import argparse
import csv
import math
import os
import statistics
from pathlib import Path
from typing import Dict, List, Tuple

os.environ.setdefault("MPLCONFIGDIR", "/tmp/matplotlib")

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
import numpy as np
from matplotlib import font_manager
from matplotlib.ticker import FuncFormatter, MaxNLocator

tebis_color = "#9AC9DB"
elect_color = "#BB9727"
slimkv_color = "#C82423"
BAR_COLORS = [tebis_color, elect_color, slimkv_color]

DEFAULT_WORKLOADS = ["load", "a"]
DEFAULT_BACKUPS = ["replication", "elect", "offline_coding"]
PANEL_FIGSIZE = (8, 5)
LEGEND_FIGSIZE = (8, 1)
ARIAL_FONT_PATH = Path("/usr/local/share/fonts/arial/ARIAL.TTF")
GLOBAL_FONT_PROPERTIES = None
if ARIAL_FONT_PATH.exists():
    font_manager.fontManager.addfont(str(ARIAL_FONT_PATH))
    GLOBAL_FONT_PROPERTIES = font_manager.FontProperties(fname=str(ARIAL_FONT_PATH))

GLOBAL_FONT_FAMILY = "Arial"
GLOBAL_FONT_FALLBACKS = ["Arial"]
GLOBAL_FONT_SIZE = 34.0
GLOBAL_VALUE_FONT_SIZE = 27.0
AXIS_LINEWIDTH = 1.5
TICK_LINEWIDTH = 1.5
BAR_EDGE_LINEWIDTH = 1.4


def apply_output_font(fig):
    """Bind figure text to the configured TTF file before PDF export."""
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


def parse_comma_list(value: str) -> List[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def display_workload_label(value: str) -> str:
    return value.upper() if len(value) == 1 else value


def display_backup_label(value: str) -> str:
    return value.replace("_", " ")


def t_critical_95(df: int) -> float:
    t_975 = {
        1: 12.7062047364,
        2: 4.3026527297,
        3: 3.1824463053,
        4: 2.7764451052,
        5: 2.5705818366,
        6: 2.4469118488,
        7: 2.3646242510,
        8: 2.3060041352,
        9: 2.2621571628,
        10: 2.2281388520,
        11: 2.2009851601,
        12: 2.1788128297,
        13: 2.1603686565,
        14: 2.1447866879,
        15: 2.1314495456,
        16: 2.1199052992,
        17: 2.1098155780,
        18: 2.1009220402,
        19: 2.0930240544,
        20: 2.0859634473,
        21: 2.0796138447,
        22: 2.0738730679,
        23: 2.0686576104,
        24: 2.0638985616,
        25: 2.0595385537,
        26: 2.0555294386,
        27: 2.0518305165,
        28: 2.0484071418,
        29: 2.0452296421,
        30: 2.0422724563,
    }
    return t_975.get(df, 1.9599639845)


def load_space_summary(
    input_file: Path,
    workloads: List[str],
    backups: List[str],
) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    if not input_file.exists():
        raise FileNotFoundError(f"Missing input file: {input_file}")

    samples: Dict[Tuple[str, str], List[float]] = {
        (workload, backup): [] for workload in workloads for backup in backups
    }

    with input_file.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        required = {"workload", "backup_method", "total_used_gib"}
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"{input_file} is missing columns: {sorted(missing)}")

        for row in reader:
            workload = row["workload"].strip()
            backup = row["backup_method"].strip()
            key = (workload, backup)
            if key not in samples:
                continue
            samples[key].append(float(row["total_used_gib"]))

    means = np.full((len(workloads), len(backups)), np.nan, dtype=float)
    errors = np.full((len(workloads), len(backups)), np.nan, dtype=float)
    counts = np.full((len(workloads), len(backups)), np.nan, dtype=float)

    for wi, workload in enumerate(workloads):
        for bi, backup in enumerate(backups):
            values = samples[(workload, backup)]
            if not values:
                continue

            n = len(values)
            mean = sum(values) / n
            stddev = statistics.stdev(values) if n >= 2 else 0.0
            ci95 = t_critical_95(n - 1) * stddev / math.sqrt(n) if n >= 2 else 0.0

            means[wi, bi] = mean
            errors[wi, bi] = ci95
            counts[wi, bi] = n

            print(
                f"workload={workload}, backup={backup}, n={n}, "
                f"mean={mean:.2f} GiB, ci95=±{ci95:.2f}"
            )

    missing_keys = [
        f"{workload}/{backup}"
        for workload in workloads
        for backup in backups
        if np.isnan(means[workloads.index(workload), backups.index(backup)])
    ]
    if missing_keys:
        raise ValueError(f"Missing data for: {', '.join(missing_keys)}")

    return means, errors, counts


def plot_space_bars(
    data: np.ndarray,
    errors: np.ndarray,
    workload_labels: List[str],
    backup_labels: List[str],
    y_axis_label: str,
    x_axis_label: str,
    output_dir: Path,
) -> None:
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

    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / "space_occupation.pdf"
    legend_output = output_dir / "legend.pdf"
    fig, ax = plt.subplots(figsize=PANEL_FIGSIZE)

    n_groups, n_items = data.shape
    x = np.arange(n_groups) * 0.50
    width = 0.42 / n_items

    valid_values = data[~np.isnan(data)]
    safe_errors = np.where(np.isnan(errors), 0.0, np.maximum(errors, 0.0))
    valid_max = np.max(valid_values) if valid_values.size > 0 else 0.0
    valid_err_max = np.max(safe_errors) if safe_errors.size > 0 else 0.0
    label_pad = max((valid_max + valid_err_max) * 0.015, 0.05)
    max_label_y = 0.0
    value_text_items = []

    for i in range(n_items):
        offset = (i - (n_items - 1) / 2) * width
        vals = data[:, i]

        bars = ax.bar(
            x + offset,
            vals,
            width=width,
            label=backup_labels[i],
            color=BAR_COLORS[i % len(BAR_COLORS)],
            edgecolor="black",
            linewidth=BAR_EDGE_LINEWIDTH,
        )

        for bar in bars:
            h = bar.get_height()
            label_y = h + label_pad
            max_label_y = max(max_label_y, label_y)
            txt = ax.text(
                bar.get_x() + bar.get_width() / 2,
                label_y,
                f"{h:.0f}",
                ha="center",
                va="bottom",
                fontsize=GLOBAL_VALUE_FONT_SIZE,
                rotation=90.0,
            )
            value_text_items.append(txt)

    ax.set_xticks(x)
    ax.set_xticklabels(workload_labels)
    ax.margins(x=0.03)
    ax.set_xlabel(x_axis_label)
    ax.set_ylabel(y_axis_label)
    ax.yaxis.set_label_coords(-0.23, 0.42)
    ax.tick_params(
        axis="x",
        bottom=True,
        labelbottom=True,
        top=False,
        labeltop=False,
        width=TICK_LINEWIDTH,
    )
    ax.tick_params(
        axis="y",
        left=True,
        labelleft=True,
        right=False,
        labelright=False,
        pad=1,
        width=TICK_LINEWIDTH,
    )
    ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value:.0f}"))

    content_top = max(valid_max, max_label_y)
    top = max(content_top * 1.32, content_top + label_pad * 8.0, content_top + 0.20, 1.0)
    ax.set_ylim(bottom=0, top=top)
    ax.yaxis.set_major_locator(MaxNLocator(nbins=5, min_n_ticks=4, prune="upper"))

    if value_text_items:
        fig.canvas.draw()
        renderer = fig.canvas.get_renderer()
        axes_bbox = ax.get_window_extent(renderer=renderer)
        max_text_top_px = max(
            text.get_window_extent(renderer=renderer).y1 for text in value_text_items
        )
        top_gap_px = 12.0
        overflow_px = max_text_top_px - (axes_bbox.y1 - top_gap_px)
        if overflow_px > 0 and axes_bbox.height > 0:
            y0, y1 = ax.get_ylim()
            data_per_px = (y1 - y0) / axes_bbox.height
            ax.set_ylim(bottom=y0, top=y1 + overflow_px * data_per_px)
            ax.yaxis.set_major_locator(MaxNLocator(nbins=5, min_n_ticks=4, prune="upper"))

    ax.grid(False)

    ax.spines["top"].set_visible(True)
    ax.spines["right"].set_visible(True)
    for spine in ax.spines.values():
        spine.set_linewidth(AXIS_LINEWIDTH)

    legend_handles, legend_labels = ax.get_legend_handles_labels()

    fig.subplots_adjust(left=0.24, right=0.98, bottom=0.21, top=0.965)
    apply_output_font(fig)
    fig.savefig(output, dpi=300)
    plt.close(fig)
    print(f"Saved figure to {output}")

    save_legend_figure(legend_handles, legend_labels, legend_output)


def save_legend_figure(handles, labels, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    n_items = max(1, len(labels))
    fig = plt.figure(figsize=LEGEND_FIGSIZE)
    fig.legend(
        handles,
        labels,
        frameon=False,
        loc="center",
        ncol=n_items,
        fontsize=GLOBAL_FONT_SIZE,
        handlelength=1.0,
        columnspacing=0.8,
        handletextpad=0.4,
    )
    apply_output_font(fig)
    fig.savefig(output, dpi=300, pad_inches=0.02)
    plt.close(fig)
    print(f"Saved legend figure to {output}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plot exp2_space storage occupation as one grouped bar chart."
    )
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="Output directory")
    parser.add_argument(
        "--workloads",
        default=",".join(DEFAULT_WORKLOADS),
        help="Comma-separated workload keys to plot, in x-axis order.",
    )
    parser.add_argument(
        "--backups",
        default=",".join(DEFAULT_BACKUPS),
        help="Comma-separated backup_method keys to plot, in bar order.",
    )
    parser.add_argument(
        "--bar-label",
        default="",
        help="Optional comma-separated x-axis labels. Defaults to workload names.",
    )
    parser.add_argument(
        "--item-labels",
        default="",
        help="Optional comma-separated legend labels. Defaults to backup names.",
    )
    parser.add_argument("--x-axis-label", default="Workload")
    parser.add_argument("--y-axis-label", default="Space usage (GiB)")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    workloads = parse_comma_list(args.workloads)
    backups = parse_comma_list(args.backups)

    if not workloads:
        raise ValueError("--workloads must not be empty")
    if not backups:
        raise ValueError("--backups must not be empty")

    workload_labels = (
        parse_comma_list(args.bar_label)
        if args.bar_label
        else [display_workload_label(value) for value in workloads]
    )
    backup_labels = (
        parse_comma_list(args.item_labels)
        if args.item_labels
        else [display_backup_label(value) for value in backups]
    )

    if len(workload_labels) != len(workloads):
        raise ValueError("--bar-label count must match --workloads count")
    if len(backup_labels) != len(backups):
        raise ValueError("--item-labels count must match --backups count")

    means, errors, _ = load_space_summary(args.input, workloads, backups)
    plot_space_bars(
        data=means,
        errors=errors,
        workload_labels=workload_labels,
        backup_labels=backup_labels,
        y_axis_label=args.y_axis_label,
        x_axis_label=args.x_axis_label,
        output_dir=args.output,
    )


if __name__ == "__main__":
    main()
