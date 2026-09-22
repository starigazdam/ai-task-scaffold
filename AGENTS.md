# AI Task Scaffold

## Repository shape

- This is a PowerShell 7+ tool for deterministic, local-first task workspaces across multiple Git repositories.
- Public entry points live in `scripts/`; shared domain logic lives in `scripts/Private/`.
- Tests live in `tests/` and use Pester with temporary Git repositories.
- Read [README.md](README.md) for user-facing commands and review the relevant architectural decisions in [docs/adr/](docs/adr/).

## Development rules

- Use PowerShell 7+ (`pwsh`), never Windows PowerShell 5.1. Public scripts require version 7, use `Set-StrictMode -Version Latest`, and set `$ErrorActionPreference = 'Stop'`.
- Preserve the plan-first contract: calculate and emit a plan before mutation; require `-Apply` for task or worktree state changes.
- Keep VS Code workspace-folder updates in `Update-WorkspaceFolders.ps1`; the scaffold only proposes them.
- Treat `schemaVersion: 1` and `ConvertTo-TaskRequest` as the request contract. Validate task keys, repository names, paths, branches, duplicate repositories, and worktree identity before changing state.
- Keep canon repositories clean and on their configured base branches. Task implementation belongs only in `tasks/<TASK-KEY>/worktrees/<repo>`.
- When changing behavior, update or add a focused Pester example that verifies both plan-only and apply behavior where relevant.
- Build JSON test fixtures with objects and `ConvertTo-Json` when they contain filesystem paths; avoid hard-coded newline assumptions and normalize paths emitted by external tools before asserting.
- Keep `.github/skills/` wrappers synchronized with their corresponding scripts when changing a user-facing workflow.

## Validation

Restore the locked Terminal.Gui dependencies before picker-related work or tests:

```powershell
./scripts/Restore-TaskScaffoldDependencies.ps1
```

Run the full suite from the repository root:

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -CI -Output Detailed"
```

Prefer the narrowest relevant Pester file first, then run the full suite before handing off changes. Do not commit generated NuGet DLLs or other dependency-cache output.