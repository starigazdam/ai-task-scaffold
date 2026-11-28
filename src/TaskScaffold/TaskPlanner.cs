using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

public sealed class WorktreeOperation
{
    [JsonPropertyName("repository")]
    public string Repository { get; init; } = string.Empty;

    [JsonPropertyName("action")]
    public string Action { get; init; } = string.Empty;

    [JsonPropertyName("source")]
    public string? Source { get; init; }

    [JsonPropertyName("branchMode")]
    public string? BranchMode { get; init; }

    [JsonPropertyName("destination")]
    public string Destination { get; init; } = string.Empty;

    [JsonPropertyName("reason")]
    public string? Reason { get; init; }

    // Only blocked plans carry an actionable detail; a null message keeps the
    // documented plan shape for every planned operation unchanged.
    [JsonPropertyName("message")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Message { get; init; }
}

public sealed class TaskPlan
{
    [JsonPropertyName("taskKey")]
    public string TaskKey { get; init; } = string.Empty;

    [JsonPropertyName("taskOperation")]
    public string TaskOperation { get; init; } = "create";

    [JsonPropertyName("worktreeOperations")]
    public List<WorktreeOperation> WorktreeOperations { get; init; } = new();

    [JsonPropertyName("requiresConfirmation")]
    public bool RequiresConfirmation { get; init; } = true;

    [JsonPropertyName("ctxFile")]
    public CtxFilePlan CtxFile { get; init; } = new();
}

public sealed class CtxRootOptions
{
    public string? ConfigRoot { get; init; }

    public string? ExternalProfilesRoot { get; init; }

    public bool Any => ConfigRoot is not null || ExternalProfilesRoot is not null;

    public static readonly CtxRootOptions None = new();
}

public sealed class TaskPlanResult
{
    [JsonPropertyName("planIdentity")]
    public string PlanIdentity { get; init; } = string.Empty;

    [JsonPropertyName("plan")]
    public TaskPlan Plan { get; init; } = new();

    [JsonIgnore]
    public TaskStatePlanned? State { get; init; }
}

public sealed class CanonicalPlanInput
{
    public int SchemaVersion { get; init; }

    public string TaskKey { get; init; } = string.Empty;

    public string TaskTitle { get; init; } = string.Empty;

    public string? PrdPath { get; init; }

    public string? WorkspaceFile { get; init; }

    public List<CanonicalRepository> Repositories { get; init; } = new();

    public List<CanonicalProfile> Profiles { get; init; } = new();

    public string TasksRoot { get; init; } = string.Empty;

    public List<CanonicalOperation> WorktreeOperations { get; init; } = new();

    public bool TaskExists { get; init; }

    public List<CanonicalFileIdentity> ManagedFiles { get; init; } = new();

    public bool ArtifactsDirectoryExists { get; init; }

    public CanonicalFileIdentity? PrdSource { get; init; }

    public List<CanonicalProfileIdentity> ProfileIdentities { get; init; } = new();

    public List<CanonicalCustomFile> CustomFiles { get; init; } = new();

    public string? CtxConfigRoot { get; init; }

    public string? CtxExternalProfilesRoot { get; init; }

    public string CtxContent { get; init; } = string.Empty;
}

public sealed class CanonicalRepository
{
    public string Name { get; init; } = string.Empty;

    public string Path { get; init; } = string.Empty;

    public string BaseBranch { get; init; } = string.Empty;

    public string Branch { get; init; } = string.Empty;

    public string? StartCommit { get; init; }
}

public sealed class CanonicalProfile
{
    public string Name { get; init; } = string.Empty;

    public string Path { get; init; } = string.Empty;
}

public sealed class CanonicalOperation
{
    public string Repository { get; init; } = string.Empty;

    public string Action { get; init; } = string.Empty;

    public string? Source { get; init; }

    public string? BranchMode { get; init; }

    public string Destination { get; init; } = string.Empty;

    public string? Reason { get; init; }

    public string CommonDir { get; init; } = string.Empty;

    public string Head { get; init; } = string.Empty;

    public string? SourceRef { get; init; }

    public string? SourceCommit { get; init; }

    public string? SourceTarget { get; init; }

    public string? DestinationIdentity { get; init; }
}

public sealed class CanonicalFileIdentity
{
    public string Path { get; init; } = string.Empty;

    public bool Exists { get; init; }

    public string? Sha256 { get; init; }
}

public sealed class CanonicalSkillIdentity
{
    public string Name { get; init; } = string.Empty;

    public CanonicalFileIdentity Skill { get; init; } = new();
}

public sealed class CanonicalProfileIdentity
{
    public string Name { get; init; } = string.Empty;

