// ============================================================================
// main.bicep — provisions the full Azure ML MLOps footprint for the energy
// forecasting pipeline. Deploy at resource-group scope.
//
//   az group create -n rg-energy-mlops -l eastus
//   az deployment group create -g rg-energy-mlops \
//       -f infra/main.bicep -p infra/main.bicepparam
//
// Creates: Storage + Key Vault + App Insights + ACR (the workspace's required
// dependencies), the Azure ML workspace itself, and a CPU compute cluster.
// ============================================================================

@description('Base name used to derive resource names.')
param baseName string = 'energy'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the Azure ML workspace.')
param workspaceName string = 'mlw-energy-forecast-v2'

@description('Name of the CPU compute cluster.')
param computeClusterName string = 'cpu-cluster'

@description('VM size for the compute cluster.')
param computeVmSize string = 'Standard_DS3_v2'

@description('Max nodes for the compute cluster (scales to 0 when idle).')
param computeMaxNodes int = 2

// Globally-unique-ish suffix derived from the resource group id.
var suffix = toLower(substring(uniqueString(resourceGroup().id), 0, 8))
var storageName = take('st${baseName}${suffix}', 24)
var kvName = take('kv-${baseName}-${suffix}', 24)
var acrName = take('acr${baseName}${suffix}', 50)
var appInsightsName = 'appi-${baseName}-${suffix}'

// ── Storage account (default datastore for the workspace) ──────────────────
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    encryption: {
      services: {
        blob: { enabled: true }
        file: { enabled: true }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

// ── Key Vault (secrets, connection strings) ────────────────────────────────
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// ── Application Insights (job + endpoint telemetry) ────────────────────────
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

// ── Azure Container Registry (holds AML environment + endpoint images) ──────
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    adminUserEnabled: true
  }
}

// ── Azure ML workspace (the MLOps hub) ─────────────────────────────────────
resource workspace 'Microsoft.MachineLearningServices/workspaces@2024-04-01' = {
  name: workspaceName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  properties: {
    friendlyName: 'Energy Market Forecasting MLOps'
    storageAccount: storage.id
    keyVault: keyVault.id
    applicationInsights: appInsights.id
    containerRegistry: acr.id
    publicNetworkAccess: 'Enabled'
  }
}

// ── CPU compute cluster (runs the training pipeline, scales to 0) ──────────
resource compute 'Microsoft.MachineLearningServices/workspaces/computes@2024-04-01' = {
  parent: workspace
  name: computeClusterName
  location: location
  properties: {
    computeType: 'AmlCompute'
    properties: {
      vmSize: computeVmSize
      vmPriority: 'Dedicated'
      scaleSettings: {
        minNodeCount: 0
        maxNodeCount: computeMaxNodes
        nodeIdleTimeBeforeScaleDown: 'PT3M'
      }
    }
  }
}

output workspaceNameOut string = workspace.name
output acrNameOut string = acr.name
output storageNameOut string = storage.name
output computeClusterNameOut string = compute.name
