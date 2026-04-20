import argparse
import matplotlib.pyplot as plt
import re
from pathlib import Path


def load_series(base_dir: str):
    base = Path(base_dir)
    input_file = base / "ops.txt"
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
        bucket = (s // window) * window
        buckets[bucket] = buckets.get(bucket, 0.0) + v
        counts[bucket] = counts.get(bucket, 0) + 1
    bucket_times = sorted(buckets.keys())
    avg_values = [buckets[b] / counts[b] for b in bucket_times]
    return bucket_times, avg_values


def main():
    parser = argparse.ArgumentParser(description="Plot throughput with optional time-window averaging")
    parser.add_argument("--dir", required=True, help="Base directory containing run_a/ops.txt")
    parser.add_argument("--window", type=int, default=5, help="Averaging window in seconds")
    parser.add_argument("--output", default="run_ops_throughput.png", help="Output image path")
    args = parser.parse_args()

    secs, throughputs = load_series(args.dir)
    secs_s, thr_s = average_window(secs, throughputs, args.window)

    plt.figure(figsize=(10, 6))
    plt.plot(secs_s, thr_s, label="Throughput (kops/sec)")
    plt.xlabel("Time (sec)")
    plt.ylabel("Throughput (kops/sec)")
    plt.ylim(bottom=0)
    plt.title(f"YCSB Throughput Over Time ({args.window}s avg)")
    plt.legend()
    plt.grid(True)
    plt.tight_layout()

    plt.savefig(args.output)
    plt.show()
    print(f"Plot saved to {args.output}")


if __name__ == "__main__":
    main()