    public string Path { get; init; } = string.Empty;

    public CanonicalFileIdentity Instructions { get; init; } = new();

    public List<CanonicalSkillIdentity> Skills { get; init; } = new();
}

public sealed class CanonicalDestinationState
{
    public string Path { get; init; } = string.Empty;

    public bool Exists { get; init; }

    public bool IsFile { get; init; }

    public bool IsReparsePoint { get; init; }

    public string? Sha256 { get; init; }
}

public sealed class CanonicalCustomFile
{
    public string Path { get; init; } = string.Empty;

    public string ContentSha256 { get; init; } = string.Empty;

    public CanonicalDestinationState Destination { get; init; } = new();
}

public static class TaskScaffoldPaths
{
    public static ScaffoldPaths Resolve()
    {
        var directory = AppContext.BaseDirectory;
        while (!string.IsNullOrEmpty(directory))
        {
            var agentProfilePath = Path.Combine(directory, "agent-profile");
            var prdTemplatePath = Path.Combine(directory, "templates", "PRD.md");
            if (Directory.Exists(agentProfilePath) && File.Exists(prdTemplatePath))
            {
                return new ScaffoldPaths
                {
                    RepositoryRoot = directory,
                    AgentProfilePath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(agentProfilePath)),
                    PrdTemplatePath = Path.GetFullPath(prdTemplatePath),
                };
            }

            directory = Path.GetDirectoryName(directory);
        }

        throw new OperationalException("could not locate the task scaffold repository root (agent-profile/ and templates/PRD.md)");
    }
}

public sealed class ScaffoldPaths
{
    public string RepositoryRoot { get; init; } = string.Empty;

    public string AgentProfilePath { get; init; } = string.Empty;

    public string PrdTemplatePath { get; init; } = string.Empty;
}

public sealed class PrdOperation
{
    public string Action { get; init; } = string.Empty;

    public string? SourcePath { get; init; }

    public string Destination { get; init; } = string.Empty;

    public string? Reason { get; init; }

    public string? TemplatePath { get; init; }
}

public sealed class ProfilePathDrift
{
    public string Name { get; init; } = string.Empty;

    public string? ExistingPath { get; init; }

    public string RequestedPath { get; init; } = string.Empty;
}

public sealed class TaskProfileState
{
    public bool IdentityMatches { get; init; }

    public List<ProfilePathDrift> PathDrift { get; init; } = new();

    public bool RequiresMigration { get; init; }
}

public sealed class CtxFilePlan
{
    [JsonPropertyName("path")]
    public string Path { get; init; } = string.Empty;

    [JsonPropertyName("action")]
    public string Action { get; init; } = string.Empty;

    [JsonPropertyName("content")]
    public string Content { get; init; } = string.Empty;
}

public sealed class CustomFileOperation
{
    public string Path { get; init; } = string.Empty;

    public string Destination { get; init; } = string.Empty;

    public string Action { get; init; } = string.Empty;

    public string? Reason { get; init; }

    public string ContentHash { get; init; } = string.Empty;
}

public sealed class TaskStatePlanned
{
    public bool TaskExists { get; init; }

    public string TasksRoot { get; init; } = string.Empty;

    public string TaskPath { get; init; } = string.Empty;

    public string ManifestPath { get; init; } = string.Empty;

    public string CtxPath { get; init; } = string.Empty;

    public string CtxContent { get; init; } = string.Empty;

    public List<CanonicalProfile> EffectiveProfiles { get; init; } = new();

    public PrdOperation PrdOperation { get; init; } = new();

    public TaskProfileState ProfileState { get; init; } = new();

    public CtxFilePlan CtxFilePlan { get; init; } = new();

    public List<CustomFileOperation> CustomFileOperations { get; init; } = new();
}

public static class TaskPlanner
{
    private static readonly Regex RemoteQualifiedPattern = new(@"^[^/]+/.+", RegexOptions.CultureInvariant);

    private static readonly Regex ObjectIdPattern = new(@"\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z", RegexOptions.CultureInvariant);

    public static TaskPlanResult Plan(NormalizedRequest request, string tasksRoot, CtxRootOptions ctxRoots)
    {
        string fullTasksRoot;
        try
        {
            fullTasksRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(tasksRoot));
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new InputException($"invalid tasks root '{tasksRoot}'");
        }

        var normalizedCtxRoots = NormalizeCtxRoots(ctxRoots);

        var orderedRepositories = request.Repositories
            .OrderBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(r => r.Name, StringComparer.Ordinal)
            .ToList();

        var planned = new List<PlannedOperation>();
        foreach (var repository in orderedRepositories)
        {
            planned.Add(PlanRepository(request.TaskKey, fullTasksRoot, repository));
        }

