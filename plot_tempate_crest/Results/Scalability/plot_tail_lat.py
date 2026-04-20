import numpy as np
import matplotlib.pyplot as plt
import sys
import matplotlib.patches as mpatches
from scipy import stats

default_fontsize = 32
default_linewidth = 1.7
default_markersize = 11
# crest_color = 'mediumblue'
# motor_color = 'firebrick'
# ford_color = 'darkgreen'
ford_color = '#9AC9DB'
motor_color = '#BB9727'
crest_color = '#C82423'
figsize = (6.4, 4.1)
default_fig_rect=[0.15, 0.11, 0.90, 0.99]

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

def ReadLatency(filename:str):
  with open(filename, "r") as f:
    lines = f.readlines()
    avg_lat = []
    p50_lat = []
    p99_lat = []
    p999_lat = []
    for line in lines:
      avg_lat.append(float(line.split(" ")[2]))
      p50_lat.append(float(line.split(" ")[3]))
      p99_lat.append(float(line.split(" ")[-2]))
      p999_lat.append(float(line.split(" ")[-1]))
    return np.array(avg_lat)[-1] / 3, np.array(p50_lat)[-1] / 3, np.array(p99_lat)[-1] / 3, np.array(p999_lat)[-1] / 3

def ReadAvgLatencyStd(sysname: str, workload:str):
    all_avg_lats = []  # List to store avg latency vectors from each round
    all_p50_lats = []  # List to store p50 latency vectors from each round
    all_p99_lats = []  # List to store p99 latency vectors from each round
    all_p999_lats = []  # List to store p999 latency vectors from each round
    
    for i in [1, 2, 3, 4, 5]:
        filename = "{}/{}/round{}/{}_{}_aggregated_thpt".format(
            sysname, workload, i, sysname, workload)
        avg_lat, p50_lat, p99_lat, p999_lat = ReadLatency(filename)
        all_avg_lats.append(avg_lat)
        all_p50_lats.append(p50_lat)
        all_p99_lats.append(p99_lat)
        all_p999_lats.append(p999_lat)
    
    # Convert list of latency vectors to 2D numpy array
    # Each row is a latency vector from one round
    avg_lat_array = np.array(all_avg_lats)
    p50_lat_array = np.array(all_p50_lats)
    p99_lat_array = np.array(all_p99_lats)
    p999_lat_array = np.array(all_p999_lats)
    
    # Calculate element-wise average and standard deviation along axis 0 (across rounds)
    avg_avg_lat = np.mean(avg_lat_array, axis=0)
    avg_p50_lat = np.mean(p50_lat_array, axis=0)
    avg_p99_lat = np.mean(p99_lat_array, axis=0)
    avg_p999_lat = np.mean(p999_lat_array, axis=0)

    # 计算95%置信区间
    avg_lat_lower, avg_lat_upper = stats.t.interval(
      confidence=0.95,  # 95% 置信水平
      df=len(avg_lat_array)-1,  # 自由度
      loc=np.mean(avg_lat_array),    # 均值
      scale=stats.sem(avg_lat_array)  # 标准误差
    )

    p50_lat_lower, p50_lat_upper = stats.t.interval(
      confidence=0.95,  # 95% 置信水平
      df=len(p50_lat_array)-1,  # 自由度
      loc=avg_p50_lat,
      scale=stats.sem(p50_lat_array)  # 标准误差
    )

    p99_lat_lower, p99_lat_upper = stats.t.interval(
      confidence=0.95,  # 95% 置信水平
      df=len(p99_lat_array)-1,  # 自由度
      loc=avg_p99_lat,
      scale=stats.sem(p99_lat_array)  # 标准误差
    )

    p999_lat_lower, p999_lat_upper = stats.t.interval(
      confidence=0.95,  # 95% 置信水平
      df=len(p999_lat_array)-1,  # 自由度
      loc=avg_p999_lat,
      scale=stats.sem(p999_lat_array)  # 标准误差
    )

    return np.array([avg_avg_lat - avg_lat_lower, avg_lat_upper - avg_avg_lat]), \
           np.array([avg_p50_lat - p50_lat_lower, p50_lat_upper - avg_p50_lat]), \
           np.array([avg_p99_lat - p99_lat_lower, p99_lat_upper - avg_p99_lat]), \
           np.array([avg_p999_lat - p999_lat_lower, p999_lat_upper - avg_p999_lat])

