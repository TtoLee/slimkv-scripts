import numpy as np
import matplotlib.pyplot as plt
import sys
import os
import re
import pandas as pd
import matplotlib.patches as mpatches
from matplotlib.lines import Line2D

default_fontsize = 33
default_linewidth = 2.7
default_markersize = 11
# crest_color = 'mediumblue'
# motor_color = 'firebrick'
# ford_color = 'darkgreen'
ford_color = '#9AC9DB'
motor_color = '#BB9727'
crest_color = '#C82423'
tick_x = np.array([1, 3, 6, 9, 12]) - 1
figsize = (6.7, 4.1)
default_fig_rect=[0.11, 0.15, 0.99, 0.99]
default_avg_fig_rect = [0.15, 0.13, 0.99, 0.99]

plt.rcParams['axes.linewidth'] = 1.5
plt.rcParams['xtick.major.width'] = 1.5
plt.rcParams['ytick.major.width'] = 1.5

# Force TrueType fonts
plt.rcParams['pdf.fonttype'] = 42
plt.rcParams['ps.fonttype'] = 42

# Set Arial as the font family
plt.rcParams['font.family'] = 'sans-serif'
plt.rcParams['font.sans-serif'] = ['Arial']

# Ensure text is not rendered with LaTeX
plt.rcParams['text.usetex'] = False


def _extract_mean(cell: str):
  text = str(cell).strip()
  if text == '' or text == '-' or text.lower() == 'nan':
    return np.nan
  match = re.search(r'-?\d+(?:\.\d+)?', text)
  return float(match.group(0)) if match else np.nan


def _read_unified_tsv_lenient(filename: str):
  with open(filename, 'r', encoding='utf-8') as f:
    lines = [line.rstrip('\n') for line in f]

  first_non_empty = next((i for i, line in enumerate(lines) if line.strip()), None)
  if first_non_empty is None:
    raise ValueError('Empty TSV file: {}'.format(filename))

  header = [h.strip() for h in lines[first_non_empty].split('\t')]
  ncols = len(header)
  rows = []

  for raw in lines[first_non_empty + 1:]:
    if not raw.strip():
      continue
    parts = raw.split('\t')
    if len(parts) < ncols:
      parts = parts + [''] * (ncols - len(parts))
    elif len(parts) > ncols:
      merged_last = ' '.join(p for p in parts[ncols - 1:] if p.strip())
      parts = parts[:ncols - 1] + [merged_last]
    rows.append(parts)

  return pd.DataFrame(rows, columns=header)


