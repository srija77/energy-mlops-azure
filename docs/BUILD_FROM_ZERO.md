# Build the stack from zero

How the day-ahead price forecasting stack serves a prediction and ships a change,
then every command to rebuild it from an empty Azure subscription.

Commands are PowerShell (backtick continuations, `$var` assignment, no stdin
pipes). Differences that bite in bash are called out.

- [Part I — How it works](#part-i--how-it-works)
- [Part II — Build it from zero](#part-ii--build-it-from-zero)
- [Failures we actually hit](#failures-we-actually-hit)
- [Teardown](#teardown)

---

# Part I — How it works

Two paths run through this system: one carries a request to a prediction, the
other carries a commit to production. They meet at the model registry.

## The serving path — one prediction

1. A browser hits the **Container App**, the public front door.
2. The app renders a form of **37 features** in six groups, generated from the
   model's real request contract so the column order cannot drift.
3. You submit. The app validates each field and names the offending one if it is
   wrong.
4. It builds the payload in the model's **declared column order** — never
   dictionary order, because the endpoint scores a reordered list silently and
   wrongly.
5. It calls the **Azure ML endpoint** over HTTPS with a key resolved from **Key
   Vault** at startup via managed identity. The key is in neither the image nor
   the template.
6. The endpoint runs `score.py`, loads the **champion** model version, and
   returns a price.
7. The app renders the result. `score.py` also writes the features and
   prediction to the **data collector**, which feeds the drift monitor.

> **Why liveness and readiness are separate endpoints.** `/health` makes no
> outbound call; `/ready` checks configuration. If liveness called the model, an
> endpoint outage would make the platform restart every healthy replica —
> turning a partial outage into a total one.

## The delivery path — two pipelines, one gate

**`mlops.yml` — the model (~15 min)**

1. `ci` — lint and unit tests. No cloud resources.
2. `train` — submits the Azure ML pipeline and streams it. A failed data or
   evaluation gate fails the build, so bad data cannot reach deploy.
3. `deploy` — resolves the `champion=true` *tag* to a version number, rolls it
   to the endpoint, smoke-tests.
4. `monitor` — creates or refreshes the daily drift schedule.

**`app.yml` — the app (~3 min)**

1. `test` — lint, unit tests, and a schema drift check that regenerates the
   feature contract and fails on any diff.
2. `build` — builds the image and pushes to the registry tagged with the
   *commit SHA*.
3. `deploy` — preflights the Key Vault secret, deploys via Bicep, then
   smoke-tests the live URL end to end.

> **Why two.** A retrain takes 15 minutes; an app change takes 3. Path filters
> keep each pipeline on its own changes, so a stylesheet tweak never waits on a
> training run. Both pause at the same `production` approval gate — automate the
> work, gate the consequence. Tagging images with the commit SHA rather than
> only `latest` is what makes a rollback one command.

---

# Part II — Build it from zero

Assumes you have the repository and an empty Azure subscription. Order matters:
providers before provisioning, secrets before deploys, roles before both.

Set these once and reuse them:

```powershell
$RG="rg-energy-mlops"; $LOC="eastus"; $WS="mlw-energy-forecast"
$SUB="<your-subscription-id>"
```

## 0 — Tools and sign-in

The `ml` extension is not installed by default and nothing else here works
without it.

```powershell
az login
az account set --subscription $SUB
```

```powershell
az extension add -n ml -y
az configure --defaults group=$RG workspace=$WS
```

> ⚠️ **Trap.** Those defaults break `az role assignment` with
> `MissingSubscription`. Whenever you assign a role, clear them first with
> `az configure --defaults group=` and set them back afterwards.

## 1 — Resource providers

Do this before provisioning. Both are unregistered on a fresh subscription and
each failure appears much later, disguised as something else.

```powershell
az provider register -n Microsoft.PolicyInsights
az provider register -n Microsoft.App
az provider show -n Microsoft.PolicyInsights --query registrationState -o tsv
az provider show -n Microsoft.App --query registrationState -o tsv
```

> 🛑 **Cost us.** Without `Microsoft.PolicyInsights`, creating the online
> endpoint fails with `SubscriptionNotRegistered` and leaves the endpoint in a
> **Failed** state that must be deleted and recreated. `Microsoft.App` is
> required for Container Apps.

## 2 — Provision the foundation

One Bicep template creates storage, Key Vault, App Insights, a container
registry, the Azure ML workspace, and a compute cluster.

```powershell
az group create -n $RG -l $LOC
```

```powershell
az deployment group create -g $RG -f infra/main.bicep -p infra/main.bicepparam
```

Read back the generated names — the suffix is derived, not chosen. Capture the
ACR, Key Vault, and Application Insights names; you need all three later.

```powershell
az resource list -g $RG --query "[].{name:name,type:type}" -o table
```

> ⚠️ **Quota.** A trial subscription often has **4 total vCPUs**.
> `Standard_DS2_v2` is 2 vCPU, so one cluster node plus the endpoint's one
> instance fills it exactly. Keep the cluster at `max_instances: 1` and do not
> use `DS3_v2` (4 vCPU) — a single node would consume the entire quota and the
> endpoint would never deploy.

## 3 — Register assets and train

The pipeline starts at raw data, not a hand-uploaded feature file, so Studio can
trace any model back to the source CSVs.

Register the *raw* asset the pipeline actually consumes. Registering a
downstream feature file instead leaves the pipeline with no input at all.

```powershell
az ml environment create -f aml/environment/train-env.yml
az ml compute create -f aml/compute.yml
az ml data create -f aml/data_assets/01_raw_energy.yml
```

Submit the pipeline and follow it — ingest → validate → build_features →
prepare → train → evaluate → promote → reference_data, roughly 15 minutes.

```powershell
$JOB = az ml job create -f aml/pipeline.yml --query name -o tsv
az ml job stream -n $JOB
```

Confirm exactly one version carries the champion tag.

```powershell
az ml model list --name dam_mcp_forecast `
  --query "[?tags.champion=='true'].{version:version,rmse:tags.eval_rmse}" -o table
```

> ✅ **Expected.** A later version can register without becoming champion.
> Promotion requires a *strictly* better score, so a tie leaves the incumbent in
> place. That is the gate working, not a failure.

## 4 — The scoring endpoint

Azure runs the web server, TLS, health probes, and rolling deploys.

Create the endpoint — a few minutes, and it consumes no vCPU.

```powershell
az ml online-endpoint create -f aml/endpoints/endpoint.yml
```

Resolve the champion tag to a concrete version, then deploy it (~8 minutes,
while Azure builds a scoring image and starts the container).

```powershell
$V = az ml model list --name dam_mcp_forecast `
  --query "[?tags.champion=='true'].version | [0]" -o tsv
az ml online-deployment create -f aml/endpoints/deployment.yml `
  --set model=azureml:dam_mcp_forecast:$V --all-traffic
```

> 🛑 **Cost us.** Do **not** write `azureml:dam_mcp_forecast@champion`. Azure
> ML's workspace registry does not implement the MLflow alias API and returns
> **HTTP 404**. The champion pointer is a *tag*, and CD must resolve it to a
> version number. Separately, the scoring environment needs
> `azureml-contrib-services` — without it the container crashes at boot with
> `ModuleNotFoundError: azureml.contrib`.

Smoke-test it. Inspect the body, not just the exit code — the scoring script
returns errors with HTTP 200.

```powershell
az ml online-endpoint invoke -n dam-mcp-endpoint --request-file scoring/sample_request.json
```

## 5 — Telemetry and drift

The monitor compares live traffic against the training baseline. It needs
collected inference data, which needs a write permission.

Azure grants the endpoint *Reader* on the storage account automatically.
Collection needs write.

```powershell
az configure --defaults group=
$PID = az ml online-endpoint show -n dam-mcp-endpoint -g $RG -w $WS `
  --query identity.principal_id -o tsv
$STG = az ml workspace show -n $WS -g $RG --query storage_account -o tsv
az role assignment create --assignee-object-id $PID `
  --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Contributor" --scope $STG
az configure --defaults group=$RG workspace=$WS
```

Create the daily drift schedule.

```powershell
az ml schedule create -f aml/monitoring.yml `
  --set create_monitor.alert_notification.emails[0]=you@example.com
```

> ⚠️ **Expect.** The monitor reports **"no production data"** until roughly a
> day of traffic accumulates. That is inherent to the daily rollup, not a
> misconfiguration. Also: the compute `runtime_version` must be `"3.4"`; Azure
> rejects anything else outright.

## 6 — Key Vault

The endpoint key goes in Key Vault so it never appears in an image, a template,
or a CI log.

Grant yourself data-plane access to the vault.

```powershell
az configure --defaults group=
$OID = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee-object-id $OID --assignee-principal-type User `
  --role "Key Vault Secrets Officer" `
  --scope $(az keyvault show -n <KV> --query id -o tsv)
az configure --defaults group=$RG workspace=$WS
```

> 🛑 **Cost us.** **Owner is not enough.** On an RBAC-enabled vault, Owner and
> Contributor are *management-plane* roles and grant no access to secret values.
> A principal that can create the whole resource group still cannot read one
> secret. Use `--assignee-object-id`, not an email — a guest account's real UPN
> is the `#EXT#` form and lookup by email fails.

Store the endpoint key. Two lines in PowerShell — there is no stdin pipe, so the
bash `--value @-` idiom does not work here. The name must be exactly
`aml-endpoint-key`; the Bicep template and the workflow both look it up by that
name.

```powershell
$key = az ml online-endpoint get-credentials -n dam-mcp-endpoint `
  -g $RG -w $WS --query primaryKey -o tsv
az keyvault secret set --vault-name <KV> -n aml-endpoint-key --value $key
```

## 7 — Containerise

Two-stage build, non-root, no ML libraries — the model runs on Azure ML, so the
image stays around 280 MB instead of 1.2 GB.

Build. The context is the repo **root**, not the app folder.

```powershell
docker build -f app/Dockerfile -t dam-mcp-app:v1 --build-arg APP_REVISION=v1 .
```

Run it locally against the live endpoint before pushing anything.

```powershell
cp .env.example .env    # paste the scoring URI and key
docker compose up --build
curl http://localhost:8000/health
```

Tag and push to the registry.

```powershell
az acr login -n <ACR>
$SERVER = az acr show -n <ACR> --query loginServer -o tsv
docker tag dam-mcp-app:v1 $SERVER/dam-mcp-app:v1
docker push $SERVER/dam-mcp-app:v1
```

> 🛑 **Cost us.** `az acr build` does **not** work on every subscription — ACR
> Tasks can return `TasksOperationsNotAllowed`, with no way to enable it short
> of a support request. Build locally or on the CI runner with buildx and push.
> Do not design the pipeline around `az acr build`.

## 8 — Deploy the app

Container Apps, with a user-assigned identity that pulls the image and reads the
secret.

```powershell
$URI = az ml online-endpoint show -n dam-mcp-endpoint --query scoring_uri -o tsv
az deployment group create -g $RG -f infra/app.bicep `
  -p acrName=<ACR> keyVaultName=<KV> appInsightsName=<APPI> `
     amlEndpointUrl=$URI imageTag=v1 `
  --query properties.outputs.appUrl.value -o tsv
```

Verify the whole chain — app, identity, vault, endpoint, model.

```powershell
curl $APPURL/health
curl $APPURL/ready
curl -X POST $APPURL/api/predict -H "Content-Type: application/json" `
  -d $(curl -s $APPURL/api/sample)
```

> ✅ **Check.** Confirm the secret resolves from the vault rather than being
> stored literally: `az containerapp secret list -n <APP> -g <RG>` should show a
> `keyVaultUrl`, not a value.

## 9 — Git

Nothing automates until the code is in a repository the runner can read.

```powershell
git rev-parse --show-toplevel    # fails = not a repo yet
git init -b main
git remote add origin https://github.com/<USER>/<REPO>.git
```

Exclude generated trees and local secrets before the first commit. Both should
report a matching rule.

```powershell
git check-ignore -v .env aml/ui_components/x
```

Commit on a branch, then merge when you choose — pushing `main` triggers
everything.

```powershell
git checkout -b feat/inference-layer
git add -A
git commit -m "Complete the inference layer"
git push -u origin feat/inference-layer
```

> 🛑 **Public repo.** Before the first push, grep your changes for real
> identifiers: personal email addresses, the resource-name suffix, subscription
> ids, app hostnames. Committed alert emails and vault names are the two that
> slip through most easily.

## 10 — Wire up CI/CD

One service principal, four variables, one approval gate. None of it lives in
the repository.

Create the deploy identity and store it as a secret without it touching your
screen.

```powershell
az configure --defaults group=
$creds = az ad sp create-for-rbac --name "gh-energy-mlops" --role Owner `
  --scopes /subscriptions/$SUB/resourceGroups/$RG --json-auth
$creds | gh secret set AZURE_CREDENTIALS --repo <USER>/<REPO>
az configure --defaults group=$RG workspace=$WS
```

> 🛑 **Cost us.** **Owner, not Contributor.** The app template creates two role
> assignments, and Contributor excludes `Microsoft.Authorization/*/Write`. Scope
> it to the one resource group so the blast radius stays there.

Give that principal data-plane read on the vault — Owner does not cover it. Skip
this and the deploy job fails preflight on a secret that exists perfectly well.

```powershell
az configure --defaults group=
$SPID = az ad sp list --display-name "gh-energy-mlops" --query "[0].id" -o tsv
az role assignment create --assignee-object-id $SPID `
  --assignee-principal-type ServicePrincipal --role "Key Vault Secrets User" `
  --scope $(az keyvault show -n <KV> --query id -o tsv)
az configure --defaults group=$RG workspace=$WS
```

Set the four repository variables. Variables, not secrets — resource names are
not sensitive, and visible values make a failed run diagnosable.

```powershell
gh variable set ACR_NAME         --repo <USER>/<REPO> --body "<ACR>"
gh variable set KEYVAULT_NAME    --repo <USER>/<REPO> --body "<KV>"
gh variable set APPINSIGHTS_NAME --repo <USER>/<REPO> --body "<APPI>"
gh variable set ALERT_EMAIL      --repo <USER>/<REPO> --body "you@example.com"
```

Create the approval gate. In the browser instead:
**Settings → Environments → New environment → `production` → Required reviewers**.

```powershell
$uid = gh api user --jq .id
$body = @{ reviewers = @(@{ type = "User"; id = [int]$uid }) } | ConvertTo-Json -Depth 5
$body | gh api --method PUT "repos/<USER>/<REPO>/environments/production" --input -
```

Verify all three before pushing.

```powershell
gh secret list   --repo <USER>/<REPO>
gh variable list --repo <USER>/<REPO>
gh api "repos/<USER>/<REPO>/environments" --jq ".environments[].name"
```

## 11 — First run

Merging to `main` triggers both pipelines. Each stops for your approval before
touching production.

```powershell
git checkout main
git merge feat/inference-layer
git push origin main
```

Watch both runs.

```powershell
gh run list --repo <USER>/<REPO> --limit 5
gh run view <RUN_ID> --repo <USER>/<REPO> --log-failed
```

Approve each deploy when it pauses: **Actions → the run → Review deployments →
Approve and deploy**. Everything before this point is automatic; this is the one
human decision.

> ⚠️ **Verify locally first.** A CI failure costs a full round trip. Reproduce
> the lint-and-test job in the same image the runner uses before pushing:
>
> ```bash
> docker run --rm -v "$PWD:/w" -w /w python:3.10-slim bash -c \
>   "pip install -q -r environment/requirements.txt pytest ruff && \
>    ruff check src/ tests/ && pytest tests/ -q"
> ```

---

# Failures we actually hit

Every one of these was silent until the exact moment it was not.

| Symptom | Real cause | Fix |
|---|---|---|
| `SubscriptionNotRegistered` creating the endpoint | Provider not registered | `az provider register -n Microsoft.PolicyInsights`, then delete the Failed endpoint and recreate |
| Deploy returns **404** on the model | Azure ML has no MLflow alias API | Resolve the `champion=true` tag to a version number |
| Scoring container crash-loops at boot | `ModuleNotFoundError: azureml.contrib` | Add `azureml-contrib-services` to the scoring environment |
| Monitor rejected on create | Unsupported runtime | `runtime_version: "3.4"` |
| `az role assignment` says `MissingSubscription` | CLI defaults injecting a scope | `az configure --defaults group=`, assign, then restore |
| `ForbiddenByRbac` reading a secret you own | Owner is management-plane only | Grant *Key Vault Secrets Officer* (you) / *Secrets User* (CI) |
| CI: "secret not found" but it exists | 403 misreported as 404 | Grant the principal vault read; never swallow stderr in a preflight |
| `ResolutionImpossible` on pip install | `mlflow` pinned above what `azureml-mlflow` allows | Match the CI pins to the job environment exactly |
| `TasksOperationsNotAllowed` | ACR Tasks unavailable on the subscription | Build with buildx locally or on the runner |
| Endpoint deploy fails on quota | Endpoint quota is separate from cluster quota | Keep the cluster at 1 node of `DS2_v2` |

---

# Teardown

Two things bill by the hour. Delete them when you are done; the rest scales to
zero.

```powershell
az containerapp delete -n <APP> -g $RG --yes
az ml online-endpoint delete -n dam-mcp-endpoint --yes
```

Everything, when the demo is over:

```powershell
az group delete -n $RG --yes --no-wait
```

> ✅ **Safe to leave.** The compute cluster scales to zero when idle and costs
> nothing between runs. The registry, vault, and storage are negligible. It is
> the always-on endpoint and container app that add up.

---

*Order matters: providers before provisioning, secrets before deploys, roles
before both.*
