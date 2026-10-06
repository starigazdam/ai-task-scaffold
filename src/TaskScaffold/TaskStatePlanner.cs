using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

public static class TaskStatePlanner
{
    private static readonly string[] ManagedFileNames = { "task.json", "PRD.md", "PLAN.md", "STATUS.md", ".ctx" };

    public static TaskStatePlanned Compute(NormalizedRequest request, string tasksRoot, List<CanonicalProfile> effectiveProfiles, string prdTemplatePath)
    {
        var taskPath = Path.Combine(tasksRoot, request.TaskKey);
        var manifestPath = Path.Combine(taskPath, "task.json");
        var ctxPath = Path.Combine(taskPath, ".ctx");
        var ctxContent = string.Join("\n", effectiveProfiles.Select(p => $"{p.Name}:{p.Path}")) + "\n";
        var taskExists = Path.Exists(taskPath);

        return new TaskStatePlanned
        {
            TaskExists = taskExists,
            TasksRoot = tasksRoot,
            TaskPath = taskPath,
            ManifestPath = manifestPath,
            CtxPath = ctxPath,
            CtxContent = ctxContent,
            EffectiveProfiles = effectiveProfiles,
            PrdOperation = ComputePrdOperation(request, taskExists, prdTemplatePath),
            ProfileState = ComputeProfileState(manifestPath, effectiveProfiles),
            CtxFilePlan = ComputeCtxFilePlan(ctxPath, ctxContent),
            CustomFileOperations = ComputeCustomFileOperations(request, taskPath),
        };
    }

    private static PrdOperation ComputePrdOperation(NormalizedRequest request, bool taskExists, string prdTemplatePath)
    {
        var sourcePath = request.PrdPath;
        var sourceProvided = !string.IsNullOrWhiteSpace(sourcePath);
        var sourceExists = sourceProvided && File.Exists(sourcePath);
        if (taskExists)
        {
            if (!sourceProvided)
            {
                return new PrdOperation { Action = "reuse-existing", Destination = "PRD.md" };
            }

            if (sourceExists)
            {
                return new PrdOperation { Action = "compare-existing", SourcePath = sourcePath, Destination = "PRD.md" };
            }

            return new PrdOperation
            {
                Action = "blocked",
                SourcePath = sourcePath,
                Destination = "PRD.md",
                Reason = $"PRD source '{sourcePath}' does not exist",
            };
        }

        if (sourceExists)
        {
            return new PrdOperation { Action = "copy-source", SourcePath = sourcePath, Destination = "PRD.md" };
        }

        if (!File.Exists(prdTemplatePath))
        {
            throw new InputException($"PRD starter template '{prdTemplatePath}' does not exist");
        }

        var reason = sourceProvided ? $"PRD source '{sourcePath}' does not exist" : "No PRD source was supplied";
        return new PrdOperation
        {
            Action = "create-starter",
            SourcePath = sourcePath,
            Destination = "PRD.md",
            TemplatePath = prdTemplatePath,
            Reason = reason,
        };
    }

