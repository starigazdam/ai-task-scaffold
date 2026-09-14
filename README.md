# ai-task-scaffold

Local-first PowerShell tooling for deterministic multi-repository task workspaces.

## Target workspace layout

```text
<workspace-root>/
  task-scaffold.settings.json
  canons/<repo>/
  tasks/<TASK-KEY>/
    task.json
    PRD.md
    PLAN.md
    STATUS.md
    artifacts/
    worktrees/<repo>/
```

`canons/` contains clean, shared base clones on their configured target branches. Task changes happen only in `tasks/<TASK-KEY>/worktrees/<repo>/`.

## Commands

- `scripts/Invoke-TaskRequestBuilder.ps1` — interactively suggests configured `canons/` repositories, shows the full request, and writes `task-request.json` only after confirmation; it never applies task state.
- `scripts/Invoke-TaskScaffold.ps1` — validate a request, produce a deterministic plan, then create/reuse task state and worktrees only with `-Apply`.
- `scripts/Invoke-TaskTeardown.ps1` — plan or, only with `-Apply`, remove clean registered task worktrees and their task directory; it leaves branches and canons intact.
- `scripts/Update-WorkspaceFolders.ps1` — separately propose or SHA-gated apply add-only VS Code workspace entries.

## Request builder settings

Place `task-scaffold.settings.json` at the workspace root. Only canon directories with an explicit repository entry are offered; their `baseBranch` is copied into the reviewable request.

```json
{
  "schemaVersion": 1,
  "repositories": {
    "api": { "baseBranch": "develop" },
    "web": { "baseBranch": "main" }
  },
  "workspace": { "file": "team.code-workspace" }
}
```

Run the builder from PowerShell, review the printed JSON, and answer `y` to write it. It creates no task directory or worktree:

```powershell
./scripts/Invoke-TaskRequestBuilder.ps1 -WorkspaceRoot C:/work/product
```

The repository is local-only; it intentionally has no remote. Run the offline suite with:

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"
```
