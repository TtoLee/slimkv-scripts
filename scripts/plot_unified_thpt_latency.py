import argparse
import re
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


def extract_mean(cell: str) -> float:
    text = str(cell).strip()
    if text == "" or text == "-" or text.lower() == "nan":
        return np.nan
    match = re.search(r"-?\d+(?:\.\d+)?", text)
    return float(match.group(0)) if match else np.nan


def read_tsv_lenient(tsv_path: Path) -> pd.DataFrame:
    with tsv_path.open("r", encoding="utf-8") as f:
        lines = [line.rstrip("\n") for line in f]

    # Skip leading blank lines and detect header.
    first_non_empty = next((i for i, line in enumerate(lines) if line.strip()), None)
    if first_non_empty is None:
        raise ValueError(f"Empty TSV file: {tsv_path}")

    header = [h.strip() for h in lines[first_non_empty].split("\t")]
    ncols = len(header)

    rows = []
    for raw in lines[first_non_empty + 1 :]:
        if not raw.strip():
            continue

        parts = raw.split("\t")
        if len(parts) < ncols:
            parts = parts + [""] * (ncols - len(parts))
        elif len(parts) > ncols:
            # Some source files contain accidental extra tabs.
            # Keep the first columns stable and merge overflow into the last column.
            merged_last = " ".join(p for p in parts[ncols - 1 :] if p.strip())
            parts = parts[: ncols - 1] + [merged_last]

        rows.append(parts)

    return pd.DataFrame(rows, columns=header)


def load_unified_tsv(tsv_path: Path):
    df = read_tsv_lenient(tsv_path)
    df = df.astype(str)
    df.columns = [c.strip() for c in df.columns]

    required_cols = {"section", "workload", "backup_method"}
    missing = required_cols.difference(df.columns)
    if missing:
        raise ValueError(f"Missing required columns: {sorted(missing)}")

    throughput_candidates = [
        "throughput_kops",
        "avg_us",
        "stddev_us",
        "min_us",
        "max_us",
        "p50_us",
        "p99_us",
        "p999_us",
    ]

    thpt_rows = df[df["section"].str.strip() == "throughput_kops"].copy()

    def pick_throughput(row: pd.Series) -> float:
        for col in throughput_candidates:
            if col in row.index:
                value = extract_mean(row[col])
                if not np.isnan(value):
                    return value

        # Fallback for malformed rows: pick the last parseable numeric token.
        parsed = [extract_mean(v) for v in row.tolist()]
        parsed = [v for v in parsed if not np.isnan(v)]
        return parsed[-1] if parsed else np.nan

    thpt_rows["throughput_mean_kops"] = thpt_rows.apply(pick_throughput, axis=1)
    thpt = (
        thpt_rows.groupby(["workload", "backup_method"], as_index=False)["throughput_mean_kops"]
        .mean()
        .dropna()
    )

    lat_rows = df[df["section"].str.strip() == "latency"].copy()
    for q in ["p50_us", "p99_us", "p999_us"]:
        if q not in lat_rows.columns:
            raise ValueError(f"Missing latency quantile column: {q}")
        lat_rows[f"{q}_mean"] = lat_rows[q].map(extract_mean)

    # Prefer end-to-end request metric when present.
    if "metric" in lat_rows.columns:
        ycsb_req = lat_rows[lat_rows["metric"].str.contains("YCSB REQUESTS", na=False)]
        if not ycsb_req.empty:
            lat_rows = ycsb_req

    lat = (
        lat_rows.groupby(["workload", "backup_method"], as_index=False)[
            ["p50_us_mean", "p99_us_mean", "p999_us_mean"]
        ]
        .mean()
        .dropna(how="all")
    )

    return thpt, lat


def workload_order(values):
    preferred = ["load", "a", "b", "c", "d"]
    existing = list(values)
    ordered = [w for w in preferred if w in existing]
    ordered += sorted([w for w in existing if w not in preferred])
    return ordered


def plot_throughput(thpt: pd.DataFrame, out_path: Path):
    pivot = thpt.pivot(index="workload", columns="backup_method", values="throughput_mean_kops")
    pivot = pivot.reindex(workload_order(pivot.index))

    ax = pivot.plot(kind="bar", figsize=(10, 5))
    ax.set_xlabel("workload")
    ax.set_ylabel("throughput (KOPS)")
    ax.set_title("Throughput by Workload")
    ax.grid(axis="y", alpha=0.3)
    plt.tight_layout()
    plt.savefig(out_path, dpi=200)
    plt.close()


def plot_latency_quantiles(lat: pd.DataFrame, out_path: Path):
    workloads = workload_order(lat["workload"].dropna().unique())
    methods = sorted(lat["backup_method"].dropna().unique())
    quantiles = [
        ("p50_us_mean", "p50 (us)"),
        ("p99_us_mean", "p99 (us)"),
        ("p999_us_mean", "p999 (us)"),
    ]

    fig, axes = plt.subplots(1, 3, figsize=(15, 4.5), sharex=True)

    for ax, (col, title) in zip(axes, quantiles):
        for method in methods:
            sub = lat[lat["backup_method"] == method].set_index("workload").reindex(workloads)
            ax.plot(workloads, sub[col], marker="o", linewidth=2, label=method)
        ax.set_title(title)
        ax.set_xlabel("workload")
        ax.grid(alpha=0.3)

    axes[0].set_ylabel("latency (us)")
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=max(1, len(labels)), frameon=False)
    plt.tight_layout(rect=(0.0, 0.0, 1.0, 0.9))
    plt.savefig(out_path, dpi=200)
    plt.close()


def main():
    parser = argparse.ArgumentParser(description="Plot throughput and latency quantiles from unified TSV")
    parser.add_argument("tsv", type=Path, help="Path to throughput_latency_unified.tsv")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=None,
        help="Output directory for figures; default is TSV parent directory",
    )
    args = parser.parse_args()

    out_dir = args.out_dir if args.out_dir else args.tsv.parent
    out_dir.mkdir(parents=True, exist_ok=True)

    thpt, lat = load_unified_tsv(args.tsv)

    thpt_fig = out_dir / "throughput_by_workload.png"
    lat_fig = out_dir / "latency_quantiles_by_workload.png"

    plot_throughput(thpt, thpt_fig)
    plot_latency_quantiles(lat, lat_fig)

    print(f"Saved: {thpt_fig}")
    print(f"Saved: {lat_fig}")


if __name__ == "__main__":
    main()
