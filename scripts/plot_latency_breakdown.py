#!/usr/bin/env python3

import argparse
import csv
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, TextIO, Tuple

import matplotlib.pyplot as plt


@dataclass
class MetricRow:
    metric: str
    host_count: int
    total_count: int
    avg_ns: float
    stddev_ns: float
    min_ns: float
    max_ns: float
    p99_ns: float
    p999_ns: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Visualize merged latency TSV produced by latency_breakdown.sh. "
            "Input can be a file or stdin."
        )
    )
    parser.add_argument(
        "-i",
        "--input",
        default="-",
        help="Input TSV path. Use '-' to read from stdin (default).",
    )
    parser.add_argument(
        "-o",
        "--output-prefix",
        default="latency_breakdown",
        help="Prefix for output files (default: latency_breakdown).",
    )
    parser.add_argument(
        "--sort-by",
        choices=["input", "metric", "avg", "total_count", "stddev", "max"],
        default="input",
        help="Sort order for table and charts (default: input, i.e., preserve input order).",
    )
    parser.add_argument(
        "--descending",
        action="store_true",
        help="Sort in descending order.",
    )
    parser.add_argument(
        "--top-n",
        type=int,
        default=0,
        help="Only display top N metrics after sorting. 0 means all.",
    )
    return parser.parse_args()


def open_input(path: str) -> TextIO:
    if path == "-":
        return sys.stdin
    return Path(path).open("r", encoding="utf-8")


def load_rows(stream: TextIO) -> List[MetricRow]:
    reader = csv.DictReader(stream, delimiter="\t")
    required = {
        "metric",
        "host_count",
        "total_count",
        "avg_ns",
        "stddev_ns",
        "min_ns",
        "max_ns",
    }
    if reader.fieldnames is None:
        raise ValueError("Input is empty; expected TSV header")

    missing = required.difference(reader.fieldnames)
    if missing:
        raise ValueError(f"Missing required columns: {', '.join(sorted(missing))}")

    rows: List[MetricRow] = []
    for row in reader:
        if not row.get("metric"):
            continue
        rows.append(
            MetricRow(
                metric=row["metric"],
                host_count=int(float(row["host_count"])),
                total_count=int(float(row["total_count"])),
                avg_ns=float(row["avg_ns"]),
                stddev_ns=float(row["stddev_ns"]),
                min_ns=float(row["min_ns"]),
                max_ns=float(row["max_ns"]),
                p99_ns=float(row.get("p99_ns") or 0.0),
                p999_ns=float(row.get("p999_ns") or 0.0),
            )
        )

    if not rows:
        raise ValueError("No data rows found in input")
    return rows


def sort_rows(rows: List[MetricRow], sort_by: str, descending: bool) -> List[MetricRow]:
    if sort_by == "input":
        return list(reversed(rows)) if descending else list(rows)
    elif sort_by == "metric":
        key_fn = lambda r: r.metric
    elif sort_by == "avg":
        key_fn = lambda r: r.avg_ns
    elif sort_by == "total_count":
        key_fn = lambda r: r.total_count
    elif sort_by == "stddev":
        key_fn = lambda r: r.stddev_ns
    else:
        key_fn = lambda r: r.max_ns
    return sorted(rows, key=key_fn, reverse=descending)


def split_metric_scope(metric: str) -> Tuple[str, str]:
    if ":" not in metric:
        return metric, "total"
    base, scope = metric.rsplit(":", 1)
    return base, scope


def print_pretty_table(rows: List[MetricRow]) -> None:
    header = [
        "metric",
        "hosts",
        "total_count",
        "avg_ns",
        "stddev_ns",
        "min_ns",
        "max_ns",
        "p99_ns",
        "p999_ns",
    ]
    matrix = [
        [
            r.metric,
            str(r.host_count),
            f"{r.total_count}",
            f"{r.avg_ns:.2f}",
            f"{r.stddev_ns:.2f}",
            f"{r.min_ns:.0f}",
            f"{r.max_ns:.0f}",
            f"{r.p99_ns:.2f}",
            f"{r.p999_ns:.2f}",
        ]
        for r in rows
    ]

    widths = [len(c) for c in header]
    for row in matrix:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def fmt_line(cells: List[str]) -> str:
        return "  ".join(cell.ljust(widths[i]) for i, cell in enumerate(cells))

    print(fmt_line(header))
    print(fmt_line(["-" * w for w in widths]))
    for row in matrix:
        print(fmt_line(row))