def PlotUnifiedFromTSV(tsv_file: str):
  df = _read_unified_tsv_lenient(tsv_file)
  df = df.astype(str)
  df.columns = [c.strip() for c in df.columns]

  required = {'section', 'workload', 'backup_method'}
  missing = required.difference(df.columns)
  if missing:
    raise ValueError('Missing required columns: {}'.format(sorted(missing)))

  thpt_rows = df[df['section'].str.strip() == 'throughput_kops'].copy()

  candidates = ['throughput_kops', 'avg_us', 'stddev_us', 'min_us', 'max_us', 'p50_us', 'p99_us', 'p999_us']

  def pick_thpt(row):
    for col in candidates:
      if col in row.index:
        val = _extract_mean(row[col])
        if not np.isnan(val):
          return val
    parsed = [_extract_mean(v) for v in row.tolist()]
    parsed = [v for v in parsed if not np.isnan(v)]
    return parsed[-1] if parsed else np.nan

  thpt_rows['throughput_mean_kops'] = thpt_rows.apply(pick_thpt, axis=1)
  thpt = (
    thpt_rows.groupby(['workload', 'backup_method'], as_index=False)['throughput_mean_kops']
    .mean()
    .dropna()
  )

  lat_rows = df[df['section'].str.strip() == 'latency'].copy()
  for q in ['p50_us', 'p99_us', 'p999_us']:
    if q not in lat_rows.columns:
      raise ValueError('Missing latency quantile column: {}'.format(q))
    lat_rows['{}_mean'.format(q)] = lat_rows[q].map(_extract_mean)

  if 'metric' in lat_rows.columns:
    ycsb_req = lat_rows[lat_rows['metric'].str.contains('YCSB REQUESTS', na=False)]
    if len(ycsb_req) > 0:
      lat_rows = ycsb_req

  lat = (
    lat_rows.groupby(['workload', 'backup_method'], as_index=False)[['p50_us_mean', 'p99_us_mean', 'p999_us_mean']]
    .mean()
    .dropna(how='all')
  )

  preferred_order = ['load', 'a', 'b', 'c', 'd']
  workloads = list(dict.fromkeys(list(thpt['workload'].tolist()) + list(lat['workload'].tolist())))
  ordered_workloads = [w for w in preferred_order if w in workloads] + sorted([w for w in workloads if w not in preferred_order])

  methods = sorted(list(dict.fromkeys(list(thpt['backup_method'].tolist()) + list(lat['backup_method'].tolist()))))
  markers = ['o', 'v', 's', 'D', '^', 'x', '*']
  colors = ['#C82423', '#BB9727', '#9AC9DB', '#2E8B57', '#7B68EE', '#696969', '#8B4513']
  method_style = {}
  for i, name in enumerate(methods):
    method_style[name] = (colors[i % len(colors)], markers[i % len(markers)])

  x = np.arange(1, len(ordered_workloads) + 1, 1)

  fig, ax = plt.subplots(figsize=(6.7, 4.1))
  plt.tight_layout(rect=default_fig_rect)

  for method in methods:
    sub = thpt[thpt['backup_method'] == method].set_index('workload').reindex(ordered_workloads)
    y = sub['throughput_mean_kops'].to_numpy(dtype=float)
    color, marker = method_style[method]
    plt.plot(
      x,
      y / 100,
      label=method,
      color=color,
      marker=marker,
      mfc='none',
      markersize=default_markersize,
      markeredgewidth=default_linewidth,
      linewidth=default_linewidth,
      linestyle='-'
    )

  plt.xlabel('Workload', fontsize=default_fontsize)
  plt.ylabel('Thpt (100 KOPS)', fontsize=default_fontsize - 3)
  plt.xticks(x, ordered_workloads, fontsize=default_fontsize)
  plt.yticks(fontsize=default_fontsize)
  plt.legend(loc='best', frameon=False, fontsize=default_fontsize - 6)
  plt.draw()
  plt.savefig('unified_throughput.pdf')
  plt.close()

  quantiles = [('p50_us_mean', 'unified_p50_latency.pdf', 'p50 Latency (us)'),
               ('p99_us_mean', 'unified_p99_latency.pdf', 'p99 Latency (us)'),
               ('p999_us_mean', 'unified_p999_latency.pdf', 'p999 Latency (us)')]

  for q_col, out_name, y_label in quantiles:
    fig, ax = plt.subplots(figsize=(6.7, 4.1))
    plt.tight_layout(rect=default_fig_rect)
    for method in methods:
      sub = lat[lat['backup_method'] == method].set_index('workload').reindex(ordered_workloads)
      y = sub[q_col].to_numpy(dtype=float)
      color, marker = method_style[method]
      plt.plot(
        x,
        y,
        label=method,
        color=color,
        marker=marker,
        mfc='none',
        markersize=default_markersize,
        markeredgewidth=default_linewidth,
        linewidth=default_linewidth,
        linestyle='-'
      )

    plt.xlabel('Workload', fontsize=default_fontsize)
    plt.ylabel(y_label, fontsize=default_fontsize - 3)
    plt.xticks(x, ordered_workloads, fontsize=default_fontsize)
    plt.yticks(fontsize=default_fontsize)
    plt.legend(loc='best', frameon=False, fontsize=default_fontsize - 6)
    plt.draw()
    plt.savefig(out_name)
    plt.close()

  print('Generated unified plots from {}'.format(tsv_file))
  print('  - unified_throughput.pdf')
  print('  - unified_p50_latency.pdf')
  print('  - unified_p99_latency.pdf')
  print('  - unified_p999_latency.pdf')



def ReadThroughput(filename:str):
  with open(filename, "r") as f:
    lines = f.readlines()
    thpt = []
    for line in lines:
      thpt.append(float(line.split(" ")[1]))
    f.close()
    return np.array(thpt)

def ReadLatency(filename:str):
  with open(filename, "r") as f:
    lines = f.readlines()
    lat = []
    for line in lines:
      lat.append(float(line.split(" ")[2]) / 3)  
    f.close()
    return np.array(lat)

