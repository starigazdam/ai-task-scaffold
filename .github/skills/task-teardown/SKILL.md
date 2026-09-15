---
name: task-teardown
description: Plan or remove clean task-local Git worktrees safely.
version: 0.1.0
author: Michal (starigazdam), Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [tasks, git, teardown]
    related_skills: []
---

# Task Teardown

Use after a task is complete and its worktrees are clean.

## Plan

```powershell
./scripts/Invoke-TaskTeardown.ps1 -TasksRoot <tasks-root> -TaskKey <task-key>
```

Review all operations. Stop on `blocked`.

## Apply

```powershell
./scripts/Invoke-TaskTeardown.ps1 -TasksRoot <tasks-root> -TaskKey <task-key> -Apply
```

The script removes only registered clean task worktrees and their task directory. It never removes branches or canons.