def save_table_tsv(rows: List[MetricRow], path: Path) -> None:
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, delimiter="\t")
        writer.writerow(
            [
                "metric",
                "host_count",
                "total_count",
                "avg_ns",
                "stddev_ns",
                "min_ns",
                "max_ns",
                "p99_ns",
                "p999_ns",
            ]
        )
        for r in rows:
            writer.writerow(
                [
                    r.metric,
                    r.host_count,
                    r.total_count,
                    f"{r.avg_ns:.2f}",
                    f"{r.stddev_ns:.2f}",
                    f"{r.min_ns:.0f}",
                    f"{r.max_ns:.0f}",
                    f"{r.p99_ns:.2f}",
                    f"{r.p999_ns:.2f}",
                ]
            )


def _value_label_x(max_value: float) -> float:
    return max_value * 0.01 if max_value > 0 else 1.0


def plot_avg_std(rows: List[MetricRow], out_path: Path, title: str) -> None:
    labels = [split_metric_scope(r.metric)[0] for r in rows]
    avg = [r.avg_ns for r in rows]
    std = [r.stddev_ns for r in rows]

    fig_h = max(4.5, 0.6 * len(rows) + 1.5)
    fig, ax = plt.subplots(figsize=(12.5, fig_h))

    y = list(range(len(rows)))
    ax.barh(y, avg, xerr=std, color="#3A86FF", alpha=0.85, ecolor="#1D3557", capsize=3)
    ax.set_yticks(y)
    ax.set_yticklabels(labels)
    ax.invert_yaxis()
    ax.set_xlabel("Latency (ns)")
    ax.set_title(title)
    ax.grid(axis="x", linestyle="--", alpha=0.25)

    max_extent = max((a + s) for a, s in zip(avg, std)) if rows else 0.0
    x_pad = _value_label_x(max_extent)
    ax.set_xlim(0, max_extent * 1.35 if max_extent > 0 else 1)

    for yi, a, s in zip(y, avg, std):
        ax.text(
            a + s + x_pad,
            yi,
            f"avg={a:.2f} ns\nstd={s:.2f} ns",
            va="center",
            ha="left",
            fontsize=9,
        )

    fig.tight_layout()
    fig.savefig(out_path, dpi=180)
    plt.close(fig)


def plot_min_avg_max(rows: List[MetricRow], out_path: Path, title: str) -> None:
    labels = [split_metric_scope(r.metric)[0] for r in rows]
    fig_h = max(4.5, 0.75 * len(rows) + 1.5)
    fig, ax = plt.subplots(figsize=(13.5, fig_h))

    y = list(range(len(rows)))
    mins = [r.min_ns for r in rows]
    avgs = [r.avg_ns for r in rows]
    maxs = [r.max_ns for r in rows]
    max_value = max(maxs) if rows else 0.0
    x_pad = _value_label_x(max_value)

    for yi, r in zip(y, rows):
        ax.hlines(yi, r.min_ns, r.max_ns, color="#6C757D", linewidth=2)
        ax.scatter(r.min_ns, yi, color="#2A9D8F", s=36, marker="o", zorder=3)
        ax.scatter(r.avg_ns, yi, color="#3A86FF", s=42, marker="D", zorder=3)
        ax.scatter(r.max_ns, yi, color="#E76F51", s=36, marker="o", zorder=3)
        ax.text(
            r.max_ns + x_pad,
            yi,
            f"min={r.min_ns:.0f} ns  avg={r.avg_ns:.2f} ns  max={r.max_ns:.0f} ns",
            va="center",
            ha="left",
            fontsize=9,
        )

    ax.set_yticks(y)
    ax.set_yticklabels(labels)
    ax.invert_yaxis()
    ax.set_xlabel("Latency (ns)")
    ax.set_title(title)
    ax.grid(axis="x", linestyle="--", alpha=0.25)
    ax.set_xlim(0, max_value * 1.45 if max_value > 0 else 1)

    fig.tight_layout()
    fig.savefig(out_path, dpi=180)
    plt.close(fig)


