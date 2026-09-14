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

The wizard selects configured canons, writes and displays `task-request.json`, displays the plan, then separately confirms copying `PRD.md` and applying worktree creation.

## Guardrails

- Prepare the PRD before starting.
- Stop on any blocked plan operation.
- Do not use canons for mutations.