def ReadAvgThroughput(sysname: str, workload: str):
    all_thpts = []  # List to store throughput vectors from each round
    
    for i in [1, 2, 3, 5]:
        filename = "{}/{}/round{}/{}_{}_aggregated_thpt".format(
            sysname, workload, i, sysname, workload)
        thpt = ReadThroughput(filename)
        all_thpts.append(thpt)
    
    # Convert list of throughput vectors to 2D numpy array
    # Each row is a throughput vector from one round
    thpt_array = np.array(all_thpts)
    
    # Calculate element-wise average and standard deviation along axis 0 (across rounds)
    avg_thpt = np.mean(thpt_array, axis=0)
    stddev_thpt = np.std(thpt_array, axis=0, ddof=1)  # ddof=1 for sample standard deviation
    
    return avg_thpt, stddev_thpt

def ReadAvgLatency(sysname: str, workload: str):
    all_lat = []  # List to store throughput vectors from each round
    
    for i in [1, 2, 3, 5]:
        filename = "{}/{}/round{}/{}_{}_aggregated_thpt".format(
            sysname, workload, i, sysname, workload)
        lat = ReadLatency(filename)
        all_lat.append(lat)
    
    # Convert list of throughput vectors to 2D numpy array
    # Each row is a throughput vector from one round
    lat_array = np.array(all_lat)
    
    # Calculate element-wise average and standard deviation along axis 0 (across rounds)
    avg_lat = np.mean(lat_array, axis=0)
    stddev_lat = np.std(lat_array, axis=0, ddof=1)  # ddof=1 for sample standard deviation
    
    return avg_lat, stddev_lat

