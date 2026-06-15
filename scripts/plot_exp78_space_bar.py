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
from matplotlib.patches import Rectangle
from matplotlib.ticker import FuncFormatter, MaxNLocator

BAR_COLORS = ["#9AC9DB", "#BB9727", "#C82423", "#54B345", "#eddd86"]

DEFAULT_WORKLOADS = ["load", "a"]
DEFAULT_BACKUPS = ["replication", "elect", "offline_coding"]
PANEL_FIGSIZE = (4, 5)
LEGEND_FIGSIZE = (8, 1)
REFERENCE_PANEL_WIDTH = 8
GROUP_SPACING = 0.50
GROUP_CLUSTER_WIDTH = 0.36
REFERENCE_GROUP_SPACING = 0.50
REFERENCE_GROUP_COUNT = 5
REFERENCE_ITEM_COUNT = 3
FIXED_CLUSTER_ITEM_COUNT = 4
FIXED_BAR_WIDTH_ITEM_COUNT = 5
REFERENCE_X_MARGIN_FACTOR = 0.03
LAYOUT_X_MARGIN_FACTOR = 0.12
X_MARGIN_FACTOR = 0.20
BASE_SUBPLOT_LEFT = 0.08
BASE_SUBPLOT_RIGHT = 0.98
EXPANDED_SUBPLOT_RIGHT = 1.00
BASE_SUBPLOT_BOTTOM = 0.21
BASE_SUBPLOT_TOP = 0.965
NARROW_SUBPLOT_LEFT = 0.30
SUBPLOT_X_SHIFT = -0.02
MIN_SUBPLOT_LEFT = 0.02
Y_AXIS_LABEL_FIGURE_X = 0.12
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


def compute_group_x_positions(n_groups: int) -> np.ndarray:
    return np.arange(n_groups) * GROUP_SPACING


def compute_bar_width(n_items: int) -> float:
    reference_width = GROUP_CLUSTER_WIDTH / REFERENCE_ITEM_COUNT
    if n_items <= FIXED_BAR_WIDTH_ITEM_COUNT:
        return reference_width
    return min(reference_width, GROUP_CLUSTER_WIDTH / n_items)


def compute_bar_offset(index: int, n_items: int, width: float) -> float:
    return (index - (n_items - 1) / 2) * width


def compute_cluster_bounds(n_items: int, width: float) -> Tuple[float, float]:
    if n_items <= FIXED_CLUSTER_ITEM_COUNT:
        fixed_cluster_width = FIXED_CLUSTER_ITEM_COUNT * width
        return -fixed_cluster_width / 2.0, fixed_cluster_width / 2.0

    cluster_width = max(n_items * width, GROUP_CLUSTER_WIDTH)
    return -cluster_width / 2.0, cluster_width / 2.0


def compute_grouped_x_range(
    n_groups: int,
    n_items: int,
    width: float,
    group_spacing: float = GROUP_SPACING,
    x_margin_factor: float = LAYOUT_X_MARGIN_FACTOR,
    reserve_fixed_bar_width: bool = False,
) -> float:
    left, right = compute_grouped_x_limits(
        n_groups,
        n_items,
        width,
        group_spacing,
        x_margin_factor,
        reserve_fixed_bar_width,
    )
    return right - left


def compute_grouped_x_limits(
    n_groups: int,
    n_items: int,
    width: float,
    group_spacing: float = GROUP_SPACING,
    x_margin_factor: float = X_MARGIN_FACTOR,
    reserve_fixed_bar_width: bool = False,
) -> Tuple[float, float]:
    effective_items = (
        FIXED_BAR_WIDTH_ITEM_COUNT
        if reserve_fixed_bar_width and n_items <= FIXED_BAR_WIDTH_ITEM_COUNT
        else n_items
    )
    cluster_left, cluster_right = compute_cluster_bounds(effective_items, width)
    left = cluster_left
    right = (n_groups - 1) * group_spacing + cluster_right

    if reserve_fixed_bar_width and n_items <= FIXED_BAR_WIDTH_ITEM_COUNT:
        pad_left, pad_right = compute_cluster_bounds(FIXED_CLUSTER_ITEM_COUNT, width)
        pad_right = (n_groups - 1) * group_spacing + pad_right
        pad = (pad_right - pad_left) * x_margin_factor
    else:
        pad = (right - left) * x_margin_factor
    return left - pad, right + pad


def set_grouped_x_limits(ax, n_groups: int, n_items: int, width: float) -> None:
    left, right = compute_grouped_x_limits(
        n_groups, n_items, width, reserve_fixed_bar_width=True
    )
    ax.set_xlim(left, right)


