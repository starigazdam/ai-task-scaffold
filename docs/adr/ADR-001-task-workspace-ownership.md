# ADR-001: Generic task scaffold owns workspace task state

- **Status:** Accepted
- **Date:** 2026-09-14

## Context

Multi-repository tasks need isolated branches and an inspectable task record. Project-specific sprint tooling must not create its own incompatible task layout.

## Decision

`ai-task-scaffold` is a standalone generic repository. A workspace root contains shared clean base clones under `canons/<repo>` and task state under `tasks/<TASK-KEY>/`.

Each task stores its mutable Git worktrees under `tasks/<TASK-KEY>/worktrees/<repo>`. The task manifest records the explicit per-repository branch map. `canons/` is refreshed only to its configured target branches and is not used for task implementation.

The scaffold is plan-first. It writes task/worktree state only with explicit apply. VS Code workspace changes are separately proposed and require a reviewed content hash to apply.

Project-specific repositories, including sprint operations, consume the task manifest and worktree paths. They do not create task folders or worktrees.

## Consequences

- Parallel task isolation is keyed by task directory, not global state or current directory.
- A task can have different branches for different repositories.
- Initial clone provisioning and one-off workspace migration are outside this tool.
- The scaffold creates task worktrees at `tasks/<TASK-KEY>/worktrees/<repo>` from the corresponding canon.