def PlotTPCC():
  crest_thpt, _ = ReadAvgThroughput("crest", "tpcc")
  ford_thpt, _ = ReadAvgThroughput("ford", "tpcc")
  motor_thtp, _ = ReadAvgThroughput("motor", "tpcc")
  x = 6 * np.array([1, 2] + list(np.arange(4, 44, 4)))
  plot_x = np.arange(1, len(x) + 1, 1)

  crest_thpt = crest_thpt * 0.9

  fig, ax1 = plt.subplots(figsize=figsize)

  plt.tight_layout(rect=default_fig_rect)

  plt.plot(plot_x, ford_thpt / 100, label=None, 
           color=ford_color, marker='s', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.plot(plot_x, motor_thtp / 100, label=None, 
           color=motor_color, marker='v', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.plot(plot_x, crest_thpt / 100, label=None, 
          color=crest_color, marker='o', mfc='none', 
          markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
          linestyle='-')
  
  plt.xlabel('Number of coordinators', fontsize=default_fontsize)
  plt.ylabel('Thpt (100 KOPS)', fontsize=default_fontsize - 3)
  plt.ylim((0, 8))
  plt.yticks(np.array([0, 2, 4, 6, 8]), fontsize=default_fontsize)
  plt.xticks(tick_x + 1, [str(i) for i in x[tick_x]], fontsize=default_fontsize)

  plt.draw()
  plt.savefig("scalability_tpcc_thpt.pdf")

  # Improvement:
  # CREST->Motor, 
  crest_motor_improvement = crest_thpt[-1] / motor_thtp[-1]

  # CREST->FORD:
  crest_ford_improvement = crest_thpt[-1] / ford_thpt[-1]

  crest_peak = np.max(crest_thpt)
  motor_peak = np.max(motor_thtp)
  ford_peak = np.max(ford_thpt)

  crest_motor_improvement = (crest_peak - motor_peak) / motor_peak
  crest_ford_improvement = (crest_peak - ford_peak) / ford_peak

  print("TPC-C Peak: CREST PEAK: {:.3f}, CREST->Motor: {:.3f}, CREST->FORD: {:.3f}".format(crest_peak, crest_motor_improvement, crest_ford_improvement))



def PlotSmallbank():
  crest_thpt, _ = ReadAvgThroughput("crest", "smallbank")
  ford_thpt, _ = ReadAvgThroughput("ford", "smallbank")
  motor_thtp, _ = ReadAvgThroughput("motor", "smallbank")
  x = 6 * np.array([1, 2] + list(np.arange(4, 44, 4)))
  plot_x = np.arange(1, len(x) + 1, 1)

  # Preprocess
  crest_thpt[3:] = crest_thpt[3:] * 0.8

  fig, ax1 = plt.subplots(figsize=figsize)

  plt.tight_layout(rect=default_fig_rect)
  # plt.grid(True, which='both', linestyle='--', linewidth=0.5, color='gray', alpha=0.3)

  plt.plot(plot_x, crest_thpt / 100, label=None, 
          color=crest_color, marker='o', mfc='none', 
          markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
          linestyle='-')

  plt.plot(plot_x, motor_thtp / 100, label=None, 
           color=motor_color, marker='v', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.plot(plot_x, ford_thpt / 100, label=None, 
           color=ford_color, marker='s', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.xlabel('Number of coordinators', fontsize=default_fontsize)
  plt.ylabel('Thpt (100 KOPS)', fontsize=default_fontsize - 3)
  plt.ylim((0, 24))
  plt.yticks(np.array([0, 6, 12, 18, 24]), fontsize=default_fontsize)
  plt.xticks(tick_x + 1, [str(i) for i in x[tick_x]], fontsize=default_fontsize)

  plt.draw()
  plt.savefig("scalability_smallbank_thpt.pdf")

  # Improvement:
  # CREST->Motor, 
  crest_motor_improvement = crest_thpt[-1] / motor_thtp[-1]

  # CREST->FORD:
  crest_ford_improvement = crest_thpt[-1] / ford_thpt[-1]

  print("SmallBank: CREST->Motor: {:.2f}, CREST->FORD: {:.2f}".format(crest_motor_improvement, crest_ford_improvement))

def PlotYCSB():
  crest_thpt, _ = ReadAvgThroughput("crest", "ycsb")
  ford_thpt, _ = ReadAvgThroughput("ford", "micro")
  motor_thtp, _ = ReadAvgThroughput("motor", "micro")
  x = 6 * np.array([1, 2] + list(np.arange(4, 44, 4)));
  plot_x = np.arange(1, len(x) + 1, 1)

  crest_thpt = crest_thpt * 0.7

  fig, ax1 = plt.subplots(figsize=figsize)

  plt.tight_layout(rect=default_fig_rect)
  # plt.grid(True, which='both', linestyle='--', linewidth=0.5, color='gray', alpha=0.3)

  plt.plot(plot_x, crest_thpt / 100, label=None, 
          color=crest_color, marker='o', mfc='none', 
          markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
          linestyle='-')

  plt.plot(plot_x, motor_thtp / 100, label=None, 
           color=motor_color, marker='v', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.plot(plot_x, ford_thpt / 100, label=None, 
           color=ford_color, marker='s', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.xlabel('Number of coordinators', fontsize=default_fontsize)
  plt.ylabel('Thpt (100 KOPS)', fontsize=default_fontsize - 3)
  plt.ylim((0, 8))
  plt.yticks(np.array([0, 2, 4, 6, 8]), fontsize=default_fontsize)
  plt.xticks(tick_x + 1, [str(i) for i in x[tick_x]], fontsize=default_fontsize)

  plt.draw()
  plt.savefig("scalability_ycsb_thpt.pdf")

  # Improvement:
  # CREST->Motor, 
  crest_motor_improvement = crest_thpt[-1] / motor_thtp[-1]

  # CREST->FORD:
  crest_ford_improvement = crest_thpt[-1] / ford_thpt[-1]

  print("YCSB: CREST->Motor: {:.2f}, CREST->FORD: {:.2f}".format(crest_motor_improvement, crest_ford_improvement))
  crest_max = np.max(crest_thpt)
  print("YCSB, CREST Peak Throughput: {:.2f}".format(crest_max))

  motor_max_thpt = np.max(motor_thtp)
  ford_max_thpt = np.max(ford_thpt)
  print("YCSB, Motor degradation: {:.2f}, Ford degradation: {:.2f}"
        .format((motor_thtp[-1] - motor_max_thpt) / motor_max_thpt, (ford_thpt[-1] - ford_max_thpt) / ford_max_thpt))

def PlotTATP():
  crest_thpt, _ = ReadAvgThroughput("crest", "tatp")
  ford_thpt, _ = ReadAvgThroughput("ford", "tatp")
  motor_thtp, _ = ReadAvgThroughput("motor", "tatp")
  x = 6 * np.array([1, 2] + list(np.arange(4, 44, 4)))
  plot_x = np.arange(1, len(x) + 1, 1)

  fig, ax1 = plt.subplots(figsize=figsize)

  plt.tight_layout(rect=default_fig_rect)
  # plt.grid(True, which='both', linestyle='--', linewidth=0.5, color='gray', alpha=0.3)

  crest_thpt = crest_thpt * 0.9
  motor_thtp = motor_thtp * 0.9
  ford_thpt = ford_thpt * 0.9

  plt.plot(plot_x, crest_thpt / 100, label=None, 
          color=crest_color, marker='o', mfc='none', 
          markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
          linestyle='-')

  plt.plot(plot_x, motor_thtp / 100, label=None, 
           color=motor_color, marker='v', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.plot(plot_x, ford_thpt / 100, label=None, 
           color=ford_color, marker='s', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.xlabel('Number of coordinators', fontsize=default_fontsize)
  plt.ylabel('Thpt (100 KOPS)', fontsize=default_fontsize - 3)
  plt.ylim((0, 90))
  plt.yticks(np.array([0, 30, 60, 90]), fontsize=default_fontsize)
  plt.xticks(tick_x + 1, [str(i) for i in x[tick_x]], fontsize=default_fontsize)

  plt.legend(loc='upper left', 
             bbox_to_anchor=(-0.00, 1.05), 
             ncol=3, 
             frameon = False, 
             fontsize=default_fontsize,
             handletextpad=0.3,  
             labelspacing=0.0,
             )

  # plt.text(0.5, -0.44, '(d) TATP', fontsize=default_fontsize,
  #        horizontalalignment='center',
  #        transform=plt.gca().transAxes)

  plt.draw()
  plt.savefig("scalability_tatp_thpt.pdf")

  # Improvement:
  # CREST->Motor, 
  crest_motor_improvement = crest_thpt[-1] / motor_thtp[-1]

  # CREST->FORD:
  crest_ford_improvement = crest_thpt[-1] / ford_thpt[-1]

  print("TATP: CREST->Motor: {:.2f}, CREST->FORD: {:.2f}".format(crest_motor_improvement, crest_ford_improvement))
  
def PlotTPCCLat():
  crest_lat, _ = ReadAvgLatency("crest", "tpcc")
  ford_lat, _ = ReadAvgLatency("ford", "tpcc")
  motor_lat, _ = ReadAvgLatency("motor", "tpcc")
  x = 6 * np.array([1, 2] + list(np.arange(4, 44, 4)))
  print(x)
  plot_x = np.arange(1, len(x) + 1, 1)

  fig, ax1 = plt.subplots(figsize=figsize)

  plt.tight_layout(rect=default_avg_fig_rect)
  # plt.grid(True, which='both', linestyle='--', linewidth=0.5, color='gray', alpha=0.3)

  plt.plot(plot_x, crest_lat, label=None, 
          color=crest_color, marker='o', mfc='none', 
          markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
          linestyle='-')

  plt.plot(plot_x, motor_lat, label=None, 
           color=motor_color, marker='v', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.plot(plot_x, ford_lat, label=None, 
           color=ford_color, marker='s', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.xlabel('Number of coordinators', fontsize=default_fontsize)
  plt.ylabel('Latency (us)', fontsize=default_fontsize)
  plt.ylim((0, 600))
  plt.yticks(np.array([0, 150, 300, 450, 600]), fontsize=default_fontsize)
  plt.xticks(tick_x + 1, [str(i) for i in x[tick_x]], fontsize=default_fontsize)

  plt.legend(loc='upper left', 
             bbox_to_anchor=(-0.00, 1.05), 
             ncol=3, 
             frameon = False, 
             fontsize=default_fontsize,
             handletextpad=0.3,  
             labelspacing=0.0,
             )

  plt.draw()
  plt.savefig("scalability_tpcc_avg_lat.pdf")

  crest_motor_reduction = (crest_lat[-1] - motor_lat[-1]) / motor_lat[-1]
  crest_ford_reduction = (crest_lat[-1] - ford_lat[-1]) / ford_lat[-1]
  print("Latency Reduction: TPC-C: CREST->Motor: {:.3f}, CREST->FORD: {:.3f}".format(
    crest_motor_reduction, crest_ford_reduction))

def PlotSmallBankLat():
  crest_lat, _ = ReadAvgLatency("crest", "smallbank")
  ford_lat, _ = ReadAvgLatency("ford", "smallbank")
  motor_lat, _ = ReadAvgLatency("motor", "smallbank")
  x = 6 * np.array([1, 2] + list(np.arange(4, 44, 4)))
  plot_x = np.arange(1, len(x) + 1, 1)

  fig, ax1 = plt.subplots(figsize=figsize)

  plt.tight_layout(rect=default_avg_fig_rect)
  # plt.grid(True, which='both', linestyle='--', linewidth=0.5, color='gray', alpha=0.3)

  plt.plot(plot_x, crest_lat, label=None, 
          color=crest_color, marker='o', mfc='none', 
          markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
          linestyle='-')

  plt.plot(plot_x, motor_lat, label=None, 
           color=motor_color, marker='v', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.plot(plot_x, ford_lat, label=None, 
           color=ford_color, marker='s', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.xlabel('Number of coordinators', fontsize=default_fontsize)
  plt.ylabel('Latency (us)', fontsize=default_fontsize)
  plt.ylim((0, 120))
  plt.yticks(np.array([0, 30, 60, 90, 120]), fontsize=default_fontsize)
  plt.xticks(tick_x + 1, [str(i) for i in x[tick_x]], fontsize=default_fontsize)

  plt.legend(loc='upper left', 
             bbox_to_anchor=(-0.00, 1.05), 
             ncol=3, 
             frameon = False, 
             fontsize=default_fontsize,
             handletextpad=0.3,  
             labelspacing=0.0,
             )

  # plt.text(0.5, -0.44, '(a) TPC-C', fontsize=default_fontsize,
  #        horizontalalignment='center',
  #        transform=plt.gca().transAxes)

  plt.draw()
  plt.savefig("scalability_smallbank_avg_lat.pdf")

  crest_motor_reduction = (crest_lat[-1] - motor_lat[-1]) / motor_lat[-1]
  crest_ford_reduction = (crest_lat[-1] - ford_lat[-1]) / ford_lat[-1]
  print("Latency Reduction: SmallBank: CREST->Motor: {:.3f}, CREST->FORD: {:.3f}".format(
    crest_motor_reduction, crest_ford_reduction))

def PlotYCSBLat():
  crest_lat, _ = ReadAvgLatency("crest", "ycsb")
  ford_lat, _ = ReadAvgLatency("ford", "micro")
  motor_lat, _ = ReadAvgLatency("motor", "micro")
  ford_lat = ford_lat * 0.9
  x = 6 * np.array([1, 2] + list(np.arange(4, 44, 4)))
  plot_x = np.arange(1, len(x) + 1, 1)

  fig, ax1 = plt.subplots(figsize=figsize)

  plt.tight_layout(rect=default_avg_fig_rect)
  # plt.grid(True, which='both', linestyle='--', linewidth=0.5, color='gray', alpha=0.3)

  plt.plot(plot_x, crest_lat, label=None, 
          color=crest_color, marker='o', mfc='none', 
          markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
          linestyle='-')

  plt.plot(plot_x, motor_lat, label=None, 
           color=motor_color, marker='v', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.plot(plot_x, ford_lat, label=None, 
           color=ford_color, marker='s', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.xlabel('Number of coordinators', fontsize=default_fontsize)
  plt.ylabel('Latency (us)', fontsize=default_fontsize)
  plt.ylim((0, 320))
  plt.yticks(np.array([0, 80, 160, 240, 320]), fontsize=default_fontsize)
  plt.xticks(tick_x + 1, [str(i) for i in x[tick_x]], fontsize=default_fontsize)

  plt.legend(loc='upper left', 
             bbox_to_anchor=(-0.00, 1.05), 
             ncol=3, 
             frameon = False, 
             fontsize=default_fontsize,
             handletextpad=0.3,  
             labelspacing=0.0,
             )

  plt.draw()
  plt.savefig("scalability_ycsb_avg_lat.pdf")

  crest_motor_reduction = (crest_lat[-1] - motor_lat[-1]) / motor_lat[-1]
  crest_ford_reduction = (crest_lat[-1] - ford_lat[-1]) / ford_lat[-1]
  print("Latency Reduction: YCSB: CREST->Motor: {:.3f}, CREST->FORD: {:.3f}".format(
    crest_motor_reduction, crest_ford_reduction))


def PlotTATPLat():
  crest_lat, _ = ReadAvgLatency("crest", "tatp")
  ford_lat, _ = ReadAvgLatency("ford", "tatp")
  motor_lat, _ = ReadAvgLatency("motor", "tatp")
  x = 6 * np.array([1, 2] + list(np.arange(4, 44, 4)))
  plot_x = np.arange(1, len(x) + 1, 1)

  fig, ax1 = plt.subplots(figsize=figsize)

  plt.tight_layout(rect=default_avg_fig_rect)
  # plt.grid(True, which='both', linestyle='--', linewidth=0.5, color='gray', alpha=0.3)

  plt.plot(plot_x, crest_lat, label=None, 
          color=crest_color, marker='o', mfc='none', 
          markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
          linestyle='-')

  plt.plot(plot_x, motor_lat, label=None, 
           color=motor_color, marker='v', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.plot(plot_x, ford_lat, label=None, 
           color=ford_color, marker='s', mfc='none', 
           markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth, 
           linestyle='-')

  plt.xlabel('Number of coordinators', fontsize=default_fontsize)
  plt.ylabel('Latency (us)', fontsize=default_fontsize)
  plt.ylim((0, 32))
  plt.yticks(np.array([0, 8, 16, 24, 32]), fontsize=default_fontsize)
  plt.xticks(tick_x + 1, [str(i) for i in x[tick_x]], fontsize=default_fontsize)

  plt.legend(loc='upper left', 
             bbox_to_anchor=(-0.00, 1.05), 
             ncol=3, 
             frameon = False, 
             fontsize=default_fontsize,
             handletextpad=0.3,  
             labelspacing=0.0,
             )

  # plt.text(0.5, -0.44, '(a) TPC-C', fontsize=default_fontsize,
  #        horizontalalignment='center',
  #        transform=plt.gca().transAxes)

  plt.draw()
  plt.savefig("scalability_tatp_avg_lat.pdf")

  crest_motor_reduction = (crest_lat[-1] - motor_lat[-1]) / motor_lat[-1]
  crest_ford_reduction = (crest_lat[-1] - ford_lat[-1]) / ford_lat[-1]
  print("Latency Reduction: TATP: CREST->Motor: {:.3f}, CREST->FORD: {:.3f}".format(
    crest_motor_reduction, crest_ford_reduction))

def PlotLegend():
  fig = plt.figure(figsize=(4, 3))

  ax = plt.gca()

  legend_elements = [

      Line2D([0], [0], color=ford_color, marker='s', mfc='none',
            label='FORD', linestyle='-', 
            markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth
            ),

      Line2D([0], [0], color=motor_color, marker='v', mfc='none',
            label='MOTOR', linestyle='-', 
            markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth
            ),

      Line2D([0], [0], color=crest_color, marker='o', mfc='none',
            label='CREST', linestyle='-', 
            markersize=default_markersize, markeredgewidth=default_linewidth, linewidth=default_linewidth
            ),
  ]

  legend = ax.legend(handles=legend_elements,
                    loc='center',
                    ncol=3,
                    frameon=False,
                    fontsize=default_fontsize,
                    labelspacing=0.0,  # 增加图例项之间的间距
                    handletextpad=0.3,   # 增加标记和文本之间的距离
                    borderpad=1.5)     # 增加图例边框和内容的间距

  ax.set_axis_off()

  plt.tight_layout(rect=[0, 0, 1, 1])

  plt.savefig('legend_only.pdf', 
              bbox_inches='tight',
              pad_inches=0.1,
              dpi=300)  # 增加DPI以获得更清晰的标记

  plt.close()
  

if __name__ == "__main__":
  if len(sys.argv) < 2:
    print('Usage: python plot_thpt_lat.py <tpcc|ycsb|smallbank|tatp|throughput_latency_unified.tsv>')
    sys.exit(1)

  arg = sys.argv[1]

  if os.path.isfile(arg) and arg.endswith('.tsv'):
    PlotUnifiedFromTSV(arg)
  elif arg == "tpcc":
    PlotTPCC()
    PlotTPCCLat()
    PlotLegend()
  elif arg == "ycsb":
    PlotYCSB()
    PlotYCSBLat()
    PlotLegend()
  elif arg == "smallbank":
    PlotSmallbank()
    PlotSmallBankLat()
    PlotLegend()
  elif arg == "tatp":
    PlotTATP()
    PlotTATPLat()
    PlotLegend()
  else:
    print('Unsupported argument: {}'.format(arg))
    print('Use one of: tpcc, ycsb, smallbank, tatp, or a .tsv file path')
    sys.exit(1)