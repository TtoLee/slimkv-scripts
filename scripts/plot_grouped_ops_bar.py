#!/usr/bin/env python3

import argparse
import csv
import math
import re
import statistics
from pathlib import Path
from typing import List, Tuple

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

tebis_color = '#9AC9DB'
elect_color = '#BB9727'
slimkv_color = '#C82423'
BAR_COLORS = [tebis_color, elect_color, slimkv_color]

LINE_RE = re.compile(r"(\d+)\s+sec\s+([\deE.+-]+)\s+operations\s+([\deE.+-]+)\s+ops/sec")
PM_RE = re.compile(r"^\s*([+-]?\d+(?:\.\d+)?)\s*±\s*([+-]?\d+(?:\.\d+)?)\s*$")
PANEL_FIGSIZE = (8, 5)
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
HEX_COLOR_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")


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


def get_bar_colors(n_items: int):
    if n_items <= 0:
        raise ValueError(f"n_items must be positive, got {n_items}")
    if not BAR_COLORS:
        raise ValueError("BAR_COLORS must not be empty")

    validated_colors = []
    for color in BAR_COLORS:
        c = color.strip()
        if not HEX_COLOR_RE.match(c):
            raise ValueError(
                f"Invalid color '{color}'. Expected #RRGGBB format, e.g. #FF8000."
            )
        validated_colors.append(c)

    return [validated_colors[i % len(validated_colors)] for i in range(n_items)]


def read_groups(groups_file: Path) -> List[List[List[Path]]]:
    groups: List[List[List[Path]]] = []
    with groups_file.open("r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = re.split(r"[\s,]+", line)
            samples_per_item: List[List[Path]] = []
            for token in parts:
                if not token:
                    continue
                sample_paths = [Path(p) for p in token.split(";") if p]
                if len(sample_paths) == 0:
                    raise ValueError(
                        f"Invalid item in {groups_file}: '{token}'. "
                        "Each item must include at least one path."
                    )
                samples_per_item.append(sample_paths)
            groups.append(samples_per_item)

    if not groups:
        raise ValueError(f"No groups found in {groups_file}")
    if len(groups) > 20:
        raise ValueError(f"Too many groups in {groups_file}: {len(groups)}")
    for idx, grp in enumerate(groups, start=1):
        if len(grp) == 0 or len(grp) > 10:
            raise ValueError(f"Group {idx} must contain 1-10 items, got {len(grp)}")
    return groups


def last_operations_per_sec_k(path: Path) -> float:
    if not path.exists():
        raise FileNotFoundError(f"Missing file: {path}")

    first_sec = None
    first_operations = None
    last_sec = None
    last_operations = None
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            m = LINE_RE.search(line)
            if not m:
                continue
            sec = int(m.group(1))
            operations = float(m.group(2))
            if first_sec is None:
                first_sec = sec
                first_operations = operations
            last_sec = sec
            last_operations = operations

    if (
        first_sec is None
        or first_operations is None
        or last_sec is None
        or last_operations is None
    ):
        raise ValueError(f"No valid sec/operations rows found in {path}")

    elapsed_sec = last_sec - first_sec
    elapsed_operations = last_operations - first_operations
    if elapsed_sec <= 0:
        raise ValueError(
            f"Elapsed sec must be positive in {path}, got first={first_sec}, last={last_sec}"
        )
    if elapsed_operations < 0:
        raise ValueError(
            f"Operations must be non-decreasing in {path}, "
            f"got first={first_operations}, last={last_operations}"
        )

    return (elapsed_operations / elapsed_sec) / 1000.0


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


def build_stats_from_groups(
    groups: List[List[List[Path]]],
    bar_labels: List[str],
    item_labels: List[str],
):
    n_groups = len(groups)
    max_items = max(len(g) for g in groups)

    means = np.full((n_groups, max_items), np.nan, dtype=float)
    stddevs = np.full((n_groups, max_items), np.nan, dtype=float)
    errors = np.full((n_groups, max_items), np.nan, dtype=float)
    counts = np.full((n_groups, max_items), np.nan, dtype=float)

    for gi, group in enumerate(groups):
        for ii, sample_files in enumerate(group):
            samples = [last_operations_per_sec_k(file_path) for file_path in sample_files]
            n = len(samples)
            if n == 0:
                continue

            mean = sum(samples) / n
            stddev = statistics.stdev(samples) if n >= 2 else 0.0
            ci95 = t_critical_95(n - 1) * stddev / math.sqrt(n) if n >= 2 else 0.0

            means[gi, ii] = mean
            stddevs[gi, ii] = stddev
            errors[gi, ii] = ci95
            counts[gi, ii] = n

            print(
                f"group={gi + 1} ({bar_labels[gi]}), "
                f"item={ii + 1} ({item_labels[ii]}), "
                f"n={n}, mean={mean:.4f} kops/sec, stddev={stddev:.4f}, ci95=±{ci95:.4f}"
            )

    return means, stddevs, errors, counts


def write_stats_csv(
    output_path: Path,
    counts: np.ndarray,
    means: np.ndarray,
    stddevs: np.ndarray,
    errors: np.ndarray,
    bar_labels: List[str],
    item_labels: List[str],
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "group_index",
            "group_label",
            "item_index",
            "item_label",
            "n",
            "mean_kops_per_sec",
            "stddev_kops_per_sec",
            "ci95_kops_per_sec",
        ])

        n_groups, n_items = means.shape
        for gi in range(n_groups):
            for ii in range(n_items):
                if np.isnan(means[gi, ii]):
                    continue
                writer.writerow([
                    gi + 1,
                    bar_labels[gi],
                    ii + 1,
                    item_labels[ii],
                    int(counts[gi, ii]) if not np.isnan(counts[gi, ii]) else 0,
                    f"{means[gi, ii]:.6f}",
                    f"{stddevs[gi, ii]:.6f}" if not np.isnan(stddevs[gi, ii]) else "0.000000",
                    f"{errors[gi, ii]:.6f}" if not np.isnan(errors[gi, ii]) else "0.000000",
                ])

    print(f"Saved statistics to {output_path}")


