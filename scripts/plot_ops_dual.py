import argparse
import matplotlib.pyplot as plt
import re
from pathlib import Path


def load_series(base_dir: str):
    base = Path(base_dir)
    input_file = base / "run_a" / "ops.txt"
    if not input_file.exists():
        raise FileNotFoundError(f"Missing input file: {input_file}")

    data = []
    with input_file.open() as f:
        for line in f:
            m = re.match(r"(\d+) sec ([\deE.+-]+) operations ([\deE.+-]+) ops/sec", line)
            if m:
                sec = int(m.group(1))
                ops = float(m.group(2)) / 1000.0
                throughput = float(m.group(3)) / 1000.0
                data.append((sec, ops, throughput))
    if not data:
        raise ValueError(f"No data found in {input_file}")
    secs, ops, throughputs = zip(*data)
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


def main():
    parser = argparse.ArgumentParser(description="Plot two throughput series on one chart")
    parser.add_argument("--dir1", required=True, help="Directory containing first load_a/ops.txt")
    parser.add_argument("--dir2", required=True, help="Directory containing second load_a/ops.txt")
    parser.add_argument("--dir3", help="Directory containing second load_a/ops.txt")
    parser.add_argument("--label1", default="Series 1", help="Legend label for first series")
    parser.add_argument("--label2", default="Series 2", help="Legend label for second series")
    parser.add_argument("--output", default="run_ops_throughput_dual.pdf", help="Output image path")
    parser.add_argument("--window", type=int, default=5, help="Averaging window in seconds")
    parser.add_argument("--title", default="YCSB Throughput Over Time", help="Plot title")
    args = parser.parse_args()

    # Apply base font size
    plt.rcParams.update({"font.size": 14})

    secs1, thr1 = load_series(args.dir1)
    secs2, thr2 = load_series(args.dir2)
    if args.dir3:
        secs3, thr3 = load_series(args.dir3)

    # Smooth by averaging in window-sized buckets
    secs1_s, thr1_s = average_window(secs1, thr1, args.window)
    secs2_s, thr2_s = average_window(secs2, thr2, args.window)

    # Find bucket with the largest absolute difference
    series1_map = {t: v for t, v in zip(secs1_s, thr1_s)}
    series2_map = {t: v for t, v in zip(secs2_s, thr2_s)}
    common_times = sorted(set(series1_map.keys()) & set(series2_map.keys()))
    if not common_times:
        raise ValueError("No overlapping time buckets between the two series")
    diffs = [(series1_map[t] - series2_map[t], t) for t in common_times]
    max_diff, max_t = max(diffs, key=lambda x: x[0])
    delta = series2_map[max_t] - series1_map[max_t]
    base = series1_map[max_t]
    pct = (delta / base * 100.0) if base != 0 else float('inf')

    plt.figure(figsize=(16, 4))
    plt.plot(secs1_s, thr1_s, label=args.label1)
    plt.plot(secs2_s, thr2_s, label=args.label2)
    plt.xlabel("Time (sec)")
    plt.ylabel("Throughput (kops/sec)")
    plt.ylim(bottom=0)
    plt.title(args.title)
    plt.legend()
    plt.grid(True)

    # Annotate the point of maximum difference
    
    if pct == float('inf'):
        annotation_text = f"{args.label2} vs {args.label1}: base=0"
    else:
        annotation_text = f"{pct:+.1f}%"
    y_target = series2_map[max_t]
    y_offset = series1_map[max_t]
    y_text = y_offset  # place text below point so arrow points upward
    plt.text(max_t+2, (y_target + y_offset) / 2, annotation_text)
    plt.annotate(
        "",
        xy=(max_t, y_target),
        xytext=(max_t, y_text),
        arrowprops=dict(facecolor='red', shrink=0.05, width=1, headwidth=6),
        ha='center'
    )
    plt.tight_layout()

    plt.savefig(args.output)
    plt.show()
    print(f"Plot saved to {args.output}")


if __name__ == "__main__":
    main()
