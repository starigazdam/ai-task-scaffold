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

`-Apply` creates only task-local state and worktrees. It copies the source PRD as `PRD.md` and never changes a canon.
