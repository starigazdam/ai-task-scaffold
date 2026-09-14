---
name: task-scaffold
description: "Plan or explicitly create a local task folder and safe Git worktrees from task-request.json. Use when a user supplies a PRD, ticket, or asks to start multi-repository work."
argument-hint: "task-request.json path, workspace root, and tasks root"
user-invocable: true
---

# Task Scaffold

## Outcome

`Invoke-TaskScaffold.ps1` is the generic, project-agnostic entry point. It reads an explicit
`task-request.json`, plans local Git worktrees, and optionally creates only local task/worktree
state. It never calls external services, pushes, creates pull requests, or edits a VS Code workspace.

## Request

```json
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Short title", "prdPath": "C:/input/FEATURE-123.md" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "main", "branch": "feature/FEATURE-123" }
  ],
  "workspace": { "file": "C:/work/product.code-workspace" }
}
```

`workspace` is optional. Repository names must be unique. The task key must be filesystem-safe.
Every repository supplies its own branch; there is no global task branch.

## Procedure

1. Confirm the request's repositories, paths, base branches, target branches, PRD, workspace root,
   and tasks root. Do not infer repositories or paths from a PRD.
2. Run plan-only first:

   ```powershell
   $plan = ./scripts/Invoke-TaskScaffold.ps1 `
     -RequestPath ./task-request.json -WorkspaceRoot ./work -TasksRoot ./tasks | ConvertFrom-Json
   $plan | ConvertTo-Json -Depth 8
   ```

3. Stop on any `blocked` worktree operation. Review all `create-*` destinations before applying.
4. Apply only task and worktree state after explicit confirmation:

   ```powershell
   ./scripts/Invoke-TaskScaffold.ps1 `
     -RequestPath ./task-request.json -WorkspaceRoot ./work -TasksRoot ./tasks -Apply
   ```

5. When the request includes `workspace.file`, review `WorkspaceFolderPlan`. It is an add-only
   proposal with `OriginalSha256`; scaffold planning and `-Apply` leave the workspace byte-identical.
   Apply it separately and only after review:

   ```powershell
   $folders = @(
     [ordered]@{ path = './work/worktrees/FEATURE-123/api'; name = '🔧 worktree: FEATURE-123 api' }
   ) | ConvertTo-Json -Compress
   ./scripts/Update-WorkspaceFolders.ps1 `
     -WorkspaceFile ./work/product.code-workspace -FoldersJson $folders -Apply `
     -ExpectedSha256 $plan.WorkspaceFolderPlan.OriginalSha256
   ```

## Output

The scaffold returns JSON containing the task key, task operation, sorted worktree operations, and
an optional `WorkspaceFolderPlan`. Repeated matching requests report existing worktrees as `reuse`.

## Guardrails

- Default is plan-only; `-Apply` is an explicit local-state confirmation.
- Never create a worktree directly or reset, delete, overwrite, or force Git state.
- Never overwrite a task PRD; a task directory with a different PRD is an error.
- Never hand-edit or silently apply a `.code-workspace` change. Only
  `Update-WorkspaceFolders.ps1 -Apply -ExpectedSha256 <reviewed-hash>` may write it.
- Treat task state as local-only. Do not stage, commit, push, or create a PR for it.
