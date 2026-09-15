---
name: workspace-folders
description: Update reviewed VS Code workspace folders.
version: 0.1.0
author: Michal (starigazdam), Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [vscode, workspace, tasks]
    related_skills: []
---

# Workspace Folders

Use to add reviewed task worktrees to a VS Code workspace.

## Plan

```powershell
./scripts/Update-WorkspaceFolders.ps1 -WorkspaceFile <workspace.code-workspace> -FoldersJson <folders-json>
```

Review `ProposedContent` and `OriginalSha256`.

## Apply

```powershell
./scripts/Update-WorkspaceFolders.ps1 -WorkspaceFile <workspace.code-workspace> -FoldersJson <folders-json> -Apply -ExpectedSha256 <reviewed-sha256>
```

The script is add-only, preserves JSONC content, and refuses a changed workspace hash.
