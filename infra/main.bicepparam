using './main.bicep'

param baseName = 'energy'
param workspaceName = 'mlw-energy-forecast-v2'
param computeClusterName = 'cpu-cluster'
// Standard_DS2_v2 = 2 vCPUs. This subscription's quota is 4 Total Regional vCPUs
// and 4 Standard DSv2 Family vCPUs, so DS3_v2 (4 vCPUs) would consume the whole
// allowance in a single node and leave nothing for a second node or an endpoint.
// The training set is 4,608 rows x 39 features — DS2_v2 is ample.
param computeVmSize = 'Standard_DS2_v2'
param computeMaxNodes = 2