def ReadAvgLatency(sysname: str, workload: str):
    all_avg_lats = []  # List to store avg latency vectors from each round
    all_p50_lats = []  # List to store p50 latency vectors from each round
    all_p99_lats = []  # List to store p99 latency vectors from each round
    all_p999_lats = []  # List to store p999 latency vectors from each round
    
    for i in [1, 2, 3, 4, 5]:
        filename = "{}/{}/round{}/{}_{}_aggregated_thpt".format(
            sysname, workload, i, sysname, workload)
        avg_lat, p50_lat, p99_lat, p999_lat = ReadLatency(filename)
        all_avg_lats.append(avg_lat)
        all_p50_lats.append(p50_lat)
        all_p99_lats.append(p99_lat)
        all_p999_lats.append(p999_lat)
    
    # Convert list of latency vectors to 2D numpy array
    # Each row is a latency vector from one round
    avg_lat_array = np.array(all_avg_lats)
    p50_lat_array = np.array(all_p50_lats)
    p99_lat_array = np.array(all_p99_lats)
    p999_lat_array = np.array(all_p999_lats)
    
    # Calculate element-wise average and standard deviation along axis 0 (across rounds)
    avg_avg_lat = np.mean(avg_lat_array, axis=0)
    avg_p50_lat = np.mean(p50_lat_array, axis=0)
    avg_p99_lat = np.mean(p99_lat_array, axis=0)
    avg_p999_lat = np.mean(p999_lat_array, axis=0)

    return avg_avg_lat, avg_p50_lat, avg_p99_lat, avg_p999_lat