def read_stats_csv(
    stats_file: Path,
    bar_labels: List[str],
    item_labels: List[str],
):
    if not stats_file.exists():
        raise FileNotFoundError(f"Missing stats file: {stats_file}")

    group_to_idx = {label: i for i, label in enumerate(bar_labels)}
    item_to_idx = {label: i for i, label in enumerate(item_labels)}

    n_groups = len(bar_labels)
    n_items = len(item_labels)

    means = np.full((n_groups, n_items), np.nan, dtype=float)
    stddevs = np.full((n_groups, n_items), np.nan, dtype=float)
    errors = np.full((n_groups, n_items), np.nan, dtype=float)
    counts = np.full((n_groups, n_items), np.nan, dtype=float)

    with stats_file.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        required_fields = {
            "group_label",
            "item_label",
            "n",
            "mean_kops_per_sec",
            "stddev_kops_per_sec",
            "ci95_kops_per_sec",
        }
        missing = required_fields - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"Stats file {stats_file} is missing required columns: {sorted(missing)}")

        for row in reader:
            group_label = row["group_label"].strip()
            item_label = row["item_label"].strip()

            if group_label not in group_to_idx:
                raise ValueError(f"Unknown group_label '{group_label}' in {stats_file}.")
            if item_label not in item_to_idx:
                raise ValueError(f"Unknown item_label '{item_label}' in {stats_file}.")

            gi = group_to_idx[group_label]
            ii = item_to_idx[item_label]

            counts[gi, ii] = float(row["n"])
            means[gi, ii] = float(row["mean_kops_per_sec"])
            stddevs[gi, ii] = float(row["stddev_kops_per_sec"])
            errors[gi, ii] = float(row["ci95_kops_per_sec"])

    print(f"Loaded statistics from {stats_file}")
    return means, stddevs, errors, counts


def parse_mean_pm_ci(value: str) -> Tuple[float, float]:
    m = PM_RE.match(value)
    if not m:
        raise ValueError(f"Invalid mean±ci95 field: '{value}'")
    return float(m.group(1)), float(m.group(2))


def normalize_label(value: str) -> str:
    return re.sub(r"[\s_]+", "", value.strip().lower())


def fmt_mean_pm_ci(mean_value: float, ci_value: float) -> str:
    return f"{mean_value:.2f}±{ci_value:.2f}"


