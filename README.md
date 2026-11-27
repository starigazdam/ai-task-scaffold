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

## Caller-supplied task files

Schema-version-2 requests may include an optional `taskFiles` array of `{ "path": "<relative path>", "content": "<exact text>" }` descriptors. Each `path` is resolved beneath the task root; `content` is written as UTF-8 without a BOM and with no newline or Unicode normalization.

```json
{
  "schemaVersion": 2,
  "task": { "key": "FEATURE-123", "title": "Add endpoint" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "main", "branch": "feature/FEATURE-123" }
  ],
  "taskFiles": [
    { "path": "AGENTS.md", "content": "Team guidance for this task." },
    { "path": "guidance/rules.md", "content": "Exact content." }
  ]
}
```

Paths must be relative, must not traverse outside the task root, and any symlink/reparse point along an existing segment is rejected. Destinations may not collide with `task.json`, `PRD.md`, `PLAN.md`, `STATUS.md`, `.ctx`, `artifacts/`, or `worktrees/`, nor duplicate or nest within one another. The plan reports `create`, `noop` (byte-identical existing file), or `conflict` for each destination; a conflict blocks apply before any task or worktree mutation, and existing files are never overwritten. The normalized relative path, the content bytes, and the current destination state are bound into `PlanIdentity`, so any drift between plan and apply requires a fresh approval. Applied paths are recorded in `task.json`'s `taskFiles` array so teardown can remove them while still rejecting unrecorded entries. Requests that omit `taskFiles` are unchanged.

### Reconciling profile path drift

When dry-run reports profile path drift, apply fails with a `reconciliation is required` error before any mutation; the scaffold never retargets an existing task's profile path automatically. The supported recovery is exact manual reconciliation followed by a fresh plan and approval:

1. Edit `tasks/<TASK-KEY>/task.json` and change the affected profile's `path` to the new resolved path, preserving each profile's `name` and its position in the ordered `profiles` list.
2. Re-run the dry-run and confirm `ProfilePathDrift` is empty and `ProfileIdentityMatches` is `true`.
3. Apply with the freshly issued `PlanIdentity`:

```powershell
$plan = ./scripts/Invoke-TaskScaffold.ps1 -RequestPath ./task-request.json -TasksRoot ./tasks | ConvertFrom-Json
./scripts/Invoke-TaskScaffold.ps1 -RequestPath ./task-request.json -TasksRoot ./tasks -Apply -ExpectedPlanIdentity $plan.PlanIdentity
```

When a workspace file is supplied, the plan proposes `[AI] <name>` folders pointing to the original profile roots, alongside task worktrees. Workspace changes remain a separate add-only, hash-gated operation. The scaffold also plans `.ctx` from the ordered effective profiles, with exactly one existing-format `name:path` entry per profile. Dry-run reports the target and content without creating it; `-Apply` creates or reconciles the file. No `home:` directive is generated. Task-scaffold does not invoke `ctx` or activate CLI profiles; ctx consumes the persisted effective profile list later. The .NET CLI `task plan`/`task apply` accept optional `--ctx-config-root <dir>` and `--ctx-external-profiles-root <dir>`; when either is supplied the planned `.ctx` starts with `config-root:` and/or `external-profiles-root:` lines followed by the profile entries, all paths relative to the task folder where possible (absolute otherwise), and the roots are validated and bound into `PlanIdentity`. Without them the output is unchanged. `scripts/Invoke-TaskScaffold.ps1` accepts the same optional `-CtxConfigRoot <dir>` / `-CtxExternalProfilesRoot <dir>` parameters with identical validation, content, and `PlanIdentity` binding; it never infers a root from profile paths and never reads or mutates `AI_CTX_PROFILES_CONFIG_ROOT` / `AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT`.

## Explicit start commit

Each repository entry may include an optional `startCommit`. It must be a full lowercase Git object ID: exactly 40 or 64 hex characters. Abbreviated IDs, uppercase IDs, ref names such as `main` or `HEAD`, and empty strings are rejected as input errors. An explicit `startCommit: null` is accepted and means the same as omitting the field; any other JSON type is refused. `baseBranch` stays required and is unchanged.

A relative `repositories[].path` is resolved once against the PowerShell filesystem location, which is also where native `git -C <path>` resolves it, and that one resolved path is used for planning, plan identity, and apply. Existing manifests keep their original raw path value, so previously written relative-path manifests remain usable.

When `startCommit` is set, the scaffold verifies the commit exists locally and does not fetch. A missing commit blocks the plan with `start-commit-missing`. An existing local or `origin` branch for the requested branch must point at that commit, otherwise the plan is blocked with `start-commit-mismatch`. That comparison is an exact full-ref lookup: a tag or another ref with a lookalike name cannot stand in, and a task ref that exists but whose tip cannot be verified locally also blocks with `start-commit-mismatch` instead of falling through to a new branch. Otherwise the branch is created from the commit. Reusing an existing matching worktree is unchanged.

