# GitHub Actions Monitoring & Troubleshooting Guide

This document provides a concise reference for monitoring and troubleshooting GitHub Actions workflow runs in the `LVKinyanjui/Llama-Cpp-CUDA-Builder` repository using the GitHub CLI (`gh`).

---

## Prerequisites

Ensure you have the GitHub CLI installed and authenticated with `repo` and `workflow` scopes:
```bash
gh auth status
```

---

## Monitoring Active and Recent Runs

### 1. List Recent Workflow Runs
To see a summary of recent runs across all workflows:
```bash
gh run list --limit 10
```
To filter by a specific workflow file:
```bash
gh run list --workflow="cuda-t4-release-turboquant.yml" --limit 5
gh run list --workflow="cuda-t4-release-llama-cpp.yml" --limit 5
```

### 2. View Run Status and Details
To inspect the overall status, jobs, and step breakdown of a specific run ID:
```bash
gh run view <RUN_ID>
```

### 3. Stream or Watch a Running Job
To poll a run until it completes (useful for active monitoring):
```bash
gh run watch <RUN_ID>
```

---

## Inspecting Logs and Troubleshooting Failures

### 1. View Summary of a Specific Job
Each run consists of jobs (e.g., `plan`, `build`, `release`). To view a specific job's structure:
```bash
gh run view --job=<JOB_ID>
```

### 2. Stream Full Logs for a Completed or Failing Run
If a run fails, view the full logs directly in your terminal:
```bash
gh run view <RUN_ID> --log
```
To view logs for *only* failed steps:
```bash
gh run view <RUN_ID> --log-failed
```

---

## Triggering Manual Builds

If you need to manually trigger a build (e.g. to test a branch/tag or force a rebuild):
```bash
gh workflow run cuda-t4-release-turboquant.yml --ref main -f force=true
gh workflow run cuda-t4-release-llama-cpp.yml --ref main -f force=true
```

---

## Operating Procedures & Workflow Gotchas

### 1. Rebuilding or Adding Matrix Targets (`force=true`)
- **The Issue:** `plan.sh` checks if the release tag (`$TAG`) already exists. If it exists and `force` is `false`, it skips the source entirely to avoid redundant work.
- **The Consequence:** If you add a new target (e.g., adding Ubuntu 24.04 / CUDA 13.0 to an existing day's tag) or modify build flags without changing the commit SHA, running the workflow without `force=true` will result in an empty matrix (`[]`) and nothing will be built or added.
- **The Rule:** Always check `force=true` when manually dispatching a run to update an existing tag or alter matrix dimensions for an already-released commit.

### 2. Scheduled Biweekly Runs & Idempotency
- **Will scheduled runs fail?** **No.** Scheduled runs (`cron: "17 4 * * 1,4"`) always evaluate against the *latest upstream commit/tag* at that exact moment.
  - For **llama.cpp**: The cron runs on Monday/Thursday. If upstream tagged a new `bNNNN` version since the last run, `$TAG` will be *new* (e.g., `llama-cpp-b12541`), so `plan.sh` will not skip it. If upstream has *not* tagged a new version, `$TAG` already exists, `plan.sh` will gracefully skip, and no redundant runner minutes or duplicate releases will be consumed.
  - For **TurboQuant**: The cron checks the HEAD of `feature/turboquant-kv-cache` and computes the tag based on the commit date and SHA (e.g., `turboquant-20261111-4185b90`). Unless commits landed on that branch on a Monday or Thursday, `$TAG` will already exist, and the scheduled run will safely skip. When new commits *do* land, the SHA/date changes, producing a new unique tag, so the build and release proceed automatically without failure.