    private static TaskProfileState ComputeProfileState(string manifestPath, List<CanonicalProfile> expectedProfiles)
    {
        if (!File.Exists(manifestPath))
        {
            return new TaskProfileState { IdentityMatches = true, RequiresMigration = false };
        }

        using var document = JsonDocument.Parse(File.ReadAllText(manifestPath));
        var root = document.RootElement;
        JsonElement profilesElement = default;
        var hasProfiles = root.ValueKind == JsonValueKind.Object && root.TryGetProperty("profiles", out profilesElement);
        var requiresMigration = !hasProfiles;

        var existingProfiles = new List<(string? Name, string? Path)>();
        if (hasProfiles)
        {
            if (profilesElement.ValueKind != JsonValueKind.Array)
            {
                throw new InputException($"existing task manifest has invalid profiles: '{manifestPath}'");
            }

            foreach (var profile in profilesElement.EnumerateArray())
            {
                string? name = null;
                string? path = null;
                if (profile.ValueKind == JsonValueKind.Object)
                {
                    if (profile.TryGetProperty("name", out var nameElement))
                    {
                        name = nameElement.ValueKind == JsonValueKind.String ? nameElement.GetString() : nameElement.ToString();
                    }

                    if (profile.TryGetProperty("path", out var pathElement))
                    {
                        path = pathElement.ValueKind == JsonValueKind.Null ? null
                            : pathElement.ValueKind == JsonValueKind.String ? pathElement.GetString()
                            : pathElement.ToString();
                    }
                }

                existingProfiles.Add((name, path));
            }
        }
        else
        {
            existingProfiles.Add(("task-scaffold", null));
        }

        var identityMatches = existingProfiles.Count == expectedProfiles.Count;
        if (identityMatches)
        {
            for (var index = 0; index < expectedProfiles.Count; index++)
            {
                if (!string.Equals(existingProfiles[index].Name, expectedProfiles[index].Name, StringComparison.OrdinalIgnoreCase))
                {
                    identityMatches = false;
                    break;
                }
            }
        }

        var pathDrift = new List<ProfilePathDrift>();
        if (identityMatches && hasProfiles)
        {
            for (var index = 0; index < expectedProfiles.Count; index++)
            {
                var existingPath = existingProfiles[index].Path;
                var expectedPath = expectedProfiles[index].Path;
                if (string.IsNullOrWhiteSpace(existingPath) ||
                    !TaskFileSafety.PathComparer.Equals(
                        TaskFileSafety.NormalizeTaskProfilePath(existingPath),
                        TaskFileSafety.NormalizeTaskProfilePath(expectedPath)))
                {
                    pathDrift.Add(new ProfilePathDrift
                    {
                        Name = expectedProfiles[index].Name,
                        ExistingPath = existingPath,
                        RequestedPath = expectedPath,
                    });
                }
            }
        }

        return new TaskProfileState
        {
            IdentityMatches = identityMatches,
            PathDrift = pathDrift,
            RequiresMigration = requiresMigration,
        };
    }

