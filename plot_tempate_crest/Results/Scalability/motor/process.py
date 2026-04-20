import numpy as np

def process_results(workload:str, round:int):
  all_data = []
  dir_name = workload + "/round" + str(round)
  for i in range(0, 3):
    fname = dir_name + "/" + "motor_{}_results_cn{}.txt".format(workload, i)
    with open(fname, "r") as f:
      lines = f.readlines()
      file_data = []
      for line in lines:
        res = np.array([float(x) for x in line.split()[1:]])
        file_data.append(res)
      all_data.append(file_data)
      f.close()
  all_data = np.array(all_data)
  all_data = all_data.sum(axis=0)
  # Store the result data into a file
  output_file = dir_name + "/" + "motor_{}_aggregated_thpt".format(workload)
  with open(output_file, "w") as f:
    for row in all_data:
      formatted_row = [f"{x:.2f}" if isinstance(x, float) else str(x) for x in row]
      f.write(" ".join(formatted_row) + "\n")

def process(workload:str): 
  for i in range(1, 6):
    process_results(workload, i)

if __name__ == "__main__":
  process("tpcc")
  # process("smallbank")
  # process("micro")
  # process("tatp")




