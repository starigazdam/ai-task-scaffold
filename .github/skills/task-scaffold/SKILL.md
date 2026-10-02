---
name: task-scaffold
description: Run the interactive local task scaffold wizard.
version: 0.1.0
author: Michal (starigazdam), Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [tasks, git, worktrees]
    related_skills: []
---

# Task Scaffold

Use for a new local multi-repository task.

## Prerequisite

```powershell
./scripts/Restore-TaskScaffoldDependencies.ps1
```

## Run

```powershell
./scripts/Start-TaskScaffold.ps1 -WorkspaceRoot <workspace-root>
```

The wizard collects the task details, then selects configured canons as its final input step. A PRD source is optional: a blank or missing source creates a headed starter `PRD.md`. The wizard writes and displays `task-request.json`, displays the plan, then separately confirms the PRD action and worktree creation.

## Guardrails

- Review whether the plan copies a source PRD or creates a starter; fill in the starter before implementation.
- Stop on any blocked plan operation.
- Do not use canons for mutations.
