import numpy as np
import matplotlib.pyplot as plt
import sys
import matplotlib.patches as mpatches
from matplotlib.lines import Line2D
from scipy import stats

default_fontsize = 31
default_linewidth = 1.7
default_markersize = 11
ford_color = '#9AC9DB'
motor_color = '#BB9727'
crest_color = '#C82423'
vallina_color = 'mistyrose'
cell_level_color = 'lightcoral'
tick_x = np.array([2, 4, 6, 8, 10, 12]) - 1
figsize = (6.7, 3.8)
default_fig_rect=[0.15, 0.15, 0.99, 0.99]
default_bar_width=0.18

plt.rcParams['axes.linewidth'] = 1.5
plt.rcParams['xtick.major.width'] = 1.5
plt.rcParams['ytick.major.width'] = 1.5
plt.rcParams['font.family'] = 'Arial'

# Force TrueType fonts
plt.rcParams['pdf.fonttype'] = 42
plt.rcParams['ps.fonttype'] = 42

# Set Arial as the font family
plt.rcParams['font.family'] = 'sans-serif'
plt.rcParams['font.sans-serif'] = ['Arial']

# Ensure text is not rendered with LaTeX
plt.rcParams['text.usetex'] = False

def ReadAvgThpt(line:int, skewed:bool): 
  all_thpts = []  # List to store throughput vectors from each round

  num_samples = 10
    
  for i in [1, 2, 3]:
    if skewed:
      filename = "skewed/round{}".format(i)
    else:
      filename = "unskewed/round{}".format(i)
    with open(filename, 'r') as f:
      lines = f.readlines()
      all_thpts.append([float(v) for v in lines[line].split(" ")])
    
    # Convert list of throughput vectors to 2D numpy array
    # Each row is a throughput vector from one round

  thpt_array = np.array(all_thpts)
  num_rounds = 3
  thpt = [thpt_array[:, i] for i in range(num_rounds)]
    
    # Calculate element-wise average and standard deviation along axis 0 (across rounds)
    # Calculate 95% confidence interval

    # # Calculate the 95% confidence interval:
  mean = np.array([np.mean(thpt[i]) for i in range(num_rounds)])
  values = np.array([stats.t.interval(
    confidence=0.95,
    df = len(thpt[i]) - 1,
    loc = np.mean(thpt[i]),
    scale=stats.sem(thpt[i])
  ) for i in range(3)])
  lower = np.array([v[0] for v in values])
  upper = np.array([v[1] for v in values])

    # Return the following results: mean, err_lower, err_upper:
  return mean, mean - lower, upper - mean
  

def PlotSkewed():
  # Workload: TPC-C, SmallBank, YCSB
  motor_values, motor_err1, motor_err2 = ReadAvgThpt(0, True)
  valina_values, valina_err1, valina_err2 = ReadAvgThpt(1, True)
  cell_level_values, cell_level_err1, cell_level_err2 = ReadAvgThpt(2, True)
  localized_values, localized_err1, localized_err2 = ReadAvgThpt(3, True)

  print("Skewed")
  print("Motor: ", motor_values)
  print("Valina: ", valina_values)
  print("Cell-Level: ", cell_level_values)
  print("Localized: ", localized_values)

  fig, ax1 = plt.subplots(figsize=figsize)

  plt.tight_layout(rect=default_fig_rect)

  bar_width = default_bar_width

  x = np.array([1, 2, 3])
  r1 = x - bar_width / 2 - bar_width
  r2 = x - bar_width / 2
  r3 = x + bar_width / 2
  r4 = x + bar_width / 2 + bar_width

  ax1.bar(r1, motor_values, 
        yerr=[motor_err1, motor_err2],
        error_kw=dict(capsize=6, capthick=2, elinewidth=2),
        width=bar_width, 
        color=motor_color, 
        label='MOTOR',
        edgecolor='black',
        linewidth=1.4,
        )

  ax1.bar(r2, valina_values, 
          yerr = [valina_err1, valina_err2],
          error_kw=dict(capsize=6, capthick=2, elinewidth=2),
          width=bar_width, 
          color=vallina_color, 
          label='Vallina',
          edgecolor='black',
          linewidth=1.4,
          )

  ax1.bar(r3, cell_level_values, 
          yerr = [cell_level_err1, cell_level_err2],
          error_kw=dict(capsize=6, capthick=2, elinewidth=2),
          width=bar_width, 
          color=cell_level_color,
          label='+ Cell-Level',
          edgecolor='black',
          linewidth=1.4,
          )

  ax1.bar(r4, localized_values, 
          yerr = [localized_err1, localized_err2],
          error_kw=dict(capsize=6, capthick=2, elinewidth=2),
          width=bar_width, 
          color=crest_color, 
          label='+ Localized',
          edgecolor='black',
          linewidth=1.4,
          )
  
  plt.xlabel("Workloads", fontsize=default_fontsize)
  plt.ylabel('Thpt (KOPS)', fontsize=default_fontsize - 3)
  plt.ylim((0, 3000))
  plt.yticks(np.array([0, 1000, 2000, 3000]), fontsize=default_fontsize - 5)
  plt.xticks(x, ["TPC-C", "SmallBank", "YCSB"], fontsize=default_fontsize - 6)

  plt.draw()
  plt.savefig("technique_analysis_skewed_thpt.pdf")