    private static CtxFilePlan ComputeCtxFilePlan(string ctxPath, string content)
    {
        var action = "create";
        if (TaskFileSafety.TryGetAttributes(ctxPath, out var attributes))
        {
            if ((attributes & FileAttributes.Directory) != 0 || (attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new InputException($"task .ctx must be a regular file: {ctxPath}");
            }

            action = string.Equals(File.ReadAllText(ctxPath), content, StringComparison.Ordinal) ? "noop" : "update";
        }

        return new CtxFilePlan { Path = ctxPath, Action = action, Content = content };
    }

    private static List<CustomFileOperation> ComputeCustomFileOperations(NormalizedRequest request, string taskPath)
    {
        TaskFileSafety.AssertTaskFileDestinations(taskPath, request.TaskFiles.Select(f => f.Path));

        var operations = new List<CustomFileOperation>();
        foreach (var file in request.TaskFiles)
        {
            var destination = TaskFileSafety.GetCustomFileDestination(taskPath, file.Path);
            var contentHash = TaskFileSafety.GetTaskFileContentHash(file.Content);
            var action = "create";
            string? reason = null;
            if (!TaskFileSafety.TestCustomPathSafety(taskPath, file.Path, excludeDestination: true))
            {
                action = "conflict";
                reason = "unsafe-task-file-path";
            }
            else
            {
                var state = TaskFileSafety.GetCustomFileState(taskPath, file.Path);
                if (state.Exists)
                {
                    if (state.IsReparsePoint)
                    {
                        action = "conflict";
                        reason = "reparse-point";
                    }
                    else if (!state.IsFile)
                    {
                        action = "conflict";
                        reason = "destination-is-directory";
                    }
                    else if (string.Equals(state.Sha256, contentHash, StringComparison.Ordinal))
                    {
                        action = "noop";
                    }
                    else
                    {
                        action = "conflict";
                        reason = "destination-differs";
                    }
                }
                else if (TestAncestorConflict(taskPath, file.Path))
                {
                    action = "conflict";
                    reason = "ancestor-is-file";
                }
            }

            operations.Add(new CustomFileOperation
            {
                Path = file.Path,
                Destination = destination,
                Action = action,
                Reason = reason,
                ContentHash = contentHash,
            });
        }

        return operations;
    }

    private static bool TestAncestorConflict(string taskPath, string relativePath)
    {
        var segments = relativePath.Split('/');
        var current = Path.GetFullPath(taskPath);
        for (var index = 0; index < segments.Length - 1; index++)
        {
            current = Path.GetFullPath(Path.Combine(current, segments[index]));
            if (TaskFileSafety.TryGetAttributes(current, out var attributes) && (attributes & FileAttributes.Directory) == 0)
            {
                return true;
            }
        }

        return false;
    }

    public static List<CanonicalFileIdentity> ManagedFiles(TaskStatePlanned state)
    {
        return ManagedFileNames.Select(name => FileIdentity(Path.Combine(state.TaskPath, name))).ToList();
    }

    public static bool ArtifactsDirectoryExists(TaskStatePlanned state)
    {
        return Directory.Exists(Path.Combine(state.TaskPath, "artifacts"));
    }

    public static CanonicalFileIdentity? PrdSourceIdentity(NormalizedRequest request)
    {
        return string.IsNullOrWhiteSpace(request.PrdPath) ? null : FileIdentity(request.PrdPath);
    }

    public static CanonicalProfileIdentity ProfileIdentity(CanonicalProfile profile)
    {
        var skillsRoot = Path.Combine(profile.Path, ".agents", "skills");
        var skills = new List<CanonicalSkillIdentity>();
        if (Directory.Exists(skillsRoot))
        {
            skills = Directory.EnumerateDirectories(skillsRoot)
                .OrderBy(directory => Path.GetFileName(directory), StringComparer.OrdinalIgnoreCase)
                .ThenBy(directory => Path.GetFileName(directory), StringComparer.Ordinal)
                .Select(directory => new CanonicalSkillIdentity
                {
                    Name = Path.GetFileName(directory),
                    Skill = FileIdentity(Path.Combine(directory, "SKILL.md")),
                })
                .ToList();
        }

        return new CanonicalProfileIdentity
        {
            Name = profile.Name,
            Path = Path.GetFullPath(profile.Path),
            Instructions = FileIdentity(Path.Combine(profile.Path, "AGENTS.md")),
            Skills = skills,
        };
    }

    public static List<CanonicalCustomFile> CanonicalCustomFiles(NormalizedRequest request, string taskPath)
    {
        var files = new List<CanonicalCustomFile>();
        foreach (var file in request.TaskFiles)
        {
            CanonicalDestinationState destination;
            if (TaskFileSafety.TestCustomPathSafety(taskPath, file.Path, excludeDestination: false))
            {
                var state = TaskFileSafety.GetCustomFileState(taskPath, file.Path);
                destination = new CanonicalDestinationState
                {
                    Path = state.Path,
                    Exists = state.Exists,
                    IsFile = state.IsFile,
                    IsReparsePoint = state.IsReparsePoint,
                    Sha256 = state.Sha256,
                };
            }
            else
            {
                destination = new CanonicalDestinationState
                {
                    Path = TaskFileSafety.GetCustomFileDestination(taskPath, file.Path),
                    Exists = true,
                    IsFile = false,
                    IsReparsePoint = true,
                };
            }

            files.Add(new CanonicalCustomFile
            {
                Path = file.Path,
                ContentSha256 = TaskFileSafety.GetTaskFileContentHash(file.Content),
                Destination = destination,
            });
        }

        return files;
    }

    public static CanonicalFileIdentity FileIdentity(string path)
    {
        if (!File.Exists(path))
        {
            return new CanonicalFileIdentity { Path = Path.GetFullPath(path), Exists = false };
        }

        return new CanonicalFileIdentity
        {
            Path = Path.GetFullPath(path),
            Exists = true,
            Sha256 = TaskFileSafety.HashFile(path),
        };
    }
}