def adjust_grouped_subplot(
    fig, n_groups: int, n_items: int, width: float
) -> Tuple[float, float]:
    uses_fixed_width_frame = n_items <= FIXED_BAR_WIDTH_ITEM_COUNT
    subplot_right = EXPANDED_SUBPLOT_RIGHT if uses_fixed_width_frame else BASE_SUBPLOT_RIGHT
    reference_range = compute_grouped_x_range(
        REFERENCE_GROUP_COUNT,
        REFERENCE_ITEM_COUNT,
        GROUP_CLUSTER_WIDTH / REFERENCE_ITEM_COUNT,
        REFERENCE_GROUP_SPACING,
        REFERENCE_X_MARGIN_FACTOR,
    )
    layout_range = compute_grouped_x_range(
        n_groups, n_items, width, reserve_fixed_bar_width=uses_fixed_width_frame
    )
    display_range = compute_grouped_x_range(
        n_groups,
        n_items,
        width,
        x_margin_factor=X_MARGIN_FACTOR,
        reserve_fixed_bar_width=uses_fixed_width_frame,
    )
    base_width = BASE_SUBPLOT_RIGHT - BASE_SUBPLOT_LEFT
    layout_width_on_reference_panel = min(
        base_width, base_width * layout_range / reference_range
    )
    layout_target_width = min(
        base_width,
        layout_width_on_reference_panel * REFERENCE_PANEL_WIDTH / PANEL_FIGSIZE[0],
    )
    target_width = layout_target_width * display_range / layout_range
    label_reference_width = layout_target_width

    if n_groups >= REFERENCE_GROUP_COUNT:
        left = BASE_SUBPLOT_LEFT
    else:
        anchor_items = (
            FIXED_CLUSTER_ITEM_COUNT
            if uses_fixed_width_frame
            else n_items
        )
        anchor_width = compute_bar_width(anchor_items)
        anchor_range = compute_grouped_x_range(n_groups, anchor_items, anchor_width)
        anchor_width_on_reference_panel = min(
            base_width, base_width * anchor_range / reference_range
        )
        anchor_target_width = min(
            base_width,
            anchor_width_on_reference_panel * REFERENCE_PANEL_WIDTH / PANEL_FIGSIZE[0],
        )
        label_reference_width = anchor_target_width
        available_width = BASE_SUBPLOT_RIGHT - NARROW_SUBPLOT_LEFT
        left = NARROW_SUBPLOT_LEFT + max(available_width - anchor_target_width, 0.0) / 2.0
        left_target_width = (
            anchor_target_width if uses_fixed_width_frame else layout_target_width
        )
        left = min(left, BASE_SUBPLOT_RIGHT - left_target_width)
    left = max(MIN_SUBPLOT_LEFT, left + SUBPLOT_X_SHIFT)
    target_width = min(target_width, subplot_right - left)

    fig.subplots_adjust(
        left=left,
        right=left + target_width,
        bottom=BASE_SUBPLOT_BOTTOM,
        top=BASE_SUBPLOT_TOP,
    )
    return target_width, label_reference_width


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


def load_summary(
    input_file: Path,
    workloads: List[str],
    item_keys: List[str],
    item_column: str,
    value_column: str,
    unit_label: str,
) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    if not input_file.exists():
        raise FileNotFoundError(f"Missing input file: {input_file}")

    samples: Dict[Tuple[str, str], List[float]] = {
        (workload, item): [] for workload in workloads for item in item_keys
    }

    with input_file.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        required = {"workload", item_column, value_column}
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"{input_file} is missing columns: {sorted(missing)}")

        for row in reader:
            workload = row["workload"].strip()
            item = row[item_column].strip()
            key = (workload, item)
            if key not in samples:
                continue
            samples[key].append(float(row[value_column]))

    means = np.full((len(workloads), len(item_keys)), np.nan, dtype=float)
    errors = np.full((len(workloads), len(item_keys)), np.nan, dtype=float)
    counts = np.full((len(workloads), len(item_keys)), np.nan, dtype=float)

    for wi, workload in enumerate(workloads):
        for ii, item in enumerate(item_keys):
            values = samples[(workload, item)]
            if not values:
                continue

            n = len(values)
            mean = sum(values) / n
            stddev = statistics.stdev(values) if n >= 2 else 0.0
            ci95 = t_critical_95(n - 1) * stddev / math.sqrt(n) if n >= 2 else 0.0

            means[wi, ii] = mean
            errors[wi, ii] = ci95
            counts[wi, ii] = n

            print(
                f"workload={workload}, {item_column}={item}, n={n}, "
                f"mean={mean:.2f} {unit_label}, ci95=±{ci95:.2f}"
            )

    missing_keys = [
        f"{workload}/{item}"
        for workload in workloads
        for item in item_keys
        if np.isnan(means[workloads.index(workload), item_keys.index(item)])
    ]
    if missing_keys:
        raise ValueError(f"Missing data for: {', '.join(missing_keys)}")

    return means, errors, counts


