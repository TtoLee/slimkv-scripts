import argparse
import numpy as np
import matplotlib.pyplot as plt


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plot space_amplification.txt: first 3 rows as bars, last 2 as lines."
    )
    parser.add_argument(
        "--data", default="space_amplification.txt", help="Path to the 5-row data file"
    )
    parser.add_argument(
        "--bar-labels",
        default="Bar1,Bar2,Bar3",
        help="Comma-separated labels for the three bar series",
    )
    parser.add_argument(
        "--line-labels",
        default="Line1,Line2",
        help="Comma-separated labels for the two line series",
    )
    parser.add_argument(
        "--output",
        default="space_amplification.png",
        help="Output image filename (png/pdf/svg)",
    )
    parser.add_argument(
        "--bar-column-labels",
        default=None,
        help="Comma-separated labels for the bar columns. Overrides header line if provided",
    )
    parser.add_argument(
        "--line-column-labels",
        default=None,
        help="Comma-separated labels for the line columns. Overrides header line if provided",
    )
    parser.add_argument(
        "--x-axis-label",
        default=None,
        help="Label text for the x-axis (e.g., dataset or workload name)",
    )
    parser.add_argument(
        "--font-size",
        type=float,
        default=10.0,
        help="Base font size for labels, ticks, legend, and annotations",
    )
    return parser.parse_args()


def plot(data: np.ndarray, args: argparse.Namespace) -> None:
    if data.shape[0] != 5:
        raise ValueError(f"Expected 5 rows, got {data.shape[0]}")

    # Apply base font size
    plt.rcParams.update({"font.size": args.font_size})

    n_cols = data.shape[1]
    x = np.arange(n_cols)

    bar_labels = [s.strip() for s in args.bar_labels.split(",")]
    if len(bar_labels) != 3:
        raise ValueError("--bar-labels must provide exactly 3 labels")

    line_labels = [s.strip() for s in args.line_labels.split(",")]
    if len(line_labels) != 2:
        raise ValueError("--line-labels must provide exactly 2 labels")

    if hasattr(args, "x_ticks_override") and args.x_ticks_override:
        x_labels = [s.strip() for s in args.x_ticks_override.split(",")]
        if len(x_labels) != n_cols:
            raise ValueError("x tick labels count must match number of columns")
    else:
        x_labels = [str(i + 1) for i in range(n_cols)]

    fig, ax1 = plt.subplots(figsize=(12, 4.5))
    width = 0.8 / 3  # total bar group width 0.8

    ann_font = max(args.font_size - 2, 6)

    bar_colors = ["tab:blue", "tab:orange", "tab:green"]
    line_colors = ["tab:red", "tab:purple"]

    # Bars (rows 0-2)
    for i in range(3):
        offset = (i - 1) * width
        bars = ax1.bar(
            x + offset,
            data[i],
            width,
            label=bar_labels[i],
            color=bar_colors[i % len(bar_colors)],
        )
        for bar in bars:
            height = bar.get_height()
            ax1.text(
                bar.get_x() + bar.get_width() / 2,
                height,
                f"{height:.0f}",
                ha="center",
                va="bottom",
                fontsize=ann_font,
                rotation=0,
            )

    ax1.set_xticks(x)
    ax1.set_xticklabels(x_labels)
    if args.x_axis_label:
        ax1.set_xlabel(args.x_axis_label)
    ax1.set_ylabel(args.bar_column_labels)
    ax1.set_ylim(bottom=0, top=np.max(data[:3]) * 1.1)  # Ensure bars start at zero

    # Lines (rows 3-4) on secondary axis to handle scale differences
    ax2 = ax1.twinx()
    for j in range(2):
        ax2.plot(
            x,
            data[3 + j],
            marker="o",
            label=line_labels[j],
            linestyle="-",
            linewidth=2,
            color=line_colors[j % len(line_colors)],
        )
        for xi, yi in zip(x, data[3 + j]):
            ax2.text(
                xi,
                yi+0.02 * max(data[3 + j]),  # offset above the point
                f"{yi:.2f}",
                ha="center",
                va="bottom",
                fontsize=ann_font,
                color=line_colors[j % len(line_colors)],
            )
    ax2.set_ylim(bottom=0, top=np.max(data[3:]) * 1.1)  # Ensure lines start at zero
    ax2.set_ylabel(args.line_column_labels)


    # Combine legends: bars arranged in 2x2 (one slot empty), lines in rightmost column
    handles1, labels1 = ax1.get_legend_handles_labels()
    handles2, labels2 = ax2.get_legend_handles_labels()

    spacer = plt.Line2D([], [], linestyle="none", marker="", alpha=0)  # blank slot to keep grid shape
    ordered_handles = [handles1[0], handles1[1], handles1[2], spacer, handles2[0], handles2[1]]
    ordered_labels = [labels1[0], labels1[1], labels1[2], " ", labels2[0], labels2[1]]

    ax1.legend(
        ordered_handles,
        ordered_labels,
        loc="upper center",
        bbox_to_anchor=(0.5, -0.15),
        ncol=3,  # 2 rows x 3 cols => bars occupy left 2 cols with one blank, lines on right col
        frameon=False,
        fontsize=args.font_size,
    )

    ax1.grid(True, linestyle="--", alpha=0.4)
    fig.tight_layout(rect=(0, 0.05, 1, 1))
    fig.savefig(args.output)
    print(f"Saved plot to {args.output}")


def main() -> None:
    args = parse_args()
    with open(args.data, "r", encoding="utf-8") as f:
        header = f.readline().strip()
        raw_labels = [] if not header else header.replace(",", " ").split()

    data = np.loadtxt(args.data, skiprows=1)

    # Use header labels for x ticks
    if raw_labels:
        args.x_ticks_override = ",".join(raw_labels)

    plot(data, args)


if __name__ == "__main__":
    main()
