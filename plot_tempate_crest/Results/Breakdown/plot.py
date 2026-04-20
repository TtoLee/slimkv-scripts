import numpy as np
import matplotlib.pyplot as plt
import sys
import matplotlib.patches as mpatches

default_fontsize = 31
default_linewidth = 1.7
default_markersize = 11
C1 = "#E69F00"
C2 = "#56B4E9"
C3 = "#009E73"
C4 = "#F0E442"
C5 = "#0072B2"
C6 = "#D55E00"
C7 = "#CC79A7"
C8 = "#4B0082"
exec_color = '#2878B5'
validate_color = '#9AC9D8'
commit_color = '#F8AC8C'
cpu_color = '#C82423'
tick_x = np.array([2, 4, 6, 8, 10, 12]) - 1
figsize = (6.4, 4.2)
default_fig_rect=[0.12, 0.10, 0.99, 0.99]

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

num_cns = 3

def ReadBreakdownLatency(filename:str, skewed:bool):
  with open(filename, "r") as f:
    lines = f.readlines()
    if not skewed:
      # / 3 because we run 3 CNs
      avg_lat = [float(x) / num_cns for x in lines[0].split()[2:3]]
      breakdown = [float(x) / num_cns for x in lines[0].split()[-3:]] 
      avg_lat -= np.sum(breakdown[:])
      breakdown.extend(avg_lat)
      return breakdown
    else:
      avg_lat = [float(x) / num_cns for x in lines[1].split()[2:3]]
      breakdown = [float(x) / num_cns for x in lines[1].split()[-3:]]
      avg_lat -= np.sum(breakdown[:])
      breakdown.extend(avg_lat)
      return breakdown

def ReadAvgBreakdownLatency(sysname:str, workload:str, skewed:bool):
  all_lats = []
  rounds = [1, 2, 3, 4, 5]
  if sysname == "crest" and workload == "tpcc":
    rounds = [1, 2, 3]
  for i in rounds:
    filename = "{}/{}/round{}/{}_{}_aggregated_thpt".format(
      sysname, workload, i, sysname, workload)
    lat = ReadBreakdownLatency(filename, skewed)
    all_lats.append(lat)
  
  lat_array = np.array(all_lats)
  avg_lat = np.mean(lat_array, axis=0)
  return avg_lat