def plot_bars(
    data: np.ndarray,
    errors: np.ndarray,
    workload_labels: List[str],
    backup_labels: List[str],
    y_axis_label: str,
    x_axis_label: str,
    output_dir: Path,
    output_name: str,
    legend_output_name: str,
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
    output = output_dir / output_name
    legend_output = output_dir / legend_output_name
    fig, ax = plt.subplots(figsize=PANEL_FIGSIZE)

    n_groups, n_items = data.shape
    x = compute_group_x_positions(n_groups)
    width = compute_bar_width(n_items)

    valid_values = data[~np.isnan(data)]
    safe_errors = np.where(np.isnan(errors), 0.0, np.maximum(errors, 0.0))
    valid_max = np.max(valid_values) if valid_values.size > 0 else 0.0
    valid_err_max = np.max(safe_errors) if safe_errors.size > 0 else 0.0
    label_pad = max((valid_max + valid_err_max) * 0.015, 0.05)
    value_x_offset = width * 0.1
    max_label_y = 0.0
    value_text_items = []

    for i in range(n_items):
        offset = compute_bar_offset(i, n_items, width)
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
                bar.get_x() + bar.get_width() / 2 + value_x_offset,
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
    set_grouped_x_limits(ax, n_groups, n_items, width)
    ax.set_xlabel(x_axis_label)
    ax.set_ylabel(y_axis_label)
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

    target_width, _ = adjust_grouped_subplot(
        fig, n_groups, n_items, width
    )
    axes_left = ax.get_position().x0
    y_axis_label_x = 0.0
    if target_width > 0:
        y_axis_label_x = (Y_AXIS_LABEL_FIGURE_X - axes_left) / target_width
    ax.yaxis.set_label_coords(y_axis_label_x, 0.42)
    apply_output_font(fig)
    fig.savefig(output, dpi=300)
    plt.close(fig)
    print(f"Saved figure to {output}")

    save_legend_figure(legend_handles, legend_labels, legend_output)


def save_legend_figure(handles, labels, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    n_items = max(1, len(labels))
    n_columns = min(n_items, 2)
    n_rows = math.ceil(n_items / n_columns)
    fig_height = LEGEND_FIGSIZE[1] * 1.7
    fig_width = LEGEND_FIGSIZE[0]
    fig = plt.figure(figsize=(fig_width, fig_height))
    ax = fig.add_axes([0.0, 0.0, 1.0, 1.0])
    ax.set_axis_off()
    ax.set_xlim(0.0, 1.0)
    ax.set_ylim(0.0, 1.0)

    column_x = [0.24] if n_columns == 1 else [0.02, 0.52]
    row_step = 0.34
    row_top = 0.50 + row_step * (n_rows - 1) / 2.0
    row_y = [0.50] if n_rows == 1 else [row_top - i * row_step for i in range(n_rows)]
    handle_width = (2.0 * GLOBAL_FONT_SIZE / 72.0) / fig_width
    handle_height = (0.7 * GLOBAL_FONT_SIZE / 72.0) / fig_height
    text_pad = 0.02

    for index, (handle, label) in enumerate(zip(handles, labels)):
        row = index // n_columns
        column = index % n_columns
        x = column_x[column]
        y = row_y[row]
        patch = handle.patches[0] if hasattr(handle, "patches") else handle
        rect = Rectangle(
            (x, y - handle_height / 2.0),
            handle_width,
            handle_height,
            facecolor=patch.get_facecolor(),
            edgecolor=patch.get_edgecolor(),
            linewidth=patch.get_linewidth(),
            transform=ax.transAxes,
            clip_on=False,
        )
        ax.add_patch(rect)
        ax.text(
            x + handle_width + text_pad,
            y,
            label,
            ha="left",
            va="center",
            fontsize=GLOBAL_FONT_SIZE,
            transform=ax.transAxes,
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
        help="Comma-separated item keys to plot, in bar order.",
    )
    parser.add_argument(
        "--item-column",
        default="backup_method",
        help="TSV column used to group bars. Defaults to backup_method.",
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
    parser.add_argument(
        "--value-column",
        default="total_used_gib",
        help="Numeric TSV column to aggregate and plot.",
    )
    parser.add_argument(
        "--unit-label",
        default="GiB",
        help="Unit label used in console summary output.",
    )
    parser.add_argument("--output-name", default="space_occupation.pdf")
    parser.add_argument("--legend-output-name", default="legend.pdf")
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

    means, errors, _ = load_summary(
        args.input,
        workloads,
        backups,
        args.item_column,
        args.value_column,
        args.unit_label,
    )
    plot_bars(
        data=means,
        errors=errors,
        workload_labels=workload_labels,
        backup_labels=backup_labels,
        y_axis_label=args.y_axis_label,
        x_axis_label=args.x_axis_label,
        output_dir=args.output,
        output_name=args.output_name,
        legend_output_name=args.legend_output_name,
    )


if __name__ == "__main__":
    main()