def write_compact_summary_file(
    output_file: Path,
    bar_labels: List[str],
    item_labels: List[str],
    throughput_data: np.ndarray,
    throughput_err: np.ndarray,
    p50_data: np.ndarray,
    p50_err: np.ndarray,
    p99_data: np.ndarray,
    p99_err: np.ndarray,
    p999_data: np.ndarray,
    p999_err: np.ndarray,
) -> None:
    output_file.parent.mkdir(parents=True, exist_ok=True)
    with output_file.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, delimiter="\t")
        writer.writerow(["workload", "backup", "throughput", "p50", "p99", "p999"])
        for gi, workload in enumerate(bar_labels):
            for ii, backup in enumerate(item_labels):
                if np.isnan(throughput_data[gi, ii]):
                    continue
                writer.writerow([
                    workload,
                    backup,
                    fmt_mean_pm_ci(throughput_data[gi, ii], np.nan_to_num(throughput_err[gi, ii], nan=0.0)),
                    fmt_mean_pm_ci(p50_data[gi, ii], np.nan_to_num(p50_err[gi, ii], nan=0.0)),
                    fmt_mean_pm_ci(p99_data[gi, ii], np.nan_to_num(p99_err[gi, ii], nan=0.0)),
                    fmt_mean_pm_ci(p999_data[gi, ii], np.nan_to_num(p999_err[gi, ii], nan=0.0)),
                ])
    print(f"Saved compact summary to {output_file}")


def read_compact_summary_file(
    summary_file: Path,
    bar_labels: List[str],
    item_labels: List[str],
):
    if not summary_file.exists():
        raise FileNotFoundError(f"Missing compact summary file: {summary_file}")

    n_groups = len(bar_labels)
    n_items = len(item_labels)
    throughput_data = np.full((n_groups, n_items), np.nan, dtype=float)
    throughput_err = np.full((n_groups, n_items), np.nan, dtype=float)
    p50_data = np.full((n_groups, n_items), np.nan, dtype=float)
    p50_err = np.full((n_groups, n_items), np.nan, dtype=float)
    p99_data = np.full((n_groups, n_items), np.nan, dtype=float)
    p99_err = np.full((n_groups, n_items), np.nan, dtype=float)
    p999_data = np.full((n_groups, n_items), np.nan, dtype=float)
    p999_err = np.full((n_groups, n_items), np.nan, dtype=float)

    group_idx = {normalize_label(v): i for i, v in enumerate(bar_labels)}
    item_idx = {normalize_label(v): i for i, v in enumerate(item_labels)}

    seen = 0
    with summary_file.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        required = {"workload", "backup", "throughput", "p50", "p99", "p999"}
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise ValueError(
                f"Compact summary file {summary_file} missing columns: {sorted(missing)}"
            )

        for row in reader:
            wk = normalize_label(row["workload"])
            bk = normalize_label(row["backup"])
            if wk not in group_idx:
                raise ValueError(f"Unknown workload '{row['workload']}' in {summary_file}")
            if bk not in item_idx:
                raise ValueError(f"Unknown backup '{row['backup']}' in {summary_file}")

            gi = group_idx[wk]
            ii = item_idx[bk]
            throughput_data[gi, ii], throughput_err[gi, ii] = parse_mean_pm_ci(row["throughput"])
            p50_data[gi, ii], p50_err[gi, ii] = parse_mean_pm_ci(row["p50"])
            p99_data[gi, ii], p99_err[gi, ii] = parse_mean_pm_ci(row["p99"])
            p999_data[gi, ii], p999_err[gi, ii] = parse_mean_pm_ci(row["p999"])
            seen += 1

    expected = n_groups * n_items
    if seen != expected:
        raise ValueError(
            f"Compact summary rows ({seen}) do not match bar-label * item-label ({expected})"
        )

    print(f"Loaded compact summary from {summary_file}")
    return {
        "throughput": (throughput_data, throughput_err),
        "p50": (p50_data, p50_err),
        "p99": (p99_data, p99_err),
        "p999": (p999_data, p999_err),
    }