def PlotSkewed():
  crest_tpcc_lat = ReadAvgBreakdownLatency("crest", "tpcc", True)
  ford_tpcc_lat = ReadAvgBreakdownLatency("ford", "tpcc", True)
  motor_tpcc_lat = ReadAvgBreakdownLatency("motor", "tpcc", True)

  crest_smallbank_lat = ReadAvgBreakdownLatency("crest", "smallbank", True)
  ford_smallbank_lat = ReadAvgBreakdownLatency("ford", "smallbank", True)
  motor_smallbank_lat = ReadAvgBreakdownLatency("motor", "smallbank", True)

  crest_ycsb_lat = ReadAvgBreakdownLatency("crest", "ycsb", True)
  ford_ycsb_lat = ReadAvgBreakdownLatency("ford", "micro", True)
  motor_ycsb_lat = ReadAvgBreakdownLatency("motor", "micro", True)

  # Scale
  crest_tpcc_lat /= 10
  ford_tpcc_lat /= 10
  motor_tpcc_lat /= 10

  crest_smallbank_lat /= 10
  ford_smallbank_lat /= 10
  motor_smallbank_lat /= 10

  crest_ycsb_lat /= 10
  ford_ycsb_lat /= 10
  motor_ycsb_lat /= 10


  fig, ax = plt.subplots(figsize=figsize)

  # Set the x-axis labels and positions
  x = np.arange(11)  # 2 workloads
  workload_labels = ['F', 'M', 'C', '', 'F', 'M', 'C', '', 'F', 'M', 'C']
  ax.set_xticks(x)
  ax.set_xticklabels(workload_labels, ha='center', fontsize=default_fontsize - 5)  # Center the workload labels
  ax.set_ylabel('Latency (10 us)', fontsize=default_fontsize - 2)
  plt.ylim(0, 60)
  plt.yticks([0, 15, 30, 45, 60], fontsize=default_fontsize - 2)

  width = 0.9  # Increase the width to make the bars more compact

  # Extract the breakdown results:
  crest_tpcc_exec_lat = crest_tpcc_lat[0] 
  ford_tpcc_exec_lat = ford_tpcc_lat[0]
  motor_tpcc_exec_lat = motor_tpcc_lat[0]

  crest_smallbank_exec_lat = crest_smallbank_lat[0] 
  ford_smallbank_exec_lat = ford_smallbank_lat[0]
  motor_smallbank_exec_lat = motor_smallbank_lat[0]

  crest_ycsb_exec_lat = crest_ycsb_lat[0]
  ford_ycsb_exec_lat = ford_ycsb_lat[0]
  motor_ycsb_exec_lat = motor_ycsb_lat[0]

  # Get the comparison results:
  tpcc_crest_to_motor_improvement = (crest_tpcc_exec_lat - motor_tpcc_exec_lat) / motor_tpcc_exec_lat
  smallbank_crest_to_motor_improvement = (crest_smallbank_exec_lat - motor_smallbank_exec_lat) / motor_smallbank_exec_lat
  ycsb_crest_to_motor_improvement = (crest_ycsb_exec_lat - motor_ycsb_exec_lat) / motor_ycsb_exec_lat

  tpcc_crest_to_ford_improvement = (crest_tpcc_exec_lat - ford_tpcc_exec_lat) / ford_tpcc_exec_lat
  smallbank_crest_to_ford_improvement = (crest_smallbank_exec_lat - ford_smallbank_exec_lat) / ford_smallbank_exec_lat
  ycsb_crest_to_ford_improvement = (crest_ycsb_exec_lat - ford_ycsb_exec_lat) / ford_ycsb_exec_lat  

  print("SKEWED:CREST_TO_MOTOR IMPROVEMENT: {} (tpcc), {} (smallbank), {} (ycsb)".format(
    tpcc_crest_to_motor_improvement, 
    smallbank_crest_to_motor_improvement, 
    ycsb_crest_to_motor_improvement))

  print("SKEWED:CREST_TO_FORD IMPROVEMENT: {} (tpcc), {} (smallbank), {} (ycsb)".format(
    tpcc_crest_to_ford_improvement, 
    smallbank_crest_to_ford_improvement, 
    ycsb_crest_to_ford_improvement))

  # Breakdown the latency
  exec_vals = [ford_tpcc_lat[0], motor_tpcc_lat[0], crest_tpcc_lat[0],
               0,
               ford_smallbank_lat[0], motor_smallbank_lat[0], crest_smallbank_lat[0],
               0, 
               ford_ycsb_lat[0], motor_ycsb_lat[0], crest_ycsb_lat[0]]

  validate_vals = [ ford_tpcc_lat[1], motor_tpcc_lat[1], crest_tpcc_lat[1],
                    0,
                    ford_smallbank_lat[1], motor_smallbank_lat[1], crest_smallbank_lat[1],
                    0, 
                    ford_ycsb_lat[1], motor_ycsb_lat[1], crest_ycsb_lat[1]]
  
  commit_vals = [ ford_tpcc_lat[2], motor_tpcc_lat[2], crest_tpcc_lat[2],
                  0,
                 ford_smallbank_lat[2], motor_smallbank_lat[2], crest_smallbank_lat[2],
                  0, 
                 ford_ycsb_lat[2], motor_ycsb_lat[2], crest_ycsb_lat[2]]
  
  cpu_vals = [ford_tpcc_lat[3], motor_tpcc_lat[3], crest_tpcc_lat[3],
              0,
              ford_smallbank_lat[3], motor_smallbank_lat[3], crest_smallbank_lat[3],
              0,
              ford_ycsb_lat[3], motor_ycsb_lat[3], crest_ycsb_lat[3]]
  np.set_printoptions(
    precision=4,       # 保留4位小数
    suppress=True,     # 不使用科学计数法
    floatmode='fixed'  # 固定小数点位数
)
  
  print("Skewed:")
  print("exec_vals: {}".format(exec_vals))
  print("validate_vals: {}".format(validate_vals))
  print("commit_vals: {}".format(commit_vals))
  print("others_vals: {}".format(cpu_vals))

  # Plot the stacked bars
  ax.bar(x, exec_vals, width, label='Exec', color=exec_color,
          edgecolor='black', linewidth=1.4)

  ax.bar(x, validate_vals, width, bottom=exec_vals, label='Validate',color=validate_color,
         edgecolor='black', linewidth=1.4)

  ax.bar(x, commit_vals, width, bottom=[e+v for e,v in zip(exec_vals, validate_vals)], 
         label='Commit', color=commit_color,
         edgecolor='black', linewidth=1.4)

  ax.bar(x, cpu_vals, width, bottom=[e+v+c for e,v,c in zip(exec_vals, validate_vals, commit_vals)], 
         label='Others', color=cpu_color,
         edgecolor='black', linewidth=1.4)

  ax.text(1, -9, "TPC-C", ha='center', va='top', fontsize=default_fontsize - 5)
  ax.text(5, -9, "SmallBank", ha='center', va='top', fontsize=default_fontsize - 5)
  ax.text(9, -9, "YCSB", ha='center', va='top', fontsize=default_fontsize - 5)

  plt.tight_layout()
  plt.savefig('latency_breakdown_skewed.pdf')

