---
name: task-request-builder
description: Build a reviewed task request from configured canons.
version: 0.1.0
author: Michal (starigazdam), Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [tasks, requests, canons]
    related_skills: []
---

# Task Request Builder

Use when a reviewed request is needed without creating task state.

## Run

```powershell
./scripts/Invoke-TaskRequestBuilder.ps1 -WorkspaceRoot <workspace-root>
```

The script reads `<workspace-root>/task-scaffold.settings.json`, offers configured `canons/` entries, prints the JSON, and writes `task-request.json` only after confirmation.

## Guardrails

- It refuses to overwrite an existing request.
- It does not create worktrees or task folders.