Every plan pins the commit it resolved — including a tracking plan without `startCommit` — and binds that pin into `PlanIdentity`; it stays internal, so the public plan shape is unchanged. Apply creates the branch at the pinned commit rather than at the movable `origin/<branch>` ref, sets the upstream to the full `refs/remotes/origin/<branch>` ref, and verifies the new worktree in order: the branch tip equals the reviewed commit, HEAD's immediate target (read with `symbolic-ref --no-recurse`) is `refs/heads/<branch>`, and the resolved upstream target equals the expected ref. A failed git command or verification stops apply; existing branches and worktrees are not deleted. Because the remote ref is always resolved through its exact full name, neither a local branch named `origin/<branch>` nor a similarly named tag can redirect the start. Planning lookups are read-only: they resolve local objects only and never lazily fetch, and the guard is scoped to those git processes. A Git without `symbolic-ref --no-recurse` fails closed instead of resolving HEAD recursively.

Lookup of missing objects is also guarded on older Git. A detectable partial clone (`extensions.partialClone`, or `remote.<name>.promisor=true`) requires a Git that supports `--no-lazy-fetch` (2.45 or later); otherwise planning fails closed with an actionable diagnostic instead of risking a lazy fetch. Full clones keep their previous behavior on older Git.

When no `startCommit` is supplied and a new branch falls back to a base, the plan also resolves the upstream exactly as native `git worktree add -b <branch> <dest> <base>` would, following `branch.autoSetupMerge`. A remote-tracking base is tracked by default/`true` and `always`, and by `simple` only when the new branch name matches the remote branch name; `false` — and an explicitly empty value, which Git treats as boolean false — tracks nothing. A local base is tracked by `always`, and `inherit` copies that base's own upstream, which may be empty. A symbolic remote base such as `origin/HEAD` tracks the symref's target (for example `refs/remotes/origin/main`), not the symbolic name. That decision is bound into `PlanIdentity` but stays internal, so the public no-pin plan shape is unchanged; changing the config between review and apply invalidates the plan. Apply still starts the branch at the pinned commit and then sets the upstream on the canonical full `refs/heads/<name>` or `refs/remotes/<remote>/<name>` ref.

The .NET CLI plans the worktree operation and binds the same internal pin into its plan identity without changing its plan output; the PowerShell scaffold applies it. The .NET CLI does not create worktrees.

## Reviewed Plan Identity

Run `Invoke-TaskScaffold.ps1` without `-Apply` to receive the complete deterministic plan and its opaque `PlanIdentity` (a SHA-256 digest). To apply that exact reviewed plan, pass the identity back through the public script interface:

```powershell
$plan = ./scripts/Invoke-TaskScaffold.ps1 -RequestPath ./task-request.json -TasksRoot ./tasks | ConvertFrom-Json
./scripts/Invoke-TaskScaffold.ps1 -RequestPath ./task-request.json -TasksRoot ./tasks -Apply -ExpectedPlanIdentity $plan.PlanIdentity
```

The identity covers the normalized request, the generated plan, task-owned state, profile instructions and skills, repository refs and planned worktree identity, workspace input, and scaffold scripts/templates. Apply checks the expected identity before locking and rechecks under the mutation lock immediately before task or worktree mutations. If any covered input differs, apply fails and requires a fresh plan and approval. `-Apply` without `-ExpectedPlanIdentity` is rejected; legacy schema-version-1 requests remain supported.

A destination is never trusted just because it exists. A plan reuses it only when it is a directory, resolves to the same Git common directory, is checked out on the requested branch (HEAD's immediate target is `refs/heads/<branch>`), and the branch tip is a readable local commit; a different destination blocks with `destination-exists` and an unreadable branch tip blocks with `reuse-unreadable`. Apply re-verifies the same properties against the plan: the branch tip must equal the commit the plan reviewed and HEAD's immediate target must be the requested branch. The upstream is the one repairable mismatch: when the branch tip and HEAD target are correct but the expected upstream — the task's `refs/remotes/origin/<branch>` when that ref is readable, otherwise the branch's existing upstream — is missing or different, apply runs `git branch --set-upstream-to=<expected>` and verifies the readback. Any other mismatch fails apply. A retry after an interrupted or failed creation therefore heals: a destination that is complete is reused, and an attach that merely lacks its upstream is repaired instead of stranded; nothing is recorded between attempts. Upstream verification compares the resolved ref target, so a symbolic remote ref (for example `origin/HEAD`, or a symbolic remote task ref) matches the ref it points at. Apply never deletes a branch, worktree, or edit on failure.

`-Apply` runs `git worktree add` in parallel for repositories that have different Git common directories. Set the limit with `AI_TASK_SCAFFOLD_WORKTREE_CONCURRENCY`: an integer from 1 to 8, default 3. Repositories that share one Git common directory stay in serial order, and a limit of 1 keeps the former serial behavior. After the first failure, no new worktree starts, running worktrees finish, and apply reports the first failure by plan order. The limit is not part of `PlanIdentity`.

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
