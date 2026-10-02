---
name: task-worktree-plan
description: Plan or apply task-local Git worktrees from a request.
version: 0.1.0
author: Michal (starigazdam), Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [tasks, git, worktrees]
    related_skills: []
---

# Task Worktree Plan

Use with an explicit reviewed `task-request.json`.

## Plan

```powershell
./scripts/Invoke-TaskScaffold.ps1 -RequestPath <request.json> -TasksRoot <tasks-root>
```

Review every operation. Stop if any operation is `blocked`.

## Apply

```powershell
./scripts/Invoke-TaskScaffold.ps1 -RequestPath <request.json> -TasksRoot <tasks-root> -Apply
```

`-Apply` creates only task-local state and worktrees. For a new task it copies an available source PRD as `PRD.md`, or creates a headed starter when the source is blank or missing. For an existing task it preserves the current PRD and collision checks. It never changes a canon.