        var scaffoldPaths = TaskScaffoldPaths.Resolve();
        var effectiveProfiles = BuildEffectiveProfiles(request, scaffoldPaths.AgentProfilePath);
        var state = TaskStatePlanner.Compute(request, fullTasksRoot, effectiveProfiles, scaffoldPaths.PrdTemplatePath, normalizedCtxRoots);
        var identity = ComputeIdentity(BuildCanonicalInput(request, fullTasksRoot, orderedRepositories, planned, state, normalizedCtxRoots));

        return new TaskPlanResult
        {
            PlanIdentity = identity,
            Plan = new TaskPlan
            {
                TaskKey = request.TaskKey,
                TaskOperation = state.TaskExists ? "reuse" : "create",
                WorktreeOperations = planned.Select(p => p.Operation).ToList(),
                RequiresConfirmation = true,
                CtxFile = state.CtxFilePlan,
            },
            State = state,
        };
    }

    private static CtxRootOptions NormalizeCtxRoots(CtxRootOptions ctxRoots)
    {
        if (ctxRoots is null || !ctxRoots.Any)
        {
            return CtxRootOptions.None;
        }

        return new CtxRootOptions
        {
            ConfigRoot = NormalizeCtxRoot(ctxRoots.ConfigRoot, "ctx config root", requireProfilesDirectory: true),
            ExternalProfilesRoot = NormalizeCtxRoot(ctxRoots.ExternalProfilesRoot, "ctx external profiles root", requireProfilesDirectory: false),
        };
    }

    private static string? NormalizeCtxRoot(string? raw, string label, bool requireProfilesDirectory)
    {
        if (raw is null)
        {
            return null;
        }

        if (raw.IndexOfAny(new[] { '\n', '\r' }) >= 0)
        {
            throw new InputException($"{label} must not contain line breaks: '{raw}'");
        }

        if (string.IsNullOrWhiteSpace(raw) || !Path.IsPathFullyQualified(raw) || !Directory.Exists(raw))
        {
            throw new InputException($"{label} must be an absolute existing directory: '{raw}'");
        }

        var normalized = TaskFileSafety.NormalizeTaskProfilePath(raw);
        if (normalized.IndexOfAny(new[] { '\n', '\r' }) >= 0)
        {
            throw new InputException($"{label} must not contain line breaks: '{normalized}'");
        }

        if (requireProfilesDirectory && !Directory.Exists(Path.Combine(normalized, "profiles")))
        {
            throw new InputException($"{label} must contain a 'profiles' directory: '{normalized}'");
        }

        return normalized;
    }

    private static List<CanonicalProfile> BuildEffectiveProfiles(NormalizedRequest request, string agentProfilePath)
    {
        var effectiveProfiles = request.Profiles
            .Select(p => new CanonicalProfile { Name = p.Name, Path = p.Path })
            .ToList();
        foreach (var profile in effectiveProfiles)
        {
            if (TaskFileSafety.PathComparer.Equals(
                    TaskFileSafety.NormalizeTaskProfilePath(profile.Path),
                    TaskFileSafety.NormalizeTaskProfilePath(agentProfilePath)))
            {
                throw new InputException($"duplicate profile path '{agentProfilePath}'");
            }
        }

        effectiveProfiles.Add(new CanonicalProfile { Name = "task-scaffold", Path = agentProfilePath });
        return effectiveProfiles;
    }

    private static PlannedOperation PlanRepository(string taskKey, string tasksRoot, NormalizedRepository repository)
    {
        if (!IsInsideWorkTree(repository.Path))
        {
            throw new InputException($"repository '{repository.Name}' is not a Git worktree");
        }

        var commonDir = GetCommonDir(repository.Path) ?? string.Empty;
        var head = GetHead(repository.Path) ?? string.Empty;
        var destination = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.Combine(tasksRoot, taskKey, "worktrees", repository.Name)));

        if (HasUnsafePathComponent(tasksRoot, taskKey, repository.Name))
        {
            return new PlannedOperation
            {
                Operation = new WorktreeOperation
                {
                    Repository = repository.Name,
                    Action = "blocked",
                    Destination = destination,
                    Reason = "unsafe-worktree-path",
                },
                CommonDir = commonDir,
                Head = head,
            };
        }

        var startCommit = repository.StartCommit;
        if (startCommit is not null &&
            !string.Equals(ResolveCommit(repository.Path, startCommit), startCommit, StringComparison.Ordinal))
        {
            return Blocked(repository, destination, "start-commit-missing", commonDir, head);
        }

        if (TryGetAttributes(destination, out var destinationAttributes))
        {
            if ((destinationAttributes & FileAttributes.Directory) != 0 && IsMatchingWorktree(repository.Path, destination, repository.Branch, commonDir))
            {
                // Reuse is proved at reuse time: the destination is this
                // repository's worktree, on the requested branch, with a readable
                // branch tip. An unreadable tip blocks instead of reusing blind.
                var reuseRef = $"refs/heads/{repository.Branch}";
                var reuseTip = (Exists: false, Commit: (string?)null);
                try
                {
                    reuseTip = ReadRefTip(repository.Path, reuseRef);
                }
                catch (OperationalException)
                {
                    return Blocked(repository, destination, "reuse-unreadable", commonDir, head);
                }

                if (!reuseTip.Exists || reuseTip.Commit is null)
                {
                    return Blocked(repository, destination, "reuse-unreadable", commonDir, head);
                }

                return new PlannedOperation
                {
                    Operation = new WorktreeOperation
                    {
                        Repository = repository.Name,
                        Action = "reuse",
                        Source = repository.Branch,
                        BranchMode = "existing",
                        Destination = destination,
                        Reason = null,
                    },
                    CommonDir = commonDir,
                    Head = head,
                    SourceRef = reuseRef,
                    SourceCommit = reuseTip.Commit,
                    SourceTarget = ResolveRefTarget(repository.Path, reuseRef),
                    DestinationIdentity = GetGitDir(destination),
                };
            }

            return new PlannedOperation
            {
                Operation = new WorktreeOperation
                {
                    Repository = repository.Name,
                    Action = "blocked",
                    Destination = destination,
                    Reason = "destination-exists",
                },
                CommonDir = commonDir,
                Head = head,
            };
        }

        var requestedLocal = $"refs/heads/{repository.Branch}";
        var requestedRemote = $"refs/remotes/origin/{repository.Branch}";
        if (startCommit is not null)
        {
            var localTip = ReadRefTip(repository.Path, requestedLocal);
            if (localTip.Exists)
            {
                if (localTip.Commit is null || !string.Equals(localTip.Commit, startCommit, StringComparison.Ordinal))
                {
                    return Blocked(repository, destination, "start-commit-mismatch", commonDir, head);
                }

                // Bind the SHA that was just validated.
                return CreateLocal(repository, destination, repository.Branch, "existing", requestedLocal, startCommit, ResolveRefTarget(repository.Path, requestedLocal), commonDir, head);
            }

            var remoteTip = ReadRefTip(repository.Path, requestedRemote);
            if (remoteTip.Exists)
            {
                if (remoteTip.Commit is null || !string.Equals(remoteTip.Commit, startCommit, StringComparison.Ordinal))
                {
                    return Blocked(repository, destination, "start-commit-mismatch", commonDir, head);
                }

                return new PlannedOperation
                {
                    Operation = new WorktreeOperation
                    {
                        Repository = repository.Name,
                        Action = "create-remote",
                        Source = requestedRemote,
                        BranchMode = "track",
                        Destination = destination,
                        Reason = null,
                    },
                    CommonDir = commonDir,
                    Head = head,
                    SourceRef = requestedRemote,
                    SourceCommit = startCommit,
                    SourceTarget = ResolveRefTarget(repository.Path, requestedRemote),
                };
            }

            return CreateLocal(repository, destination, startCommit, "new", startCommit, startCommit, null, commonDir, head);
        }

        var localBranchTip = ReadRefTip(repository.Path, requestedLocal);
        if (localBranchTip.Exists)
        {
            if (localBranchTip.Commit is null)
            {
                return Blocked(repository, destination, "start-commit-missing", commonDir, head);
            }

            return CreateLocal(repository, destination, repository.Branch, "existing", requestedLocal, localBranchTip.Commit, ResolveRefTarget(repository.Path, requestedLocal), commonDir, head);
        }

        var remoteBranchTip = ReadRefTip(repository.Path, requestedRemote);
        if (remoteBranchTip.Exists)
        {
            if (remoteBranchTip.Commit is null)
            {
                return Blocked(repository, destination, "start-commit-missing", commonDir, head);
            }

            return new PlannedOperation
            {
                Operation = new WorktreeOperation
                {
                    Repository = repository.Name,
                    Action = "create-remote",
                    Source = $"origin/{repository.Branch}",
                    BranchMode = "track",
                    Destination = destination,
                    Reason = null,
                },
                CommonDir = commonDir,
                Head = head,
                SourceRef = requestedRemote,
                SourceCommit = remoteBranchTip.Commit,
                SourceTarget = ResolveRefTarget(repository.Path, requestedRemote),
            };
        }

        var localBase = $"refs/heads/{repository.BaseBranch}";
        var localBaseTip = ReadRefTip(repository.Path, localBase);
        if (localBaseTip.Exists)
        {
            if (localBaseTip.Commit is null)
            {
                return Blocked(repository, destination, "base-branch-missing", commonDir, head);
            }

            return CreateLocal(repository, destination, repository.BaseBranch, "new", localBase, localBaseTip.Commit, ResolveRefTarget(repository.Path, localBase), commonDir, head);
        }

        var remoteBase = RemoteQualifiedPattern.IsMatch(repository.BaseBranch) ? repository.BaseBranch : $"origin/{repository.BaseBranch}";
        var remoteBaseRef = $"refs/remotes/{remoteBase}";
        var remoteBaseTip = ReadRefTip(repository.Path, remoteBaseRef);
        if (remoteBaseTip.Exists)
        {
            if (remoteBaseTip.Commit is null)
            {
                return Blocked(repository, destination, "base-branch-missing", commonDir, head);
            }

            return CreateLocal(repository, destination, remoteBase, "new", remoteBaseRef, remoteBaseTip.Commit, ResolveRefTarget(repository.Path, remoteBaseRef), commonDir, head);
        }

        return new PlannedOperation
        {
            Operation = new WorktreeOperation
            {
                Repository = repository.Name,
                Action = "blocked",
                Destination = destination,
                Reason = "base-branch-missing",
            },
            CommonDir = commonDir,
            Head = head,
        };
    }

    private static PlannedOperation CreateLocal(NormalizedRepository repository, string destination, string source, string branchMode, string sourceRef, string sourceCommit, string? sourceTarget, string commonDir, string head)
    {
        if (string.Equals(branchMode, "existing", StringComparison.Ordinal))
        {
            // Attach verifies the upstream the new worktree inherits, and Git
            // copies the source worktree config into it. An include in that
            // file can resolve differently at the destination, so block
            // before any worktree exists.
            var include = GetWorktreeConfigInclude(repository.Path);
            if (include is { } found)
            {
                var message = $"the worktree config '{found.Path}' has '{found.Key}'; git worktree add copies that file into the new worktree, where the include can resolve differently, so the inherited upstream cannot be verified before attach; move it to the shared repository config as an unconditional include, or remove it";
                return Blocked(repository, destination, "worktree-config-include", commonDir, head, message);
            }
        }

        return new PlannedOperation
        {
            Operation = new WorktreeOperation
            {
                Repository = repository.Name,
                Action = "create-local",
                Source = source,
                BranchMode = branchMode,
                Destination = destination,
                Reason = null,
            },
            CommonDir = commonDir,
            Head = head,
            SourceRef = sourceRef,
            SourceCommit = sourceCommit,
            SourceTarget = sourceTarget,
        };
    }

    private static PlannedOperation Blocked(NormalizedRepository repository, string destination, string reason, string commonDir, string head, string? message = null)
    {
        return new PlannedOperation
        {
            Operation = new WorktreeOperation
            {
                Repository = repository.Name,
                Action = "blocked",
                Destination = destination,
                Reason = reason,
                Message = message,
            },
            CommonDir = commonDir,
            Head = head,
        };
    }

    private static CanonicalPlanInput BuildCanonicalInput(NormalizedRequest request, string tasksRoot, List<NormalizedRepository> repositories, List<PlannedOperation> planned, TaskStatePlanned state, CtxRootOptions ctxRoots)
    {
        return new CanonicalPlanInput
        {
            SchemaVersion = request.SchemaVersion,
            TaskKey = request.TaskKey,
            TaskTitle = request.TaskTitle,
            PrdPath = request.PrdPath,
            WorkspaceFile = request.WorkspaceFile,
            Repositories = repositories.Select(r => new CanonicalRepository
            {
                Name = r.Name,
                Path = r.Path,
                BaseBranch = r.BaseBranch,
                Branch = r.Branch,
                StartCommit = r.StartCommit,
            }).ToList(),
            Profiles = request.Profiles.Select(p => new CanonicalProfile
            {
                Name = p.Name,
                Path = p.Path,
            }).ToList(),
            TasksRoot = tasksRoot,
            WorktreeOperations = planned.Select(p => new CanonicalOperation
            {
                Repository = p.Operation.Repository,
                Action = p.Operation.Action,
                Source = p.Operation.Source,
                BranchMode = p.Operation.BranchMode,
                Destination = p.Operation.Destination,
                Reason = p.Operation.Reason,
                CommonDir = p.CommonDir,
                Head = p.Head,
                SourceRef = p.SourceRef,
                SourceCommit = p.SourceCommit,
                SourceTarget = p.SourceTarget,
                DestinationIdentity = p.DestinationIdentity,
            }).ToList(),
            TaskExists = state.TaskExists,
            ManagedFiles = TaskStatePlanner.ManagedFiles(state).ToList(),
            ArtifactsDirectoryExists = TaskStatePlanner.ArtifactsDirectoryExists(state),
            PrdSource = TaskStatePlanner.PrdSourceIdentity(request),
            ProfileIdentities = state.EffectiveProfiles.Select(TaskStatePlanner.ProfileIdentity).ToList(),
            CustomFiles = TaskStatePlanner.CanonicalCustomFiles(request, state.TaskPath).ToList(),
            CtxConfigRoot = ctxRoots.ConfigRoot,
            CtxExternalProfilesRoot = ctxRoots.ExternalProfilesRoot,
            CtxContent = state.CtxContent,
        };
    }

    private static string ComputeIdentity(CanonicalPlanInput canonical)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(canonical);
        var hash = SHA256.HashData(bytes);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static bool IsInsideWorkTree(string repositoryPath)
    {
        var result = RunGit(repositoryPath, "rev-parse", "--is-inside-work-tree");
        return result.ExitCode == 0 && result.StdOut.Trim().Equals("true", StringComparison.Ordinal);
    }

    private static string? GetCommonDir(string repositoryPath)
    {
        var result = RunGit(repositoryPath, "rev-parse", "--path-format=absolute", "--git-common-dir");
        return result.ExitCode == 0 ? FirstLine(result.StdOut) : null;
    }

    private static string? GetGitDir(string repositoryPath)
    {
        var result = RunGit(repositoryPath, "rev-parse", "--path-format=absolute", "--git-dir");
        return result.ExitCode == 0 ? FirstLine(result.StdOut) : null;
    }

    private static string? GetWorktreeConfigPath(string repositoryPath)
    {
        var result = RunGit(repositoryPath, "rev-parse", "--path-format=absolute", "--git-path", "config.worktree");
        return result.ExitCode == 0 ? FirstLine(result.StdOut) : null;
    }

    private static (string Path, string Key)? GetWorktreeConfigInclude(string repositoryPath)
    {
        // `git worktree add` copies the source worktree's config.worktree into
        // the new worktree. Any include in that file can resolve differently
        // there: a relative path resolves against the new file, and an
        // includeIf condition sees the new worktree. Do not emulate Git's
        // include resolution: scan the file Git copies and report the first
        // include key. A stale file blocks too, whatever
        // extensions.worktreeConfig says; that is a conservative refusal.
        var path = GetWorktreeConfigPath(repositoryPath)
            ?? throw new OperationalException($"cannot resolve the worktree config path for '{repositoryPath}'");
        if (!File.Exists(path))
        {
            return null;
        }

        var includes = RunGit(repositoryPath, "config", "--file", path, "--null", "--name-only", "--get-regexp", @"^include(if\..+)?\.path$");
        if (includes.ExitCode == 1)
        {
            return null;
        }

        if (includes.ExitCode != 0)
        {
            throw new OperationalException($"cannot read the worktree config includes in '{path}': {FirstLine(includes.StdErr)}");
        }

        var key = includes.StdOut.Split('\0', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        return key is null ? null : (path, key);
    }

    private static string? GetHead(string repositoryPath)
    {
        var result = RunGit(repositoryPath, "rev-parse", "HEAD");
        return result.ExitCode == 0 ? FirstLine(result.StdOut) : null;
    }

    private static string? GetImmediateHeadRef(string repositoryPath)
    {
        // HEAD's immediate target, never a recursive alias resolution: a task
        // branch may itself be a symbolic alias, and an indirect alias that only
        // resolves to the requested branch is not that branch.
        var result = RunGit(repositoryPath, "symbolic-ref", "-q", "--no-recurse", "HEAD");
        if (result.ExitCode == 0)
        {
            return FirstLine(result.StdOut);
        }

        if (result.StdErr.Contains("unknown option", StringComparison.Ordinal) ||
            result.StdErr.Contains("unrecognized option", StringComparison.Ordinal))
        {
            throw new OperationalException(
                $"cannot read the immediate HEAD target in '{repositoryPath}': this Git does not support 'symbolic-ref --no-recurse'; refusing to resolve HEAD recursively (Git 2.46 or later is required)");
        }

        return null;
    }

    private static bool IsMatchingWorktree(string repositoryPath, string destination, string branch, string commonDir)
    {
        if (string.IsNullOrEmpty(commonDir))
        {
            return false;
        }

        var destinationCommonDir = GetCommonDir(destination);
        if (destinationCommonDir is null || !string.Equals(destinationCommonDir, commonDir, StringComparison.Ordinal))
        {
            return false;
        }

        var destinationHeadRef = GetImmediateHeadRef(destination);
        return string.Equals(destinationHeadRef, $"refs/heads/{branch}", StringComparison.Ordinal);
    }

    private static string? ResolveCommit(string repositoryPath, string reference)
    {
        // No replacement objects: a replace ref can map a missing pinned commit
        // to a local one, which would validate an object that is not here.
        var result = RunGit(repositoryPath, "--no-replace-objects", "rev-parse", "--verify", "--quiet", $"{reference}^{{commit}}");
        return result.ExitCode == 0 ? FirstLine(result.StdOut) : null;
    }

    private static string? ResolveRefTarget(string repositoryPath, string reference)
    {
        // The canonical target of a symbolic ref, or the ref itself when it is
        // not symbolic. Bound into the identity so retargeting a symref at an
        // equal commit still changes the reviewed plan, whether or not a
        // separate upstream will be written.
        var current = reference;
        for (var depth = 0; depth < 8; depth++)
        {
            var result = RunGit(repositoryPath, "symbolic-ref", "-q", current);
            if (result.ExitCode != 0)
            {
                break;
            }

            var target = FirstLine(result.StdOut);
            if (!target.StartsWith("refs/", StringComparison.Ordinal) || string.Equals(target, current, StringComparison.Ordinal))
            {
                break;
            }

            current = target;
        }

        return current;
    }

    private static (bool Exists, string? Commit) ReadRefTip(string repositoryPath, string reference)
    {
        // Presence comes from exact name checks that never run revision DWIM:
        // show-ref --verify and symbolic-ref -q accept only the full name, so a
        // lookalike tag cannot stand in. for-each-ref supplies the raw object
        // ID. Absence needs every signal: show-ref exit 1, symbolic-ref exit 1,
        // no listing row, and no for-each-ref warning. A malformed loose ref or
        // a cyclic symref is present-but-unreadable, never absent.
        var presence = RunGit(repositoryPath, "show-ref", "--verify", "--quiet", reference);
        var symbolic = RunGit(repositoryPath, "symbolic-ref", "-q", reference);

        var result = RunGit(repositoryPath, "for-each-ref", "--format=%(refname) %(objectname)", reference);
        if (result.ExitCode != 0)
        {
            throw new OperationalException($"cannot read ref '{reference}' in '{repositoryPath}'");
        }

        string? objectId = null;
        var listed = false;
        foreach (var rawLine in result.StdOut.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (!line.StartsWith(reference + " ", StringComparison.Ordinal))
            {
                continue;
            }

            // Fixed-width parse: the remainder is exactly one raw object ID.
            var candidate = line[(reference.Length + 1)..];
            if (ObjectIdPattern.IsMatch(candidate))
            {
                objectId = candidate;
            }

            listed = true;
            break;
        }

        var warned = !string.IsNullOrWhiteSpace(result.StdErr);
        bool exists;
        if (presence.ExitCode == 0 || symbolic.ExitCode == 0 || listed)
        {
            exists = true;
        }
        else if (presence.ExitCode == 1 && symbolic.ExitCode == 1 && !warned)
        {
            exists = false;
        }
        else
        {
            // Another exit code, or a warning with an omitted row: present but
            // unreadable. Callers fail closed instead of falling through.
            exists = true;
        }

        if (!exists)
        {
            return (false, null);
        }

        if (objectId is null)
        {
            return (true, null);
        }

        var verify = RunGit(repositoryPath, "--no-replace-objects", "rev-parse", "--verify", "--quiet", $"{objectId}^{{commit}}");
        if (verify.ExitCode != 0)
        {
            return (true, null);
        }

        var commit = FirstLine(verify.StdOut);
        return (true, string.Equals(commit, objectId, StringComparison.Ordinal) ? objectId : null);
    }

    private static bool HasUnsafePathComponent(string tasksRoot, string taskKey, string repositoryName)
    {
        var ancestors = new[]
        {
            tasksRoot,
            Path.Combine(tasksRoot, taskKey),
            Path.Combine(tasksRoot, taskKey, "worktrees"),
        };

        foreach (var ancestor in ancestors)
        {
            if (!TryGetAttributes(ancestor, out var attributes))
            {
                break;
            }

            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                return true;
            }

            if ((attributes & FileAttributes.Directory) == 0)
            {
                return true;
            }
        }

        var destination = Path.Combine(tasksRoot, taskKey, "worktrees", repositoryName);
        return TryGetAttributes(destination, out var destinationAttributes) && (destinationAttributes & FileAttributes.ReparsePoint) != 0;
    }

    private static bool TryGetAttributes(string path, out FileAttributes attributes)
    {
        try
        {
            attributes = File.GetAttributes(path);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            attributes = default;
            return false;
        }
    }

    private static readonly Dictionary<string, bool> NoLazyFetchSupportByPath = new(StringComparer.Ordinal);

    private static readonly object GitCapabilityLock = new();

    private static (int ExitCode, string StdOut, string StdErr) RunGit(string repositoryPath, params string[] arguments)
    {
        EnsureNoLazyFetchAllowed(repositoryPath);
        return RunGitProcess(repositoryPath, true, arguments);
    }

    private static void EnsureNoLazyFetchAllowed(string repositoryPath)
    {
        if (SupportsNoLazyFetch())
        {
            // The per-child GIT_NO_LAZY_FETCH guard below still applies.
            return;
        }

        if (!IsPartialClone(repositoryPath))
        {
            // Old Git is safe for a full clone: there is no promisor remote.
            return;
        }

        throw new OperationalException(
            $"repository '{repositoryPath}' is a partial clone, but this Git does not support --no-lazy-fetch (Git 2.45 or later is required); refusing a read-only planning lookup that could fetch a missing object. Upgrade Git or use a full clone.");
    }

    private static bool SupportsNoLazyFetch()
    {
        // Key by PATH so a test shim that shadows git is not masked by a result
        // cached for the real executable.
        var key = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        lock (GitCapabilityLock)
        {
            if (NoLazyFetchSupportByPath.TryGetValue(key, out var cached))
            {
                return cached;
            }
        }

        var result = RunGitProcess(null, false, "--no-lazy-fetch", "--version");
        var supported = result.ExitCode == 0;
        lock (GitCapabilityLock)
        {
            NoLazyFetchSupportByPath[key] = supported;
        }

        return supported;
    }

    private static bool IsPartialClone(string repositoryPath)
    {
        // Never cached: extensions.partialClone and remote.<name>.promisor are
        // mutable repository config, and the initial plan and the locked
        // re-plan must both see a promisor remote added in between. Old Git is
        // only safe while the repository is a full clone.
        var partial = false;
        var extensions = RunGitProcess(repositoryPath, false, "config", "--get", "extensions.partialClone");
        if (extensions.ExitCode == 0 && !string.IsNullOrWhiteSpace(extensions.StdOut))
        {
            partial = true;
        }
        else
        {
            var promisors = RunGitProcess(repositoryPath, false, "config", "--bool", "--get-regexp", @"^remote\..*\.promisor$");
            if (promisors.ExitCode == 0)
            {
                foreach (var rawLine in promisors.StdOut.Split('\n'))
                {
                    var line = rawLine.Trim();
                    if (line.Length == 0)
                    {
                        continue;
                    }

                    var separator = line.IndexOfAny(new[] { ' ', '\t' });
                    if (separator <= 0)
                    {
                        continue;
                    }

                    if (line[(separator + 1)..].Trim().Equals("true", StringComparison.Ordinal))
                    {
                        partial = true;
                        break;
                    }
                }
            }
        }

        return partial;
    }

    private static (int ExitCode, string StdOut, string StdErr) RunGitProcess(string? repositoryPath, bool guardNoLazyFetch, params string[] arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "git",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        if (repositoryPath is not null)
        {
            startInfo.ArgumentList.Add("-C");
            startInfo.ArgumentList.Add(repositoryPath);
        }

        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        // Planner git calls are read-only. A partial clone would otherwise
        // lazily fetch a missing object just to answer rev-parse.
        if (guardNoLazyFetch)
        {
            startInfo.Environment["GIT_NO_LAZY_FETCH"] = "1";
        }

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null)
            {
                throw new OperationalException("failed to start git");
            }

            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();
            process.WaitForExit();
            return (process.ExitCode, stdoutTask.GetAwaiter().GetResult(), stderrTask.GetAwaiter().GetResult());
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            throw new OperationalException("git executable could not be started");
        }
    }

    private static string FirstLine(string value)
    {
        var newlineIndex = value.IndexOf('\n');
        var line = newlineIndex >= 0 ? value[..newlineIndex] : value;
        return line.Trim();
    }

    private sealed class PlannedOperation
    {
        public WorktreeOperation Operation { get; init; } = new();

        public string CommonDir { get; init; } = string.Empty;

        public string Head { get; init; } = string.Empty;

        public string? SourceRef { get; init; }

        public string? SourceCommit { get; init; }

        public string? SourceTarget { get; init; }

        public string? DestinationIdentity { get; init; }
    }
}