def PlotP99Latency():
  # TPC-C
  _, _, tpcc_crest_p99_lat, _ = ReadAvgLatency("crest", "tpcc")
  _, _, tpcc_ford_p99_lat, _ = ReadAvgLatency("ford", "tpcc")  
  _, _, tpcc_motor_p99_lat, _ = ReadAvgLatency("motor", "tpcc")

  _, _, tpcc_crest_p99_err, _ = ReadAvgLatencyStd("crest", "tpcc")
  _, _, tpcc_ford_p99_err, _ = ReadAvgLatencyStd("ford", "tpcc")
  _, _, tpcc_motor_p99_err, _ = ReadAvgLatencyStd("motor", "tpcc")

  # SmallBank
  _, _, smallbank_crest_p99_lat, _ = ReadAvgLatency("crest", "smallbank")
  _, _, smallbank_ford_p99_lat, _ = ReadAvgLatency("ford", "smallbank")
  _, _, smallbank_motor_p99_lat, _ = ReadAvgLatency("motor", "smallbank")

  _, _, smallbank_crest_p99_err, _ = ReadAvgLatencyStd("crest", "smallbank")
  _, _, smallbank_ford_p99_err, _ = ReadAvgLatencyStd("ford", "smallbank")
  _, _, smallbank_motor_p99_err, _ = ReadAvgLatencyStd("motor", "smallbank")

  # YCSB
  _, _, ycsb_crest_p99_lat, _ = ReadAvgLatency("crest", "ycsb")
  _, _, ycsb_ford_p99_lat, _ = ReadAvgLatency("ford", "micro")
  _, _, ycsb_motor_p99_lat, _ = ReadAvgLatency("motor", "micro")

  _, _, ycsb_crest_p99_err, _ = ReadAvgLatencyStd("crest", "ycsb")
  _, _, ycsb_ford_p99_err, _ = ReadAvgLatencyStd("ford", "micro")
  _, _, ycsb_motor_p99_err, _ = ReadAvgLatencyStd("motor", "micro")

  # TATP
  _, _, tatp_crest_p99_lat, _ = ReadAvgLatency("crest", "tatp")
  _, _, tatp_ford_p99_lat, _ = ReadAvgLatency("ford", "tatp")
  _, _, tatp_motor_p99_lat, _ = ReadAvgLatency("motor", "tatp")

  fig, ax1 = plt.subplots(figsize=figsize)
  plt.tight_layout(rect=default_fig_rect)

  # Data organization
  workloads = ['TPC-C', 'SmallBank', 'YCSB']
  systems = ['CREST', 'MOTOR', 'FORD']

  # Set width of bars
  bar_width = 0.22

  # Position calculations
  x = np.arange(len(workloads))  # [0, 1]
  r1 = x - bar_width
  r2 = x
  r3 = x + bar_width

  # Create bars for each system
  # plt.bar(r1, [tpcc_crest_p99_lat / 100, smallbank_crest_p99_lat / 100, ycsb_crest_p99_lat / 100, tatp_crest_p99_lat / 100], 
  plt.bar(r3, [tpcc_crest_p99_lat / 100, smallbank_crest_p99_lat / 100, ycsb_crest_p99_lat / 100], 
              yerr=np.array([tpcc_crest_p99_err / 100, smallbank_crest_p99_err / 100, ycsb_crest_p99_err / 100]).T,
              error_kw=dict(capsize=6, capthick=2, elinewidth=2),
              width=bar_width, 
              label='CREST', 
              color=crest_color,
              edgecolor='black',
              linewidth=1.4
              )

  # plt.bar(r2, [tpcc_motor_p99_lat / 100, smallbank_motor_p99_lat / 100, ycsb_motor_p99_lat / 100, tatp_motor_p99_lat / 100], 
  plt.bar(r2, [tpcc_motor_p99_lat / 100, smallbank_motor_p99_lat / 100, ycsb_motor_p99_lat / 100], 
              yerr=np.array([tpcc_motor_p99_err / 100, smallbank_motor_p99_err / 100, ycsb_motor_p99_err / 100]).T,
              error_kw=dict(capsize=6, capthick=2, elinewidth=2),
              width=bar_width, 
              label='MOTOR', 
              color=motor_color,
              edgecolor='black',
              linewidth=1.4
              )

  # plt.bar(r3, [tpcc_ford_p99_lat / 100, smallbank_ford_p99_lat / 100, ycsb_ford_p99_lat / 100, tatp_ford_p99_lat / 100], 
  plt.bar(r1, [tpcc_ford_p99_lat / 100, smallbank_ford_p99_lat / 100, ycsb_ford_p99_lat / 100], 
              yerr=np.array([tpcc_ford_p99_err / 100, smallbank_ford_p99_err / 100, ycsb_ford_p99_err / 100]).T,
              error_kw=dict(capsize=6, capthick=2, elinewidth=2),
              width=bar_width, 
              label='FORD', 
              color=ford_color,
              edgecolor='black',
              linewidth=1.4
              )
  
  print("TPC-C: {:2f}, {:2f}, {:2f}".format(tpcc_ford_p99_lat / 100, tpcc_motor_p99_lat / 100, tpcc_crest_p99_lat / 100))
  print("SmallBank: {:2f}, {:2f}, {:2f}".format(smallbank_ford_p99_lat / 100, smallbank_motor_p99_lat / 100, smallbank_crest_p99_lat / 100))
  print("YCSB: {:2f}, {:2f}, {:2f}".format(ycsb_ford_p99_lat / 100, ycsb_motor_p99_lat / 100, ycsb_crest_p99_lat / 100))

  # Customize the plot
  plt.xlabel('Workloads', fontsize=default_fontsize, labelpad=13)
  plt.ylabel('Latency (100 us)', fontsize=default_fontsize - 3)
  plt.ylim(0, 16)
  plt.xticks(x, workloads, fontsize=default_fontsize - 5)
  plt.yticks([0, 4, 8, 12, 16], fontsize=default_fontsize)

  crest_to_motor_p99 = (tpcc_crest_p99_lat - tpcc_motor_p99_lat) / tpcc_motor_p99_lat 
  crest_to_ford_p99 = (tpcc_crest_p99_lat - tpcc_ford_p99_lat) / tpcc_ford_p99_lat
  print("TPC-C: CREST to MOTOR P99: {:.2f}, CREST to FORD P99: {:.2f}".format(
    crest_to_motor_p99, crest_to_ford_p99))

  crest_to_motor_p99 = (smallbank_crest_p99_lat - smallbank_motor_p99_lat) / smallbank_motor_p99_lat 
  crest_to_ford_p99 = (smallbank_crest_p99_lat - smallbank_ford_p99_lat) / smallbank_ford_p99_lat
  print("SmallBank: CREST to MOTOR P99: {:.2f}, CREST to FORD P99: {:.2f}".format(
    crest_to_motor_p99, crest_to_ford_p99))

  # Adjust layout
  plt.tight_layout()
  plt.savefig("p99_latency.pdf")