def PlotUnSkewed():
  # Workload: TPC-C, SmallBank, YCSB
  motor_values, motor_err1, motor_err2 = ReadAvgThpt(0, False)
  valina_values, valina_err1, valina_err2 = ReadAvgThpt(1, False)
  cell_level_values, cell_level_err1, cell_level_err2 = ReadAvgThpt(2, False)
  localized_values, localized_err1, localized_err2 = ReadAvgThpt(3, False)

  print("Unskewed")
  print("Motor: ", motor_values)
  print("Valina: ", valina_values)
  print("Cell-Level: ", cell_level_values)
  print("Localized: ", localized_values)

  fig, ax1 = plt.subplots(figsize=figsize)

  plt.tight_layout(rect=default_fig_rect)

  bar_width = default_bar_width

  x = np.array([1, 2, 3])
  r1 = x - bar_width / 2 - bar_width
  r2 = x - bar_width / 2
  r3 = x + bar_width / 2
  r4 = x + bar_width / 2 + bar_width

  ax1.bar(r1, motor_values,
        yerr = [motor_err1, motor_err2],
        error_kw=dict(capsize=6, capthick=2, elinewidth=2),
        width=bar_width, 
        color=motor_color, 
        label='MOTOR',
        edgecolor='black',
        linewidth=1.4,
        )

  ax1.bar(r2, valina_values, 
          yerr = [valina_err1, valina_err2],
          error_kw=dict(capsize=6, capthick=2, elinewidth=2),
          width=bar_width, 
          color=vallina_color, 
          label='Vallina',
          edgecolor='black',
          linewidth=1.4,
          )

  ax1.bar(r3, cell_level_values, 
          yerr = [cell_level_err1, cell_level_err2],
          error_kw=dict(capsize=6, capthick=2, elinewidth=2),
          width=bar_width, 
          color=cell_level_color,
          label='+ Cell-Level',
          edgecolor='black',
          linewidth=1.4,
          )

  ax1.bar(r4, localized_values,
          yerr = [localized_err1, localized_err2],
          error_kw=dict(capsize=6, capthick=2, elinewidth=2),
          width=bar_width, 
          color=crest_color, 
          label='+ Localized',
          edgecolor='black',
          linewidth=1.4,
          )
  
  plt.xlabel("Workloads", fontsize=default_fontsize)
  plt.ylabel('Thpt (KOPS)', fontsize=default_fontsize - 3)
  plt.ylim((0, 4500))
  plt.yticks(np.array([0, 1500, 3000, 4500]), fontsize=default_fontsize - 5)
  plt.xticks(x, ["TPC-C", "SmallBank", "YCSB"], fontsize=default_fontsize - 6)

  plt.draw()
  plt.savefig("technique_analysis_unskewed_thpt.pdf")

def PlotLegend():
  fig = plt.figure(figsize=(4, 3))
  patches = []
  for label, color in [
                       ('MOTOR', motor_color),
                       ('Base', vallina_color), 
                       ('+ Cell-Level', cell_level_color), 
                        ('+ Localized', crest_color)
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
  plt.savefig('technique_analysis_legend.pdf', 
              bbox_inches='tight',
              pad_inches=0.0)
  plt.close()

if __name__ == '__main__':
  PlotSkewed()
  PlotUnSkewed()
  # PlotLegend()


