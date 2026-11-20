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