def parse_summary_file(
    summary_file: Path,
    group_count: int,
    item_count: int,
):
    if not summary_file.exists():
        raise FileNotFoundError(f"Missing summary file: {summary_file}")

    rows = []
    with summary_file.open("r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("metric\t") or line.startswith("metric "):
                continue

            parts = re.split(r"\t+|\s{2,}", line)
            parts = [p.strip() for p in parts if p.strip()]
            if len(parts) < 8:
                raise ValueError(
                    f"Summary line has too few columns ({len(parts)}): {line}"
                )

            # Support both compact and full summary formats.
            # compact: workload backup p50 - - - p99 p999
            # full:    metric group selected_total_count avg stddev min max p50 p99 p999
            if len(parts) >= 10:
                p50_field = parts[7]
                p99_field = parts[8]
                p999_field = parts[9]
            else:
                p50_field = parts[2]
                p99_field = parts[6]
                p999_field = parts[7]

            p50_mean, p50_ci = parse_mean_pm_ci(p50_field)
            p99_mean, p99_ci = parse_mean_pm_ci(p99_field)
            p999_mean, p999_ci = parse_mean_pm_ci(p999_field)

            rows.append({
                "p50_mean": p50_mean,
                "p50_ci": p50_ci,
                "p99_mean": p99_mean,
                "p99_ci": p99_ci,
                "p999_mean": p999_mean,
                "p999_ci": p999_ci,
            })

    expected_rows = group_count * item_count
    if len(rows) != expected_rows:
        raise ValueError(
            f"Summary file row count ({len(rows)}) does not match "
            f"group_count * item_count ({group_count} * {item_count} = {expected_rows})."
        )

    p50_means = np.full((group_count, item_count), np.nan, dtype=float)
    p50_errors = np.full((group_count, item_count), np.nan, dtype=float)
    p99_means = np.full((group_count, item_count), np.nan, dtype=float)
    p99_errors = np.full((group_count, item_count), np.nan, dtype=float)
    p999_means = np.full((group_count, item_count), np.nan, dtype=float)
    p999_errors = np.full((group_count, item_count), np.nan, dtype=float)

    idx = 0
    for gi in range(group_count):
        for ii in range(item_count):
            row = rows[idx]
            idx += 1

            p50_means[gi, ii] = row["p50_mean"]
            p50_errors[gi, ii] = row["p50_ci"]
            p99_means[gi, ii] = row["p99_mean"]
            p99_errors[gi, ii] = row["p99_ci"]
            p999_means[gi, ii] = row["p999_mean"]
            p999_errors[gi, ii] = row["p999_ci"]

    print(f"Loaded summary data from {summary_file}")
    return {
        "p50": (p50_means, p50_errors),
        "p99": (p99_means, p99_errors),
        "p999": (p999_means, p999_errors),
    }


def plot_grouped_bars_on_ax(
    ax,
    data: np.ndarray,
    errors: np.ndarray,
    bar_labels: List[str],
    item_labels: List[str],
    y_axis_label: str,
    title: str,
    colors,
    value_rotation: float,
    value_font_size: float,
    x_axis_label: str = "",
):
    n_groups, n_items = data.shape
    x = np.arange(n_groups) * 0.50
    width = 0.42 / n_items

    valid_values = data[~np.isnan(data)]
    use_one_decimal = valid_values.size > 0 and np.all(np.abs(valid_values) < 10)
    axis_use_decimal = valid_values.size > 0 and np.max(np.abs(valid_values)) < 1.0
    value_fmt = "{:.1f}" if use_one_decimal else "{:.0f}"

    valid_max = np.max(valid_values) if valid_values.size > 0 else 0.0
    safe_errors = np.where(np.isnan(errors), 0.0, np.maximum(errors, 0.0))
    valid_err_max = np.max(safe_errors) if safe_errors.size > 0 else 0.0
    upper = valid_max + valid_err_max
    label_pad = max(upper * 0.015, 0.05)
    value_x_offset = width * 0.1
    max_label_y = 0.0
    value_text_items = []
    has_four_digit_label = False

    for i in range(n_items):
        offset = (i - (n_items - 1) / 2) * width
        vals = data[:, i]
        err_vals = errors[:, i]

        bars = ax.bar(
            x + offset,
            np.nan_to_num(vals, nan=0.0),
            width=width,
            label=item_labels[i],
            color=colors[i % len(colors)],
            edgecolor="black",
            linewidth=BAR_EDGE_LINEWIDTH,
        )

        safe_err = np.where(np.isnan(err_vals), 0.0, np.maximum(err_vals, 0.0))
        valid_mask = ~np.isnan(vals)
        ax.errorbar(
            (x + offset)[valid_mask],
            vals[valid_mask],
            yerr=safe_err[valid_mask],
            fmt="none",
            ecolor="black",
            elinewidth=2.0,
            capsize=6,
            capthick=2.0,
            zorder=3,
        )

        for b_idx, bar in enumerate(bars):
            if np.isnan(vals[b_idx]):
                bar.set_alpha(0.15)
                continue
            h = bar.get_height()
            label_y = h + safe_err[b_idx] + label_pad
            if label_y > max_label_y:
                max_label_y = label_y
            text_value = value_fmt.format(h)
            if len(re.sub(r"\D", "", text_value)) >= 4:
                has_four_digit_label = True
            txt = ax.text(
                bar.get_x() + bar.get_width() / 2 + value_x_offset,
                label_y,
                text_value,
                ha="center",
                va="bottom",
                fontsize=value_font_size,
                rotation=value_rotation,
            )
            value_text_items.append((txt, bar))

    ax.set_xticks(x)
    ax.set_xticklabels(bar_labels)
    ax.margins(x=0.03)
    ax.tick_params(
        axis="x",
        bottom=True,
        labelbottom=True,
        top=False,
        labeltop=False,
        width=TICK_LINEWIDTH,
    )
    ax.set_xlabel(x_axis_label if x_axis_label else "Workload")
    ax.set_ylabel(y_axis_label)
    # Keep y-axis title aligned across all figures; tick-to-title distance may vary by chart.
    ax.yaxis.set_label_coords(-0.23, 0.42)
    ax.tick_params(
        axis="y",
        left=True,
        labelleft=True,
        right=False,
        labelright=False,
        pad=1,
        width=TICK_LINEWIDTH,
    )
    ax.yaxis.set_major_formatter(
        FuncFormatter(lambda value, _: f"{value:.1f}" if axis_use_decimal else f"{value:.0f}")
    )

    # Keep y-axis upper bound above data max and reserve extra room for value labels.
    content_top = max(upper, max_label_y)
    top_padding_factor = 0.17 if has_four_digit_label else 0.12
    label_pad_factor = 2.8 if has_four_digit_label else 2.0
    absolute_padding = 0.30 if has_four_digit_label else 0.20
    top_padding = max(content_top * top_padding_factor, label_pad * label_pad_factor, absolute_padding)
    target_top = content_top + top_padding
    if target_top <= 0:
        target_top = 1.0

    # Do not snap to a full tick step: keep y-limit as short as possible.
    min_top = upper + max(abs(upper) * 1e-6, 1e-9)
    top = max(target_top, min_top)

    # Pixel-aware safety gap so top border never overlaps value labels.
    axes_height_px = (
        ax.figure.get_size_inches()[1] * ax.figure.dpi * ax.get_position().height
    )
    if axes_height_px > 0:
        data_per_px = top / axes_height_px
        label_height_px = value_font_size * ax.figure.dpi / 72.0
        clearance_factor = 0.62 if has_four_digit_label else 0.45
        min_clearance_floor_px = 9.5 if has_four_digit_label else 6.0
        min_clearance_px = max(label_height_px * clearance_factor, min_clearance_floor_px)
        min_clearance_data = data_per_px * min_clearance_px
        if top - max_label_y < min_clearance_data:
            top = max_label_y + min_clearance_data

    ax.set_ylim(bottom=0, top=top)
    ax.yaxis.set_major_locator(MaxNLocator(nbins=5, min_n_ticks=4, prune="upper"))

    # Final guard: measure rendered label extents and enforce a pixel gap to top border.
    if value_text_items:
        fig = ax.figure
        fig.canvas.draw()
        renderer = fig.canvas.get_renderer()
        axes_bbox = ax.get_window_extent(renderer=renderer)
        if axes_bbox.height > 0:
            y0, y1 = ax.get_ylim()
            data_per_px = (y1 - y0) / axes_bbox.height
            # Keep text baseline above bar top with a small pixel gap.
            min_bar_gap_px = 4.0
            max_overlap_px = 0.0
            for txt, bar in value_text_items:
                txt_bbox = txt.get_window_extent(renderer=renderer)
                bar_bbox = bar.get_window_extent(renderer=renderer)
                overlap_px = (bar_bbox.y1 + min_bar_gap_px) - txt_bbox.y0
                if overlap_px > max_overlap_px:
                    max_overlap_px = overlap_px

            if max_overlap_px > 0:
                shift_data = max_overlap_px * data_per_px
                for txt, _ in value_text_items:
                    txt.set_y(txt.get_position()[1] + shift_data)
                fig.canvas.draw()
                renderer = fig.canvas.get_renderer()
                axes_bbox = ax.get_window_extent(renderer=renderer)

        top_gap_px = 10.0 if has_four_digit_label else 5.0
        max_text_top_px = max(t.get_window_extent(renderer=renderer).y1 for t, _ in value_text_items)
        overflow_px = max_text_top_px - (axes_bbox.y1 - top_gap_px)

        if overflow_px > 0 and axes_bbox.height > 0:
            y0, y1 = ax.get_ylim()
            data_per_px = (y1 - y0) / axes_bbox.height
            new_top = y1 + overflow_px * data_per_px
            ax.set_ylim(bottom=y0, top=new_top)
            ax.yaxis.set_major_locator(MaxNLocator(nbins=5, min_n_ticks=4, prune="upper"))

    ax.grid(False)

    ax.spines["top"].set_visible(True)
    ax.spines["right"].set_visible(True)
    for spine in ax.spines.values():
        spine.set_linewidth(AXIS_LINEWIDTH)

    return ax.get_legend_handles_labels()

def build_panel_output_path(output_dir: Path, panel_tag: str) -> Path:
    return output_dir / f"{panel_tag}.pdf"


def build_legend_output_path(output_dir: Path) -> Path:
    return output_dir / "legend.pdf"


def save_legend_figure(handles, labels, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    n_items = max(1, len(labels))
    # Keep legend width aligned with two main panels combined.
    fig = plt.figure(figsize=(PANEL_FIGSIZE[0] * 2.0, 1.0))
    fig.legend(
        handles,
        labels,
        frameon=False,
        loc="center",
        ncol=n_items,
        fontsize=GLOBAL_FONT_SIZE,
    )
    apply_output_font(fig)
    fig.savefig(output, dpi=300, pad_inches=0.02)
    plt.close(fig)
    print(f"Saved legend figure to {output}")


def plot_panels_separately(
    panels,
    item_labels: List[str],
    output_dir: Path,
    colors,
):
    mpl.rcParams.update({
        "font.size": GLOBAL_FONT_SIZE,
        "font.family": GLOBAL_FONT_FAMILY,
        "font.sans-serif": GLOBAL_FONT_FALLBACKS,
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
        "pdf.use14corefonts": False,
        "text.usetex": False,
        "axes.linewidth": AXIS_LINEWIDTH,
    })
    output_dir.mkdir(parents=True, exist_ok=True)

    legend_handles = None
    legend_labels = None

    for panel in panels:
        panel_output = build_panel_output_path(output_dir, panel["file_tag"])
        fig, ax = plt.subplots(figsize=PANEL_FIGSIZE)

        handles, labels = plot_grouped_bars_on_ax(
            ax=ax,
            data=panel["data"],
            errors=panel["errors"],
            bar_labels=panel["bar_labels"],
            item_labels=item_labels,
            y_axis_label=panel["y_label"],
            title=panel["title"],
            colors=colors,
            value_rotation=90.0,
            value_font_size=GLOBAL_VALUE_FONT_SIZE,
            x_axis_label=panel.get("x_label", ""),
        )
        if legend_handles is None:
            legend_handles, legend_labels = handles, labels

        # Use fixed margins and no tight bounding-box so all output figures have identical size.
        fig.subplots_adjust(left=0.24, right=0.98, bottom=0.21, top=0.965)
        apply_output_font(fig)
        fig.savefig(panel_output, dpi=300)
        plt.close(fig)
        print(f"Saved figure to {panel_output}")

    if legend_handles and legend_labels:
        save_legend_figure(
            legend_handles,
            legend_labels,
            build_legend_output_path(output_dir),
        )

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Modes:\n"
            "1) only --groups-file\n"
            "2) only --summary-input\n"
            "3) --summary-input + --groups-file\n"
            "4) only --compact-input\n"
        )
    )

    parser.add_argument("--groups-file", default="", help="Raw ops-file group definition")
    parser.add_argument("--summary-input", default="", help="Summary text file for avg/p99/p999 plotting")
    parser.add_argument("--compact-input", default="", help="Compact summary TSV with workload/backup/throughput/p50/p99/p999")
    parser.add_argument("--compact-output", default="", help="Optional compact summary TSV output for future re-plotting")

    parser.add_argument("--bar-label", required=True, help="Comma-separated x-axis group labels")
    parser.add_argument("--item-labels", required=True, help="Comma-separated bar legend labels")

    parser.add_argument("--x-axis-label", default="", help="X-axis label for single chart or the standalone panel")
    parser.add_argument("--y1-axis-label", default="", help="Y-axis label for chart #1")
    parser.add_argument("--y2-axis-label", default="", help="Y-axis label for chart #2")
    parser.add_argument("--y3-axis-label", default="", help="Y-axis label for chart #3")
    parser.add_argument("--y4-axis-label", default="", help="Y-axis label for chart #4")

    parser.add_argument("--output", required=True, help="Output directory path")

    args = parser.parse_args()

    has_groups = bool(args.groups_file)
    has_summary = bool(args.summary_input)
    has_compact = bool(args.compact_input)

    if has_compact and (has_groups or has_summary):
        raise ValueError("--compact-input cannot be used together with --groups-file/--summary-input")

    allowed = (
        (has_groups and not has_summary and not has_compact)
        or (has_summary and not has_groups and not has_compact)
        or (has_summary and has_groups and not has_compact)
        or (has_compact and not has_groups and not has_summary)
    )

    if not allowed:
        raise ValueError(
            "Allowed combinations are:\n"
            "  --groups-file\n"
            "  --summary-input\n"
            "  --summary-input + --groups-file\n"
            "  --compact-input"
        )

    return args


