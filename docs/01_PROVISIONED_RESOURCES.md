# 01 — Provisioned Azure Resources (live inventory)

Provisioned **2026-08-19** under subscription **<YOUR_SUBSCRIPTION_NAME>**
(`<SUBSCRIPTION_ID>`), account `<YOUR_AZURE_ACCOUNT>`,
tenant `<TENANT_ID>` (`Default Directory`).

Resource group **`rg-energy-mlops`** — region **`eastus`**.

## Subscription constraints (read before changing VM sizes)

| Quota (eastus) | Limit |
|---|---|
| Total Regional vCPUs | **4** |
| Standard DSv2 Family vCPUs | **4** |
| Total Regional Low-priority vCPUs | 3 |

`Standard_DS3_v2` is 4 vCPUs — a single node would consume the entire allowance.
The cluster therefore uses **`Standard_DS2_v2` (2 vCPUs), max 2 nodes**, set in
[`infra/main.bicepparam`](../infra/main.bicepparam) and mirrored in
[`config/config.yaml`](../config/config.yaml) for the endpoint.

Resource providers registered on this subscription (all were `NotRegistered` —
a fresh subscription needs this before anything deploys):
`Microsoft.MachineLearningServices`, `Microsoft.ContainerRegistry`,
`Microsoft.KeyVault`, `Microsoft.Insights`, `Microsoft.OperationalInsights`,
`Microsoft.Network`.

## Infrastructure (Bicep — `energy-infra` deployment)

| # | Resource | Name | Type / SKU | Purpose |
|---|----------|------|------------|---------|
| 1 | Storage account | `st<SUFFIX>` | StorageV2 / Standard_LRS | Default datastore (data assets, job outputs, models) |
| 2 | Key Vault | `kv-energy-<SUFFIX>` | standard, RBAC | Secrets / connection strings |
| 3 | Application Insights | `appi-energy-<SUFFIX>` | web | Job + endpoint telemetry |
| 4 | Container Registry | `acrenergy<SUFFIX>` | Standard | AML environment + endpoint images |
| 5 | Azure ML workspace | `mlw-energy-forecast-v2` | Basic, SystemAssigned identity | MLOps control plane |
| 6 | Compute cluster | `cpu-cluster` | **Standard_DS2_v2**, 0→2 nodes | Runs the pipeline (scales to 0) |

## AML control-plane assets

| Asset | Name : version | Created by |
|-------|----------------|------------|
| Environment | `energy-train-env:4` | [`aml/environment/train-env.yml`](../aml/environment/train-env.yml) |
| Data asset (bronze) | `energy_raw:1` (uri_folder, 9.24 MB) | [`aml/data_assets/01_raw_energy.yml`](../aml/data_assets/01_raw_energy.yml) |
| Pipeline job | `olive_moon_llsz5zb736` | [`aml/pipeline.yml`](../aml/pipeline.yml) — 7 stages, ingest→promote |

> **`energy-train-env:4` matters.** Versions 1–3 in the previous subscription had no
> `setuptools` in the conda env, so `import mlflow` died with
> `ModuleNotFoundError: No module named 'pkg_resources'` and every training run failed.
> Fixed in [`aml/environment/conda.yml`](../aml/environment/conda.yml) with `setuptools<81`.

## Source control / CI-CD

| Item | Value |
|---|---|
| Repository | https://github.com/<GITHUB_USER>/<GITHUB_REPO> (visibility: set by you) |
| Workflow | [`.github/workflows/mlops.yml`](../.github/workflows/mlops.yml) — ci → train → deploy |
| Environment | `production` with a required-reviewer approval gate (needs a public repo, or a paid plan for private repos, on GitHub Free) |
| Secret needed | `AZURE_CREDENTIALS` — output of `az ad sp create-for-rbac ... --json-auth` |

## Studio links

- **Workspace:** https://ml.azure.com/?wsid=/subscriptions/<SUBSCRIPTION_ID>/resourcegroups/rg-energy-mlops/workspaces/mlw-energy-forecast-v2&tid=<TENANT_ID>
- **Pipeline run:** https://ml.azure.com/runs/olive_moon_llsz5zb736?wsid=/subscriptions/<SUBSCRIPTION_ID>/resourcegroups/rg-energy-mlops/workspaces/mlw-energy-forecast-v2&tid=<TENANT_ID>

## Cost notes

- Compute cluster is **$0 while idle** (scales to 0 nodes).
- Ongoing floor: ACR Standard, Key Vault, App Insights ingestion, Storage — cents/day.
- An online endpoint holds **1× Standard_DS2_v2 always-on** while deployed — the biggest
  running cost. Delete it when not demoing.

## Teardown

```powershell
az ml online-endpoint delete -n dam-mcp-endpoint --yes   # stop endpoint cost only
az group delete --name rg-energy-mlops --yes --no-wait   # remove EVERYTHING
```