def plot_percentile(rows: List[MetricRow], out_path: Path, title: str, percentile: str) -> None:
    labels = [split_metric_scope(r.metric)[0] for r in rows]
    if percentile == "p99":
        values = [r.p99_ns for r in rows]
    else:
        values = [r.p999_ns for r in rows]

    fig_h = max(4.5, 0.6 * len(rows) + 1.5)
    fig, ax = plt.subplots(figsize=(12.5, fig_h))

    y = list(range(len(rows)))
    ax.barh(y, values, color="#FF6B6B", alpha=0.88)
    ax.set_yticks(y)
    ax.set_yticklabels(labels)
    ax.invert_yaxis()
    ax.set_xlabel("Latency (ns)")
    ax.set_title(title)
    ax.grid(axis="x", linestyle="--", alpha=0.25)

    max_value = max(values) if rows else 0.0
    x_pad = _value_label_x(max_value)
    ax.set_xlim(0, max_value * 1.35 if max_value > 0 else 1)

    for yi, v in zip(y, values):
        ax.text(v + x_pad, yi, f"{percentile}={v:.2f} ns", va="center", ha="left", fontsize=9)

    fig.tight_layout()
    fig.savefig(out_path, dpi=180)
    plt.close(fig)


def main() -> None:
    args = parse_args()

    with open_input(args.input) as stream:
        rows = load_rows(stream)

    rows = sort_rows(rows, args.sort_by, args.descending)
    if args.top_n > 0:
        rows = rows[: args.top_n]

    print_pretty_table(rows)

    prefix = Path(args.output_prefix)
    table_path = Path(f"{prefix}.sorted.tsv")
    total_rows = [r for r in rows if split_metric_scope(r.metric)[1] == "total"]
    last_rows = [r for r in rows if split_metric_scope(r.metric)[1].startswith("last")]

    total_avg_std_path = Path(f"{prefix}.total.avg_std.png")
    last_avg_std_path = Path(f"{prefix}.last.avg_std.png")
    total_min_avg_max_path = Path(f"{prefix}.total.min_avg_max.png")
    last_min_avg_max_path = Path(f"{prefix}.last.min_avg_max.png")
    last_p99_path = Path(f"{prefix}.last.p99.png")
    last_p999_path = Path(f"{prefix}.last.p999.png")

    save_table_tsv(rows, table_path)
    if total_rows:
        plot_avg_std(total_rows, total_avg_std_path, "Total Scope: Average Latency with Standard Deviation")
        plot_min_avg_max(total_rows, total_min_avg_max_path, "Total Scope: Min / Avg / Max Latency")
    if last_rows:
        plot_avg_std(last_rows, last_avg_std_path, "Last Scope: Average Latency with Standard Deviation")
        plot_min_avg_max(last_rows, last_min_avg_max_path, "Last Scope: Min / Avg / Max Latency")
        p99_rows = [r for r in last_rows if r.p99_ns > 0]
        p999_rows = [r for r in last_rows if r.p999_ns > 0]
        if p99_rows:
            plot_percentile(p99_rows, last_p99_path, "Last Scope: P99 Latency", "p99")
        if p999_rows:
            plot_percentile(p999_rows, last_p999_path, "Last Scope: P999 Latency", "p999")

    print(f"\nSaved sorted table: {table_path}")
    if total_rows:
        print(f"Saved chart: {total_avg_std_path}")
        print(f"Saved chart: {total_min_avg_max_path}")
    if last_rows:
        print(f"Saved chart: {last_avg_std_path}")
        print(f"Saved chart: {last_min_avg_max_path}")
        p99_rows = [r for r in last_rows if r.p99_ns > 0]
        p999_rows = [r for r in last_rows if r.p999_ns > 0]
        if p99_rows:
            print(f"Saved chart: {last_p99_path}")
        if p999_rows:
            print(f"Saved chart: {last_p999_path}")


if __name__ == "__main__":
    main()