def load_standalone_data(args, bar_labels, item_labels):
    if args.groups_file:
        groups = read_groups(Path(args.groups_file))

        if len(bar_labels) != len(groups):
            raise ValueError(
                f"bar-label count ({len(bar_labels)}) must match number of groups ({len(groups)})"
            )

        max_items = max(len(g) for g in groups)
        if len(item_labels) != max_items:
            raise ValueError(
                f"item-labels count ({len(item_labels)}) must match number of items per group ({max_items})"
            )

        means, stddevs, errors, counts = build_stats_from_groups(
            groups=groups,
            bar_labels=bar_labels,
            item_labels=item_labels,
        )

        return means, errors

    raise ValueError("No standalone input source provided.")


def main() -> None:
    args = parse_args()

    bar_labels = parse_comma_list(args.bar_label)
    item_labels = parse_comma_list(args.item_labels)

    if len(bar_labels) == 0:
        raise ValueError("bar-label must not be empty")
    if len(item_labels) == 0:
        raise ValueError("item-labels must not be empty")

    colors = get_bar_colors(len(item_labels))

    has_groups = bool(args.groups_file)
    has_summary = bool(args.summary_input)
    has_compact = bool(args.compact_input)
    has_standalone = has_groups
    y1_axis_label = args.y1_axis_label
    y2_axis_label = args.y2_axis_label
    y3_axis_label = args.y3_axis_label
    y4_axis_label = args.y4_axis_label

    if has_compact:
        compact_result = read_compact_summary_file(Path(args.compact_input), bar_labels, item_labels)
        throughput_data, throughput_err = compact_result["throughput"]
        p50_data, p50_err = compact_result["p50"]
        p99_data, p99_err = compact_result["p99"]
        p999_data, p999_err = compact_result["p999"]

        panels = [
            {
                "data": throughput_data,
                "errors": throughput_err,
                "bar_labels": bar_labels,
                "y_label": y1_axis_label,
                "title": "",
                "x_label": args.x_axis_label,
                "file_tag": "throughput",
            },
            {
                "data": p50_data,
                "errors": p50_err,
                "bar_labels": bar_labels,
                "y_label": y2_axis_label,
                "title": "",
                "x_label": args.x_axis_label,
                "file_tag": "p50",
            },
            {
                "data": p99_data,
                "errors": p99_err,
                "bar_labels": bar_labels,
                "y_label": y3_axis_label,
                "title": "",
                "x_label": args.x_axis_label,
                "file_tag": "p99",
            },
            {
                "data": p999_data,
                "errors": p999_err,
                "bar_labels": bar_labels,
                "y_label": y4_axis_label,
                "title": "",
                "x_label": args.x_axis_label,
                "file_tag": "p999",
            },
        ]

        plot_panels_separately(
            panels=panels,
            item_labels=item_labels,
            output_dir=Path(args.output),
            colors=colors,
        )
        return

    if has_summary:
        summary_result = parse_summary_file(
            summary_file=Path(args.summary_input),
            group_count=len(bar_labels),
            item_count=len(item_labels),
        )

        p50_data, p50_err = summary_result["p50"]
        p99_data, p99_err = summary_result["p99"]
        p999_data, p999_err = summary_result["p999"]

        standalone_data = None
        standalone_err = None

        panels = []

        if has_standalone:
            standalone_data, standalone_err = load_standalone_data(args, bar_labels, item_labels)
            panels.append({
                "data": standalone_data,
                "errors": standalone_err,
                "bar_labels": bar_labels,
                "y_label": y1_axis_label,
                "title": "",
                "x_label": args.x_axis_label,
                "file_tag": "throughput",
            })

            panels.append({
                "data": p50_data,
                "errors": p50_err,
                "bar_labels": bar_labels,
                "y_label": y2_axis_label,
                "title": "",
                "x_label": args.x_axis_label,
                "file_tag": "p50",
            })
            panels.append({
                "data": p99_data,
                "errors": p99_err,
                "bar_labels": bar_labels,
                "y_label": y3_axis_label,
                "title": "",
                "x_label": args.x_axis_label,
                "file_tag": "p99",
            })
            panels.append({
                "data": p999_data,
                "errors": p999_err,
                "bar_labels": bar_labels,
                "y_label": y4_axis_label,
                "title": "",
                "x_label": args.x_axis_label,
                "file_tag": "p999",
            })

        if args.compact_output:
            if standalone_data is None or standalone_err is None:
                raise ValueError("--compact-output requires throughput source (--groups-file or --stats-input) with --summary-input")
            write_compact_summary_file(
                output_file=Path(args.compact_output),
                bar_labels=bar_labels,
                item_labels=item_labels,
                throughput_data=standalone_data,
                throughput_err=standalone_err,
                p50_data=p50_data,
                p50_err=p50_err,
                p99_data=p99_data,
                p99_err=p99_err,
                p999_data=p999_data,
                p999_err=p999_err,
            )
        elif not has_standalone:
            panels.append({
                "data": p50_data,
                "errors": p50_err,
                "bar_labels": bar_labels,
                "y_label": y2_axis_label,
                "title": "",
                "x_label": args.x_axis_label,
                "file_tag": "p50",
            })
            panels.append({
                "data": p99_data,
                "errors": p99_err,
                "bar_labels": bar_labels,
                "y_label": y3_axis_label,
                "title": "",
                "x_label": args.x_axis_label,
                "file_tag": "p99",
            })
            panels.append({
                "data": p999_data,
                "errors": p999_err,
                "bar_labels": bar_labels,
                "y_label": y4_axis_label,
                "title": "",
                "x_label": args.x_axis_label,
                "file_tag": "p999",
            })

        plot_panels_separately(
            panels=panels,
            item_labels=item_labels,
            output_dir=Path(args.output),
            colors=colors,
        )
        return

    standalone_data, standalone_err = load_standalone_data(args, bar_labels, item_labels)
    panels = [{
        "data": standalone_data,
        "errors": standalone_err,
        "bar_labels": bar_labels,
        "y_label": y1_axis_label,
        "title": "",
        "x_label": args.x_axis_label,
        "file_tag": "throughput",
    }]

    plot_panels_separately(
        panels=panels,
        item_labels=item_labels,
        output_dir=Path(args.output),
        colors=colors,
    )


if __name__ == "__main__":
    main()