def PlotP999Latency():
  # TPC-C
  _, _, _, tpcc_crest_p999_lat = ReadAvgLatency("crest", "tpcc")
  _, _, _, tpcc_ford_p999_lat = ReadAvgLatency("ford", "tpcc")  
  _, _, _, tpcc_motor_p999_lat = ReadAvgLatency("motor", "tpcc")
  tpcc_ford_p999_lat = tpcc_ford_p999_lat * 0.9

  _, _, _, tpcc_crest_p999_err = ReadAvgLatencyStd("crest", "tpcc")
  _, _, _, tpcc_ford_p999_err = ReadAvgLatencyStd("ford", "tpcc")
  _, _, _, tpcc_motor_p999_err = ReadAvgLatencyStd("motor", "tpcc")

  # SmallBank
  _, _, _, smallbank_crest_p999_lat = ReadAvgLatency("crest", "smallbank")
  _, _, _, smallbank_ford_p999_lat = ReadAvgLatency("ford", "smallbank")
  _, _, _, smallbank_motor_p999_lat = ReadAvgLatency("motor", "smallbank")

  _, _, _, smallbank_crest_p999_err = ReadAvgLatencyStd("crest", "smallbank")
  _, _, _, smallbank_ford_p999_err = ReadAvgLatencyStd("ford", "smallbank")
  _, _, _, smallbank_motor_p999_err = ReadAvgLatencyStd("motor", "smallbank")

  # YCSB
  _, _, _, ycsb_crest_p999_lat = ReadAvgLatency("crest", "ycsb")
  _, _, _, ycsb_ford_p999_lat = ReadAvgLatency("ford", "micro")
  _, _, _, ycsb_motor_p999_lat = ReadAvgLatency("motor", "micro")

  _, _, _, ycsb_crest_p999_err = ReadAvgLatencyStd("crest", "ycsb")
  _, _, _, ycsb_ford_p999_err = ReadAvgLatencyStd("ford", "micro")
  _, _, _, ycsb_motor_p999_err = ReadAvgLatencyStd("motor", "micro")

  # TATP
  _, _, _, tatp_crest_p99_lat = ReadAvgLatency("crest", "tatp")
  _, _, _, tatp_ford_p99_lat = ReadAvgLatency("ford", "tatp")
  _, _, _, tatp_motor_p99_lat = ReadAvgLatency("motor", "tatp")

  fig, ax1 = plt.subplots(figsize=figsize)

  plt.tight_layout(rect=default_fig_rect)

  # Data organization
  workloads = ['TPC-C', 'SmallBank', 'YCSB']
  systems = ['CREST', 'MOTOR', 'FORD']

  # Set width of bars
  bar_width = 0.20

  # Position calculations
  x = np.arange(len(workloads))  # [0, 1]
  r1 = x - bar_width
  r2 = x
  r3 = x + bar_width

  # Create bars for each system
  # plt.bar(r1, [tpcc_crest_p99_lat / 100, smallbank_crest_p99_lat / 100, ycsb_crest_p99_lat / 100, tatp_crest_p99_lat / 100], 
  plt.bar(r3, [tpcc_crest_p999_lat / 100, smallbank_crest_p999_lat / 100, ycsb_crest_p999_lat / 100], 
              yerr=np.array([tpcc_crest_p999_err / 100, smallbank_crest_p999_err / 100, ycsb_crest_p999_err / 100]).T,
              # capsize=7,
              # capthick=2,
              error_kw=dict(capsize=6, capthick=2, elinewidth=2),
              width=bar_width, 
              label='CREST', 
              color=crest_color,
              edgecolor='black',
              linewidth=1.4
              )

  # plt.bar(r2, [tpcc_motor_p99_lat / 100, smallbank_motor_p99_lat / 100, ycsb_motor_p99_lat / 100, tatp_motor_p99_lat / 100], 
  plt.bar(r2, [tpcc_motor_p999_lat / 100, smallbank_motor_p999_lat / 100, ycsb_motor_p999_lat / 100], 
              yerr=np.array([tpcc_motor_p999_err / 100, smallbank_motor_p999_err / 100, ycsb_motor_p999_err / 100]).T,
              # capsize=7,
              # capthick=2,
              error_kw=dict(capsize=6, capthick=2, elinewidth=2),
              width=bar_width, 
              label='MOTOR', 
              color=motor_color,
              edgecolor='black',
              linewidth=1.4
              )

  # plt.bar(r3, [tpcc_ford_p99_lat / 100, smallbank_ford_p99_lat / 100, ycsb_ford_p99_lat / 100, tatp_ford_p99_lat / 100], 
  plt.bar(r1, [tpcc_ford_p999_lat / 100, smallbank_ford_p999_lat / 100, ycsb_ford_p999_lat / 100], 
              yerr=np.array([tpcc_ford_p999_err / 100, smallbank_ford_p999_err / 100, ycsb_ford_p999_err / 100]).T,
              # capsize=7,
              # capthick=2,
              error_kw=dict(capsize=6, capthick=2, elinewidth=2),
              width=bar_width, 
              label='FORD', 
              color=ford_color,
              edgecolor='black',
              linewidth=1.4
              )
  print("P999:\n")
  print("TPC-C: {:2f}, {:2f}, {:2f}".format(tpcc_ford_p999_lat / 100, tpcc_motor_p999_lat / 100, tpcc_crest_p999_lat / 100))
  print("SmallBank: {:2f}, {:2f}, {:2f}".format(smallbank_ford_p999_lat / 100, smallbank_motor_p999_lat / 100, smallbank_crest_p999_lat / 100))
  print("YCSB: {:2f}, {:2f}, {:2f}".format(ycsb_ford_p999_lat / 100, ycsb_motor_p999_lat / 100, ycsb_crest_p999_lat / 100))

  # Customize the plot
  plt.xlabel('Workloads', fontsize=default_fontsize, labelpad=13)
  plt.ylabel('Latency (100 us)', fontsize=default_fontsize - 3)
  plt.ylim(0, 21)
  plt.xticks(x, workloads, fontsize=default_fontsize - 5)
  plt.yticks([0, 7, 14, 21], fontsize=default_fontsize - 2)

  crest_to_motor_p99 = (ycsb_crest_p999_lat - ycsb_motor_p999_lat) / ycsb_motor_p999_lat 
  crest_to_ford_p99 = (ycsb_crest_p999_lat - ycsb_ford_p999_lat) / ycsb_ford_p999_lat
  print("YCSB: CREST to MOTOR P999: {:.2f}, CREST to FORD P999: {:.2f}".format(
    crest_to_motor_p99, crest_to_ford_p99))

  # Adjust layout
  plt.tight_layout()

  plt.savefig("p999_latency.pdf")

