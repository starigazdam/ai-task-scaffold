# ai-task-scaffold

Local-first PowerShell tooling for deterministic multi-repository task workspaces.

## Target workspace layout

```text
<workspace-root>/
  task-scaffold.settings.json
  canons/<repo>/
  tasks/<TASK-KEY>/
    task.json
    .ctx
    PRD.md
    PLAN.md
    STATUS.md
    artifacts/
    worktrees/<repo>/
```

`canons/` contains clean, shared base clones on their configured target branches. Task changes happen only in `tasks/<TASK-KEY>/worktrees/<repo>/`.

## Commands

- `scripts/Start-TaskScaffold.ps1` — terminal wizard: accepts an optional PRD source, lets you navigate and check canon repositories, previews the request and worktree plan, then separately confirms the PRD action and scaffold apply.
- `scripts/Invoke-TaskRequestBuilder.ps1` — interactively suggests configured `canons/` repositories, shows the full request, and writes `task-request.json` only after confirmation; it never applies task state.
- `scripts/Invoke-TaskScaffold.ps1` — validate a request, produce a deterministic plan, then create/reuse task state and worktrees only with `-Apply -ExpectedPlanIdentity <identity>`.
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

## Resolved profile contract

The request builder emits `schemaVersion: 2`. The scaffold continues to accept version-1 requests and normalizes them internally as version 2 with no requested profiles. Version-2 callers may omit `profiles` or provide an ordered list of resolved profile roots:

```json
{
  "schemaVersion": 2,
  "task": { "key": "FEATURE-123", "title": "Add endpoint" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "main", "branch": "feature/FEATURE-123" }
  ],
  "profiles": [
    { "name": "team", "path": "C:/work/ai-tools/profiles/team" },
    { "name": "dotnet", "path": "C:/work/ai-tools/profiles/dotnet" }
  ]
}
```

Each profile name must be unique and each path must be an absolute path to an existing directory containing `AGENTS.md`. Skills are optional; when `.agents/skills` exists, each entry must be a skill directory containing `SKILL.md`. Profile order is preserved. Duplicate normalized paths and the reserved `task-scaffold` name are rejected.

The scaffold appends its own `agent-profile/` as `task-scaffold`. Dry-run reports requested, injected, and effective profiles. Apply persists effective `{name, path}` entries in `tasks/<TASK-KEY>/task.json`; legacy manifests without profiles are treated as pre-profile tasks and gain the field when applied. Profile names and order are task identity. If an existing task has the same names/order but different resolved paths, dry-run reports path drift and apply stops pending reconciliation.

### Reconciling profile path drift

When dry-run reports profile path drift, apply fails with a `reconciliation is required` error before any mutation; the scaffold never retargets an existing task's profile path automatically. The supported recovery is exact manual reconciliation followed by a fresh plan and approval:

1. Edit `tasks/<TASK-KEY>/task.json` and change the affected profile's `path` to the new resolved path, preserving each profile's `name` and its position in the ordered `profiles` list.
2. Re-run the dry-run and confirm `ProfilePathDrift` is empty and `ProfileIdentityMatches` is `true`.
3. Apply with the freshly issued `PlanIdentity`:

```powershell
$plan = ./scripts/Invoke-TaskScaffold.ps1 -RequestPath ./task-request.json -TasksRoot ./tasks | ConvertFrom-Json
./scripts/Invoke-TaskScaffold.ps1 -RequestPath ./task-request.json -TasksRoot ./tasks -Apply -ExpectedPlanIdentity $plan.PlanIdentity
```

When a workspace file is supplied, the plan proposes `[AI] <name>` folders pointing to the original profile roots, alongside task worktrees. Workspace changes remain a separate add-only, hash-gated operation. The scaffold also plans `.ctx` from the ordered effective profiles, with exactly one existing-format `name:path` entry per profile. Dry-run reports the target and content without creating it; `-Apply` creates or reconciles the file. No `home:` directive is generated. Task-scaffold does not invoke `ctx` or activate CLI profiles; ctx consumes the persisted effective profile list later.

## Reviewed Plan Identity

Run `Invoke-TaskScaffold.ps1` without `-Apply` to receive the complete deterministic plan and its opaque `PlanIdentity` (a SHA-256 digest). To apply that exact reviewed plan, pass the identity back through the public script interface:

```powershell
$plan = ./scripts/Invoke-TaskScaffold.ps1 -RequestPath ./task-request.json -TasksRoot ./tasks | ConvertFrom-Json
./scripts/Invoke-TaskScaffold.ps1 -RequestPath ./task-request.json -TasksRoot ./tasks -Apply -ExpectedPlanIdentity $plan.PlanIdentity
```

The identity covers the normalized request, the generated plan, task-owned state, profile instructions and skills, repository refs and planned worktree identity, workspace input, and scaffold scripts/templates. Apply checks the expected identity before locking and rechecks under the mutation lock immediately before task or worktree mutations. If any covered input differs, apply fails and requires a fresh plan and approval. `-Apply` without `-ExpectedPlanIdentity` is rejected; legacy schema-version-1 requests remain supported.

Run the full terminal wizard from PowerShell. Enter the task key and title, then provide an optional PRD path; leave it blank to create a starter. Repository selection is the final input step. Use **Up/Down** to navigate, **Space** to check/uncheck, then **Enter** to continue. If the supplied source is missing, the wizard reports that it will create the starter instead. It shows the request and scaffold plan, then asks once more before copying or creating `PRD.md` and creating task/worktree state:

```powershell
./scripts/Start-TaskScaffold.ps1 -WorkspaceRoot C:/work/product
```

`Terminal.Gui` 1.17.1 and its `NStack.Core` 1.1.1 dependency are restored from NuGet using the committed `packages.lock.json`; DLLs are not committed.

Restore the exact locked dependencies before using the picker or running its tests:

```powershell
./scripts/Restore-TaskScaffoldDependencies.ps1
pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -CI -Output Detailed"
```

The repository is published on GitHub; local-first operation does not require network access after dependencies are restored.
