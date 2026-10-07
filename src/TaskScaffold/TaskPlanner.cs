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

        if (TryGetAttributes(destination, out var destinationAttributes))
        {
            if ((destinationAttributes & FileAttributes.Directory) != 0 && IsMatchingWorktree(repository.Path, destination, repository.Branch, commonDir))
            {
                var reuseRef = $"refs/heads/{repository.Branch}";
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
                    SourceCommit = ResolveCommit(repository.Path, reuseRef),
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
        if (RefExists(repository.Path, requestedLocal))
        {
            return CreateLocal(repository, destination, repository.Branch, "existing", requestedLocal, commonDir, head);
        }

        var requestedRemote = $"refs/remotes/origin/{repository.Branch}";
        if (RefExists(repository.Path, requestedRemote))
        {
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
                SourceCommit = ResolveCommit(repository.Path, requestedRemote),
            };
        }

        var localBase = $"refs/heads/{repository.BaseBranch}";
        if (RefExists(repository.Path, localBase))
        {
            return CreateLocal(repository, destination, repository.BaseBranch, "new", localBase, commonDir, head);
        }

        var remoteBase = RemoteQualifiedPattern.IsMatch(repository.BaseBranch) ? repository.BaseBranch : $"origin/{repository.BaseBranch}";
        var remoteBaseRef = $"refs/remotes/{remoteBase}";
        if (RefExists(repository.Path, remoteBaseRef))
        {
            return CreateLocal(repository, destination, remoteBase, "new", remoteBaseRef, commonDir, head);
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

    private static PlannedOperation CreateLocal(NormalizedRepository repository, string destination, string source, string branchMode, string sourceRef, string commonDir, string head)
    {
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
            SourceCommit = ResolveCommit(repository.Path, sourceRef),
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

    private static string? GetHead(string repositoryPath)
    {
        var result = RunGit(repositoryPath, "rev-parse", "HEAD");
        return result.ExitCode == 0 ? FirstLine(result.StdOut) : null;
    }

    private static string? GetBranch(string repositoryPath)
    {
        var result = RunGit(repositoryPath, "branch", "--show-current");
        return result.ExitCode == 0 ? FirstLine(result.StdOut) : null;
    }

    private static bool RefExists(string repositoryPath, string reference)
    {
        var result = RunGit(repositoryPath, "rev-parse", "--verify", "--quiet", $"{reference}^{{commit}}");
        return result.ExitCode == 0;
    }

    private static string? ResolveCommit(string repositoryPath, string reference)
    {
        var result = RunGit(repositoryPath, "rev-parse", "--verify", "--quiet", $"{reference}^{{commit}}");
        return result.ExitCode == 0 ? FirstLine(result.StdOut) : null;
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

        var destinationBranch = GetBranch(destination);
        return string.Equals(destinationBranch, branch, StringComparison.Ordinal);
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

    private static (int ExitCode, string StdOut, string StdErr) RunGit(string repositoryPath, params string[] arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "git",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.ArgumentList.Add("-C");
        startInfo.ArgumentList.Add(repositoryPath);
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
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

        public string? DestinationIdentity { get; init; }
    }
}
