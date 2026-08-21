# Documentation — start here

## 👉 Running the demo? Read **one** document:

# [DEMO_GUIDE.md](DEMO_GUIDE.md)

That is the complete, self-contained runbook: empty subscription → resource group →
workspace → compute → data → pipeline → model → endpoint → CI/CD → teardown.
Every step is a portal click path or a copy-paste command, with expected output
and what to say. **You do not need anything else on this page to run the demo.**

---

## Everything else, and when to read it

| Document | Read it when | Length |
|---|---|---|
| **[DEMO_GUIDE.md](DEMO_GUIDE.md)** | **You are giving the demo.** The only one you need. | 13 parts |
| [BUILD_FROM_ZERO.md](BUILD_FROM_ZERO.md) | You are rebuilding the stack from an empty subscription, or want the one command for a single step | 12 phases |
| [ARCHITECTURE.md](ARCHITECTURE.md) | You want the local-stack → Azure-service mapping, and the data flow diagram | short |
| [01_PROVISIONED_RESOURCES.md](01_PROVISIONED_RESOURCES.md) | You need the live resource inventory, quota limits, or the teardown commands | short |

## Teaching modules — the *why* behind each pipeline stage

Read these to **prepare** for teaching, not during the demo. Each explains the Azure
concept, what it replaced from the local project, and ends with questions to ask a class.

| Module | Topic | Key idea |
|---|---|---|
| [02 — Data plane](module_02_data_plane.md) | Datastores, Data Assets, versioning | A data asset holds the *address* of data plus a version — Azure's `.dvc` file |
| [03 — Ingestion](module_03_ingestion.md) | Components, code snapshots, environments, `.amlignore` | Scraping belongs in a landing job, never in a training pipeline |
| [04 — Validation](module_04_validation.md) | Expectation suites, the quality **gate** | A failed expectation must *fail the job*, because a failed job stops the pipeline |
| [05 — Features](module_05_features.md) | Data Assets vs. a real feature store | A feature store that is never called is decoration; here's when you actually need one |

Modules 6–9 (training/registry, promotion, serving, monitoring/CI-CD) are covered
practically in DEMO_GUIDE Parts 10–12; standalone write-ups are not yet written.

---

## Removed on purpose

`00_CONSOLE_RUNBOOK.md`, `00_PORTAL_RUNBOOK.md`, `RUNBOOK.md`, and `00_CONSOLE_DEMO.md`
were deleted. They predated the raw-data pipeline and actively contradicted the
current system — they described "ingestion skipped" (the pipeline used to start from a
hand-uploaded parquet) and a `@champion` alias that **Azure ML does not support**.
Following them would have led you into two failures we already fixed.
They remain in git history if you need them.

**Not to be confused with [BUILD_FROM_ZERO.md](BUILD_FROM_ZERO.md)**, which is new and
current. It deliberately does *not* reuse the old `RUNBOOK.md` filename, so that a
search for the deleted document cannot surface the replacement and vice versa.