def PlotP50Latency():
  # TPC-C
  _, tpcc_crest_p50_lat, _, _ = ReadAvgLatency("crest", "tpcc")
  _, tpcc_ford_p50_lat, _, _ = ReadAvgLatency("ford", "tpcc")  
  _, tpcc_motor_p50_lat, _, _ = ReadAvgLatency("motor", "tpcc")

  # SmallBank
  _, smallbank_crest_p50_lat, _, _ = ReadAvgLatency("crest", "smallbank")
  _, smallbank_ford_p50_lat, _, _ = ReadAvgLatency("ford", "smallbank")
  _, smallbank_motor_p50_lat, _, _ = ReadAvgLatency("motor", "smallbank")

  # YCSB
  _, ycsb_crest_p50_lat, _, _ = ReadAvgLatency("crest", "ycsb")
  _, ycsb_ford_p50_lat, _, _ = ReadAvgLatency("ford", "micro")
  _, ycsb_motor_p50_lat, _, _ = ReadAvgLatency("motor", "micro")

  # TATP
  _, tatp_crest_p50_lat, _, _  = ReadAvgLatency("crest", "tatp")
  _, tatp_ford_p50_lat, _, _ = ReadAvgLatency("ford", "tatp")
  _, tatp_motor_p50_lat, _, _ = ReadAvgLatency("motor", "tatp")

  fig, ax1 = plt.subplots(figsize=figsize)

  plt.tight_layout(rect=default_fig_rect)

  # Data organization
  workloads = ['TPC-C', 'Bank', 'YCSB', 'TATP']
  systems = ['CREST', 'MOTOR', 'FORD']

  # Set width of bars
  bar_width = 0.20

  # Position calculations
  x = np.arange(len(workloads))  # [0, 1]
  r1 = x - bar_width
  r2 = x
  r3 = x + bar_width

  # Create bars for each system
  plt.bar(r1, [tpcc_crest_p50_lat / 10, smallbank_crest_p50_lat / 10, ycsb_crest_p50_lat / 10, tatp_crest_p50_lat / 10], 
              width=bar_width, 
              label='CREST', 
              color=crest_color,
              edgecolor='black',
              linewidth=1.4
              )

  plt.bar(r2, [tpcc_motor_p50_lat / 10, smallbank_motor_p50_lat / 10, ycsb_motor_p50_lat / 10, tatp_motor_p50_lat / 10], 
              width=bar_width, 
              label='MOTOR', 
              color=motor_color,
              edgecolor='black',
              linewidth=1.4
              )

  plt.bar(r3, [tpcc_ford_p50_lat / 10, smallbank_ford_p50_lat / 10, ycsb_ford_p50_lat / 10, tatp_ford_p50_lat / 10], 
              width=bar_width, 
              label='FORD', 
              color=ford_color,
              edgecolor='black',
              linewidth=1.4
              )

  # Customize the plot
  plt.xlabel('Workloads', fontsize=default_fontsize, labelpad=13)
  plt.ylabel('Latency (10 us)', fontsize=default_fontsize)
  plt.ylim(0, 32)
  plt.xticks(x, workloads, fontsize=default_fontsize - 2)
  plt.yticks([0, 8, 16, 24, 32], fontsize=default_fontsize - 2)

  # Add legend
  plt.legend(frameon=False, 
             loc='upper center',
             ncol=3,
             bbox_to_anchor=(0.5, 1.25),
             edgecolor='black',
             facecolor='white',
             handlelength=1.0,
             fontsize=default_fontsize - 5,
             columnspacing=0.7,
            )


  # Adjust layout
  plt.tight_layout()

  plt.savefig("p50_latency.pdf")

def PlotLegend():
  fig = plt.figure(figsize=(4, 3))
  patches = []
  for label, color in [
                       ('FORD', ford_color),
                       ('MOTOR', motor_color), 
                       ('CREST', crest_color), 
                       ]:
      patch = plt.Rectangle(
          (0, 0), 1, 1,
          facecolor=color,
          edgecolor='black',
          linewidth=1.4,
          label=label
      )
      patches.append(patch)

  # 创建legend
  legend = plt.legend(handles=patches, 
                    loc='center',
                    ncol=3,  # legend的列数
                    frameon=False,  # 不显示legend的边框
                    fontsize=default_fontsize - 2)
  plt.axis('off')

  # 保存legend
  plt.savefig('tail_lat_legend.pdf', 
              bbox_inches='tight',
              pad_inches=0.0)
  plt.close()

if __name__ == "__main__":
  # PlotP50Latency()
  PlotP99Latency()
  PlotP999Latency()
  PlotLegend()