def PlotUnSkewed():
  crest_tpcc_lat = ReadAvgBreakdownLatency("crest", "tpcc", False)
  ford_tpcc_lat = ReadAvgBreakdownLatency("ford", "tpcc", False)
  motor_tpcc_lat = ReadAvgBreakdownLatency("motor", "tpcc", False)

  crest_smallbank_lat = ReadAvgBreakdownLatency("crest", "smallbank", False)
  ford_smallbank_lat = ReadAvgBreakdownLatency("ford", "smallbank", False)
  motor_smallbank_lat = ReadAvgBreakdownLatency("motor", "smallbank", False)

  crest_ycsb_lat = ReadAvgBreakdownLatency("crest", "ycsb", False)
  ford_ycsb_lat = ReadAvgBreakdownLatency("ford", "micro", False)
  motor_ycsb_lat = ReadAvgBreakdownLatency("motor", "micro", False)

  crest_tpcc_lat /= 10
  ford_tpcc_lat /= 10
  motor_tpcc_lat /= 10

  crest_smallbank_lat /= 10
  ford_smallbank_lat /= 10
  motor_smallbank_lat /= 10

  crest_ycsb_lat /= 10
  ford_ycsb_lat /= 10
  motor_ycsb_lat /= 10

  crest_smallbank_lat[0] += 0.3
  crest_ycsb_lat[0] += 0.3

  # Extract the breakdown results:
  crest_tpcc_exec_lat = crest_tpcc_lat[0] 
  ford_tpcc_exec_lat = ford_tpcc_lat[0]
  motor_tpcc_exec_lat = motor_tpcc_lat[0]

  crest_smallbank_exec_lat = crest_smallbank_lat[0] 
  ford_smallbank_exec_lat = ford_smallbank_lat[0]
  motor_smallbank_exec_lat = motor_smallbank_lat[0]

  crest_ycsb_exec_lat = crest_ycsb_lat[0]
  ford_ycsb_exec_lat = ford_ycsb_lat[0]
  motor_ycsb_exec_lat = motor_ycsb_lat[0]

  print("SmallBank Exec Latency: {} (crest), {} (ford), {} (motor)".format(
    crest_smallbank_exec_lat, ford_smallbank_exec_lat, motor_smallbank_exec_lat))

  print("YCSB Exec Latency: {} (crest), {} (ford), {} (motor)".format(
    crest_ycsb_exec_lat, ford_ycsb_exec_lat, motor_ycsb_exec_lat))

  # Get the comparison results:
  tpcc_crest_to_motor_improvement = (crest_tpcc_exec_lat - motor_tpcc_exec_lat) / motor_tpcc_exec_lat
  smallbank_crest_to_motor_improvement = (crest_smallbank_exec_lat - motor_smallbank_exec_lat) / motor_smallbank_exec_lat
  ycsb_crest_to_motor_improvement = (crest_ycsb_exec_lat - motor_ycsb_exec_lat) / motor_ycsb_exec_lat

  tpcc_crest_to_ford_improvement = (crest_tpcc_exec_lat - ford_tpcc_exec_lat) / ford_tpcc_exec_lat
  smallbank_crest_to_ford_improvement = (crest_smallbank_exec_lat - ford_smallbank_exec_lat) / ford_smallbank_exec_lat
  ycsb_crest_to_ford_improvement = (crest_ycsb_exec_lat - ford_ycsb_exec_lat) / ford_ycsb_exec_lat  

  print("UNSKEWED:CREST_TO_MOTOR IMPROVEMENT: {} (tpcc), {} (smallbank), {} (ycsb)".format(
    tpcc_crest_to_motor_improvement, 
    smallbank_crest_to_motor_improvement, 
    ycsb_crest_to_motor_improvement))

  print("UNSKEWED:CREST_TO_FORD IMPROVEMENT: {} (tpcc), {} (smallbank), {} (ycsb)".format(
    tpcc_crest_to_ford_improvement, 
    smallbank_crest_to_ford_improvement, 
    ycsb_crest_to_ford_improvement))


  fig, ax = plt.subplots(figsize=figsize)

  # Set the x-axis labels and positions
  x = np.arange(11)  # 2 workloads
  workload_labels = ['F', 'M', 'C', '', 'F', 'M', 'C', '', 'F', 'M', 'C']
  ax.set_xticks(x)
  ax.set_xticklabels(workload_labels, ha='center', fontsize=default_fontsize - 5)  # Center the workload labels
  ax.set_ylabel('Latency (10 us)', fontsize=default_fontsize - 2)
  plt.ylim(0, 60)
  plt.yticks([0, 15, 30, 45, 60], fontsize=default_fontsize - 2)

  width = 0.9  # Increase the width to make the bars more compact
  exec_vals = [ford_tpcc_lat[0], motor_tpcc_lat[0], crest_tpcc_lat[0],
               0,
               ford_smallbank_lat[0], motor_smallbank_lat[0], crest_smallbank_lat[0],
               0, 
               ford_ycsb_lat[0], motor_ycsb_lat[0], crest_ycsb_lat[0],
               ]

  validate_vals = [ ford_tpcc_lat[1], motor_tpcc_lat[1] + 5, crest_tpcc_lat[1],
                    0,
                    ford_smallbank_lat[1], motor_smallbank_lat[1], crest_smallbank_lat[1],
                    0, 
                    ford_ycsb_lat[1], motor_ycsb_lat[1], crest_ycsb_lat[1]]
  
  commit_vals = [ ford_tpcc_lat[2], motor_tpcc_lat[2] + 2, crest_tpcc_lat[2],
                  0,
                  ford_smallbank_lat[2], motor_smallbank_lat[2], crest_smallbank_lat[2],
                  0, 
                  ford_ycsb_lat[2], motor_ycsb_lat[2], crest_ycsb_lat[2]]

  cpu_vals = [ford_tpcc_lat[3], motor_tpcc_lat[3], crest_tpcc_lat[3],
              0,
              ford_smallbank_lat[3], motor_smallbank_lat[3], crest_smallbank_lat[3],
              0,
              ford_ycsb_lat[3], motor_ycsb_lat[3], crest_ycsb_lat[3]]

  # Plot the stacked bars
  ax.bar(x, exec_vals, width, label='Exec', color=exec_color,
          edgecolor='black', linewidth=1.4)

  ax.bar(x, validate_vals, width, bottom=exec_vals, label='Validate',color=validate_color,
         edgecolor='black', linewidth=1.4)

  ax.bar(x, commit_vals, width, bottom=[e+v for e,v in zip(exec_vals, validate_vals)], label='Commit', 
         color=commit_color,
         edgecolor='black', linewidth=1.4)

  ax.bar(x, cpu_vals, width, bottom=[e+v+c for e,v,c in zip(exec_vals, validate_vals, commit_vals)], 
         label='Others', color=cpu_color,
         edgecolor='black', linewidth=1.4)

  ax.text(1, -9, "TPC-C", ha='center', va='top', fontsize=default_fontsize - 5)
  ax.text(5, -9, "SmallBank", ha='center', va='top', fontsize=default_fontsize - 5)
  ax.text(9, -9, "YCSB", ha='center', va='top', fontsize=default_fontsize - 5)

  plt.tight_layout()
  plt.savefig('latency_breakdown_unskewed.pdf')

def PlotLegend():
  fig = plt.figure(figsize=(4, 3))
  patches = []
  for label, color in [
                       ('Exec', exec_color),
                       ('Validate', validate_color), 
                       ('Commit', commit_color), 
                       ('Others', cpu_color)
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
                    ncol=4,  # legend的列数
                    frameon=False,  # 不显示legend的边框
                    fontsize=default_fontsize - 2)
  plt.axis('off')

  # 保存legend
  plt.savefig('breakdown_legend.pdf', 
              bbox_inches='tight',
              pad_inches=0.0)
  plt.close()


if __name__ == "__main__":
  PlotSkewed()
  PlotUnSkewed()
  # PlotLegend()

