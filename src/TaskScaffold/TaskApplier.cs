using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

public static class TaskApplier
{
    private static readonly Regex PlanIdentityPattern = new(@"\A[a-f0-9]{64}\z", RegexOptions.CultureInvariant);

    private static readonly JsonSerializerOptions IndentedOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static TaskPlanResult Apply(NormalizedRequest request, string tasksRoot, string? expectedPlanIdentity)
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

        var reviewPlan = TaskPlanner.Plan(request, fullTasksRoot);
        PrecheckPlanIdentity(reviewPlan, request, expectedPlanIdentity);

        var mutationLock = EnterMutationLock(fullTasksRoot);
        try
        {
            var plan = TaskPlanner.Plan(request, fullTasksRoot);
            var state = plan.State!;
            if (!string.Equals(expectedPlanIdentity, plan.PlanIdentity, StringComparison.Ordinal))
            {
                throw new InputException("task-scaffold plan identity changed before apply; no task state was changed; replan and approve again");
            }

            AssertTaskPathSafety(state.TasksRoot, request.TaskKey);
            if (state.PrdOperation.Action == "blocked")
            {
                throw new InputException($"cannot apply task '{request.TaskKey}': {state.PrdOperation.Reason}");
            }

            var customConflict = state.CustomFileOperations.FirstOrDefault(operation => operation.Action == "conflict");
            if (customConflict is not null)
            {
                throw new InputException($"cannot apply task file '{customConflict.Path}': {customConflict.Reason}");
            }

            CheckExistingTaskConsistency(request, state);
            WritePrd(request, state);
            WritePlanAndStatus(request, state);
            WriteManifest(request, state);
            WriteCustomFiles(request, state);
            WriteCtx(request, state);
            Directory.CreateDirectory(Path.Combine(state.TaskPath, "artifacts"));

            return plan;
        }
        finally
        {
            mutationLock.Dispose();
        }
    }

    private static void PrecheckPlanIdentity(TaskPlanResult reviewPlan, NormalizedRequest request, string? expectedPlanIdentity)
    {
        if (string.IsNullOrWhiteSpace(expectedPlanIdentity))
        {
            throw new InputException("Apply requires ExpectedPlanIdentity from the reviewed plan");
        }

        if (!PlanIdentityPattern.IsMatch(expectedPlanIdentity))
        {
            throw new InputException("ExpectedPlanIdentity must be a SHA-256 plan identity from the reviewed plan");
        }

        if (!string.Equals(expectedPlanIdentity, reviewPlan.PlanIdentity, StringComparison.Ordinal))
        {
            throw new InputException("task-scaffold plan identity changed since review; replan and approve again");
        }

        var state = reviewPlan.State!;
        if (state.TaskExists)
        {
            if (!state.ProfileState.IdentityMatches)
            {
                throw new InputException($"existing task '{request.TaskKey}' manifest profiles differ from the request");
            }

            if (state.ProfileState.PathDrift.Count > 0)
            {
                throw new InputException($"existing task '{request.TaskKey}' profile paths changed; reconciliation is required before apply");
            }
        }
    }

    private static FileStream EnterMutationLock(string tasksRoot)
    {
        var tasksRootPath = Path.GetFullPath(tasksRoot);
        Directory.CreateDirectory(tasksRootPath);
        var lockPath = Path.Combine(tasksRootPath, ".ai-task-scaffold.lock");
        return new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }

    private static void AssertTaskPathSafety(string tasksRoot, string taskKey)
    {
        if (!TaskFileSafety.TestTaskPathSafety(tasksRoot, taskKey))
        {
            throw new InputException($"cannot scaffold task '{taskKey}': unsafe-task-path");
        }
    }

    private static void CheckExistingTaskConsistency(NormalizedRequest request, TaskStatePlanned state)
    {
        if (!state.TaskExists)
        {
            return;
        }

        var taskKey = request.TaskKey;
        if (!File.Exists(state.ManifestPath))
        {
            throw new InputException($"existing task '{taskKey}' has no task.json");
        }

        using (var document = JsonDocument.Parse(File.ReadAllText(state.ManifestPath)))
        {
            if (!ContractMatches(document.RootElement, request))
            {
                throw new InputException($"existing task '{taskKey}' manifest differs from the request");
            }
        }

        if (!state.ProfileState.IdentityMatches)
        {
            throw new InputException($"existing task '{taskKey}' manifest profiles differ from the request");
        }

        if (state.ProfileState.PathDrift.Count > 0)
        {
            throw new InputException($"existing task '{taskKey}' profile paths changed; reconciliation is required before apply");
        }
    }

    private static bool ContractMatches(JsonElement root, NormalizedRequest request)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        if (!TryGetInt(root, "schemaVersion", out var schemaVersion) || schemaVersion != 3)
        {
            return false;
        }

        if (!root.TryGetProperty("task", out var task) || task.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        if (!TryGetString(task, "key", out var key) || !string.Equals(key, request.TaskKey, StringComparison.Ordinal))
        {
            return false;
        }

        if (!TryGetString(task, "title", out var title) || !string.Equals(title, request.TaskTitle, StringComparison.Ordinal))
        {
            return false;
        }

        if (!TryGetString(task, "prdPath", out var prdPath) || !string.Equals(prdPath, "PRD.md", StringComparison.Ordinal))
        {
            return false;
        }

        if (!root.TryGetProperty("repositories", out var repositories) || repositories.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        var actual = new List<(string Name, string Path, string Branch, string BaseBranch)>();
        foreach (var repository in repositories.EnumerateArray())
        {
            if (repository.ValueKind != JsonValueKind.Object ||
                !TryGetString(repository, "name", out var name) ||
                !TryGetString(repository, "path", out var path) ||
                !TryGetString(repository, "branch", out var branch) ||
                !TryGetString(repository, "baseBranch", out var baseBranch))
            {
                return false;
            }

            actual.Add((name, path, branch, baseBranch));
        }

        var expected = ExpectedRepositories(request);
        var orderedActual = actual
            .OrderBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(r => r.Name, StringComparer.Ordinal)
            .ToList();
        if (orderedActual.Count != expected.Count)
        {
            return false;
        }

        for (var index = 0; index < orderedActual.Count; index++)
        {
            if (!string.Equals(orderedActual[index].Name, expected[index].Name, StringComparison.Ordinal) ||
                !string.Equals(orderedActual[index].Path, expected[index].Path, StringComparison.Ordinal) ||
                !string.Equals(orderedActual[index].Branch, expected[index].Branch, StringComparison.Ordinal) ||
                !string.Equals(orderedActual[index].BaseBranch, expected[index].BaseBranch, StringComparison.Ordinal))
            {
                return false;
            }
        }

        return true;
    }

    private static List<(string Name, string Path, string Branch, string BaseBranch)> ExpectedRepositories(NormalizedRequest request)
    {
        return request.Repositories
            .Select(repository => (repository.Name, repository.Path, repository.Branch, repository.BaseBranch))
            .OrderBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(r => r.Name, StringComparer.Ordinal)
            .ToList();
    }

    private static void WritePrd(NormalizedRequest request, TaskStatePlanned state)
    {
        var taskKey = request.TaskKey;
        var prdDestination = Path.Combine(state.TaskPath, "PRD.md");
        if (state.TaskExists)
        {
            if (!File.Exists(prdDestination))
            {
                throw new InputException($"existing task '{taskKey}' has no PRD.md");
            }

            if (state.PrdOperation.Action == "compare-existing" &&
                !string.Equals(TaskFileSafety.HashFile(state.PrdOperation.SourcePath!), TaskFileSafety.HashFile(prdDestination), StringComparison.Ordinal))
            {
                throw new InputException($"existing task '{taskKey}' has a different PRD.md");
            }

            return;
        }

        Directory.CreateDirectory(state.TaskPath);
        AssertTaskPathSafety(state.TasksRoot, taskKey);
        if (state.PrdOperation.Action == "copy-source")
        {
            File.Copy(state.PrdOperation.SourcePath!, prdDestination);
            return;
        }

        AssertTaskPathSafety(state.TasksRoot, taskKey);
        var template = File.ReadAllText(state.PrdOperation.TemplatePath!);
        var starter = template.Replace("{{TASK_TITLE}}", request.TaskTitle);
        File.WriteAllText(prdDestination, starter, new UTF8Encoding(false));
    }

    private static void WritePlanAndStatus(NormalizedRequest request, TaskStatePlanned state)
    {
        var planPath = Path.Combine(state.TaskPath, "PLAN.md");
        if (!Path.Exists(planPath))
        {
            AssertTaskPathSafety(state.TasksRoot, request.TaskKey);
            var content = $"# {request.TaskKey} — {request.TaskTitle}\n\nSource PRD: PRD.md\n\n## Phases";
            File.WriteAllText(planPath, content, new UTF8Encoding(false));
        }

        var statusPath = Path.Combine(state.TaskPath, "STATUS.md");
        if (!Path.Exists(statusPath))
        {
            AssertTaskPathSafety(state.TasksRoot, request.TaskKey);
            var repositoryLines = string.Join("\n", request.Repositories.Select(repository => $"  - {repository.Name}: {repository.Branch}"));
            var content = $"# {request.TaskKey} — {request.TaskTitle}\nstate: not-started\nplan: PLAN.md\nrepos:\n{repositoryLines}\nphases:";
            File.WriteAllText(statusPath, content, new UTF8Encoding(false));
        }
    }

    private static void WriteManifest(NormalizedRequest request, TaskStatePlanned state)
    {
        var recordedTaskFiles = GetRecordedTaskFiles(state.ManifestPath);
        var requestedTaskFilePaths = request.TaskFiles.Select(file => file.Path).ToList();
        var mergedTaskFiles = MergeTaskFilePaths(recordedTaskFiles, requestedTaskFilePaths);
        var taskFilesChanged = false;
        if (requestedTaskFilePaths.Count > 0)
        {
            if (mergedTaskFiles.Count != recordedTaskFiles.Count)
            {
                taskFilesChanged = true;
            }
            else
            {
                for (var index = 0; index < mergedTaskFiles.Count; index++)
                {
                    if (!TaskFileSafety.PathComparer.Equals(mergedTaskFiles[index], recordedTaskFiles[index]))
                    {
                        taskFilesChanged = true;
                        break;
                    }
                }
            }
        }

        if (!Path.Exists(state.ManifestPath))
        {
            AssertTaskPathSafety(state.TasksRoot, request.TaskKey);
            WriteJson(state.ManifestPath, BuildNewManifest(request, state, mergedTaskFiles));
        }
        else if (state.ProfileState.RequiresMigration)
        {
            AssertTaskPathSafety(state.TasksRoot, request.TaskKey);
            var manifest = ParseManifest(request, state.ManifestPath);
            manifest["profiles"] = BuildProfilesArray(state.EffectiveProfiles);
            if (mergedTaskFiles.Count > 0)
            {
                if (taskFilesChanged || !manifest.ContainsKey("taskFiles"))
                {
                    manifest["taskFiles"] = BuildStringArray(mergedTaskFiles);
                }
            }

            WriteJson(state.ManifestPath, manifest);
        }
        else if (taskFilesChanged)
        {
            AssertTaskPathSafety(state.TasksRoot, request.TaskKey);
            var manifest = ParseManifest(request, state.ManifestPath);
            manifest["taskFiles"] = BuildStringArray(mergedTaskFiles);
            WriteJson(state.ManifestPath, manifest);
        }
    }

    private static JsonObject BuildNewManifest(NormalizedRequest request, TaskStatePlanned state, List<string> mergedTaskFiles)
    {
        var manifest = new JsonObject
        {
            ["schemaVersion"] = 3,
            ["task"] = new JsonObject
            {
                ["key"] = request.TaskKey,
                ["title"] = request.TaskTitle,
                ["prdPath"] = "PRD.md",
            },
            ["repositories"] = BuildRepositoriesArray(request),
            ["profiles"] = BuildProfilesArray(state.EffectiveProfiles),
            ["phases"] = new JsonArray(),
        };
        if (mergedTaskFiles.Count > 0)
        {
            manifest["taskFiles"] = BuildStringArray(mergedTaskFiles);
        }

        return manifest;
    }

    private static JsonObject ParseManifest(NormalizedRequest request, string manifestPath)
    {
        if (JsonNode.Parse(File.ReadAllText(manifestPath)) is JsonObject manifest)
        {
            return manifest;
        }

        throw new InputException($"existing task '{request.TaskKey}' has an invalid task.json");
    }

    private static JsonArray BuildRepositoriesArray(NormalizedRequest request)
    {
        var array = new JsonArray();
        foreach (var repository in ExpectedRepositories(request))
        {
            array.Add(new JsonObject
            {
                ["name"] = repository.Name,
                ["path"] = repository.Path,
                ["branch"] = repository.Branch,
                ["baseBranch"] = repository.BaseBranch,
            });
        }

        return array;
    }

    private static JsonArray BuildProfilesArray(List<CanonicalProfile> profiles)
    {
        var array = new JsonArray();
        foreach (var profile in profiles)
        {
            array.Add(new JsonObject
            {
                ["name"] = profile.Name,
                ["path"] = profile.Path,
            });
        }

        return array;
    }

    private static JsonArray BuildStringArray(IEnumerable<string> values)
    {
        var array = new JsonArray();
        foreach (var value in values)
        {
            array.Add((JsonNode)value);
        }

        return array;
    }

    private static void WriteJson(string path, JsonNode node)
    {
        File.WriteAllText(path, node.ToJsonString(IndentedOptions), new UTF8Encoding(false));
    }

    private static void WriteCustomFiles(NormalizedRequest request, TaskStatePlanned state)
    {
        foreach (var operation in state.CustomFileOperations)
        {
            if (operation.Action == "noop")
            {
                continue;
            }

            if (!TaskFileSafety.TestCustomPathSafety(state.TaskPath, operation.Path, excludeDestination: false))
            {
                throw new InputException($"cannot write task file '{operation.Path}': unsafe-task-file-path");
            }

            var taskFile = request.TaskFiles.First(file => string.Equals(file.Path, operation.Path, StringComparison.Ordinal));
            Directory.CreateDirectory(Path.GetDirectoryName(operation.Destination)!);
            if (!TaskFileSafety.TestCustomPathSafety(state.TaskPath, operation.Path, excludeDestination: false))
            {
                throw new InputException($"cannot write task file '{operation.Path}': unsafe-task-file-path");
            }

            var bytes = TaskFileSafety.GetTaskFileContentBytes(taskFile.Content);
            using var stream = new FileStream(operation.Destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            stream.Write(bytes, 0, bytes.Length);
        }
    }

    private static void WriteCtx(NormalizedRequest request, TaskStatePlanned state)
    {
        AssertTaskPathSafety(state.TasksRoot, request.TaskKey);
        if (TaskFileSafety.TryGetAttributes(state.CtxPath, out var attributes))
        {
            if ((attributes & FileAttributes.Directory) != 0 || (attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new InputException($"task .ctx must be a regular file: {state.CtxPath}");
            }

            if (!string.Equals(File.ReadAllText(state.CtxPath), state.CtxContent, StringComparison.Ordinal))
            {
                File.WriteAllText(state.CtxPath, state.CtxContent, new UTF8Encoding(false));
            }

            return;
        }

        File.WriteAllText(state.CtxPath, state.CtxContent, new UTF8Encoding(false));
    }

    private static List<string> GetRecordedTaskFiles(string manifestPath)
    {
        if (!File.Exists(manifestPath))
        {
            return new List<string>();
        }

        using var document = JsonDocument.Parse(File.ReadAllText(manifestPath));
        if (!document.RootElement.TryGetProperty("taskFiles", out var element) || element.ValueKind == JsonValueKind.Null)
        {
            return new List<string>();
        }

        var result = new List<string>();
        if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray())
            {
                result.Add(item.ValueKind == JsonValueKind.String ? item.GetString()! : item.ToString());
            }
        }
        else if (element.ValueKind == JsonValueKind.String)
        {
            result.Add(element.GetString()!);
        }

        return result;
    }

    private static List<string> MergeTaskFilePaths(List<string> existing, List<string> requested)
    {
        var merged = new List<string>(existing);
        foreach (var path in requested)
        {
            if (!merged.Any(candidate => TaskFileSafety.PathComparer.Equals(candidate, path)))
            {
                merged.Add(path);
            }
        }

        return merged;
    }

    private static bool TryGetString(JsonElement element, string propertyName, out string value)
    {
        value = string.Empty;
        if (!element.TryGetProperty(propertyName, out var property) || property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = property.GetString() ?? string.Empty;
        return true;
    }

    private static bool TryGetInt(JsonElement element, string propertyName, out int value)
    {
        value = 0;
        return element.TryGetProperty(propertyName, out var property) &&
            property.ValueKind == JsonValueKind.Number &&
            property.TryGetInt32(out value);
    }
}
