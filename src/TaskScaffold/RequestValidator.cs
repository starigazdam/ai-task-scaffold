using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

public sealed class InputException : Exception
{
    public InputException(string message) : base(message)
    {
    }
}

public sealed class OperationalException : Exception
{
    public OperationalException(string message) : base(message)
    {
    }
}

public sealed class RepositoryEntry
{
    [JsonPropertyName("name")]
    public string Name { get; init; } = string.Empty;

    [JsonPropertyName("path")]
    public string Path { get; init; } = string.Empty;
}

public sealed class ProfileEntry
{
    [JsonPropertyName("name")]
    public string Name { get; init; } = string.Empty;

    [JsonPropertyName("path")]
    public string Path { get; init; } = string.Empty;
}

public sealed class ValidationResult
{
    [JsonPropertyName("valid")]
    public bool Valid { get; init; }

    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; init; }

    [JsonPropertyName("taskKey")]
    public string TaskKey { get; init; } = string.Empty;

    [JsonPropertyName("repositories")]
    public List<RepositoryEntry> Repositories { get; init; } = new();

    [JsonPropertyName("prdPath")]
    public string? PrdPath { get; init; }

    [JsonPropertyName("profiles")]
    public List<ProfileEntry> Profiles { get; init; } = new();

    [JsonPropertyName("workspaceFile")]
    public string? WorkspaceFile { get; init; }
}

public static class RequestValidator
{
    private static readonly Regex NamePattern = new(@"\A[A-Za-z0-9][A-Za-z0-9._-]*\z", RegexOptions.CultureInvariant);

    public static ValidationResult Validate(string requestPath)
    {
        string fullRequestPath;
        try
        {
            fullRequestPath = Path.GetFullPath(requestPath);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new InputException($"invalid request path '{requestPath}'");
        }

        string text;
        try
        {
            text = File.ReadAllText(fullRequestPath);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new InputException($"cannot read request file '{requestPath}'");
        }

        var requestDirectory = Path.GetDirectoryName(fullRequestPath);
        if (string.IsNullOrEmpty(requestDirectory))
        {
            requestDirectory = Directory.GetCurrentDirectory();
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(text, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64,
            });
        }
        catch (JsonException)
        {
            throw new InputException("request is not valid JSON");
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new InputException("request must be a JSON object");
            }

            CheckForDuplicateProperties(root);

            var rootFields = ReadObject(root, "request", "schemaVersion", "task", "repositories", "profiles", "workspace");

            var version = Require(rootFields, "schemaVersion", "request");
            if (version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var schemaVersion) || schemaVersion != 3)
            {
                throw new InputException("unsupported schemaVersion; schemaVersion 3 is required");
            }

            var task = ReadObject(Require(rootFields, "task", "request"), "task", "key", "title", "prdPath");
            var key = ReadString(Require(task, "key", "task"), "task.key");
            if (!NamePattern.IsMatch(key))
            {
                throw new InputException($"invalid task key '{key}'");
            }

            var title = ReadString(Require(task, "title", "task"), "task.title");
            if (string.IsNullOrWhiteSpace(title))
            {
                throw new InputException("task title is required");
            }

            string? prdPath = null;
            if (task.TryGetValue("prdPath", out var prdElement) && prdElement.ValueKind != JsonValueKind.Null)
            {
                var rawPrd = ReadString(prdElement, "task.prdPath");
                if (!string.IsNullOrWhiteSpace(rawPrd))
                {
                    prdPath = ResolvePath(rawPrd, requestDirectory);
                }
            }

            var repositoriesElement = Require(rootFields, "repositories", "request");
            if (repositoriesElement.ValueKind != JsonValueKind.Array)
            {
                throw new InputException("repositories must be an array");
            }

            var repositories = new List<RepositoryEntry>();
            var repositoryNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var repositoryElement in repositoriesElement.EnumerateArray())
            {
                var repository = ReadObject(repositoryElement, "repositories[]", "name", "path", "baseBranch", "branch");
                var name = ReadString(Require(repository, "name", "repository"), "repository.name");
                if (!NamePattern.IsMatch(name))
                {
                    throw new InputException($"invalid repository name '{name}'");
                }

                if (!repositoryNames.Add(name))
                {
                    throw new InputException($"duplicate repository name '{name}'");
                }

                var rawPath = ReadString(Require(repository, "path", "repository"), "repository.path");
                if (string.IsNullOrWhiteSpace(rawPath))
                {
                    throw new InputException($"repository '{name}' path is required");
                }

                var baseBranch = ReadString(Require(repository, "baseBranch", "repository"), "repository.baseBranch");
                var branch = ReadString(Require(repository, "branch", "repository"), "repository.branch");
                if (!IsValidGitBranch(baseBranch))
                {
                    throw new InputException($"invalid Git base branch '{baseBranch}'");
                }

                if (!IsValidGitBranch(branch))
                {
                    throw new InputException($"invalid Git branch '{branch}'");
                }

                repositories.Add(new RepositoryEntry
                {
                    Name = name,
                    Path = ResolvePath(rawPath, requestDirectory),
                });
            }

            if (repositories.Count == 0)
            {
                throw new InputException("at least one repository is required");
            }

            var profiles = new List<ProfileEntry>();
            if (rootFields.TryGetValue("profiles", out var profilesElement))
            {
                if (profilesElement.ValueKind != JsonValueKind.Array)
                {
                    throw new InputException("profiles must be an array");
                }

                var profileNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var profileElement in profilesElement.EnumerateArray())
                {
                    var profile = ReadObject(profileElement, "profiles[]", "name", "path");
                    var name = ReadString(Require(profile, "name", "profile"), "profile.name");
                    if (!NamePattern.IsMatch(name))
                    {
                        throw new InputException($"invalid profile name '{name}'");
                    }

                    if (string.Equals(name, "task-scaffold", StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InputException($"profile name '{name}' is reserved");
                    }

                    if (!profileNames.Add(name))
                    {
                        throw new InputException($"duplicate profile name '{name}'");
                    }

                    var rawProfilePath = ReadString(Require(profile, "path", "profile"), "profile.path");
                    if (string.IsNullOrWhiteSpace(rawProfilePath) || !Path.IsPathFullyQualified(rawProfilePath))
                    {
                        throw new InputException($"profile '{name}' path must be an absolute resolved directory");
                    }

                    if (!Directory.Exists(rawProfilePath))
                    {
                        throw new InputException($"profile '{name}' directory does not exist: {rawProfilePath}");
                    }

                    var resolvedProfilePath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(rawProfilePath));
                    if (!File.Exists(Path.Combine(resolvedProfilePath, "AGENTS.md")))
                    {
                        throw new InputException($"invalid profile '{name}': AGENTS.md is required");
                    }

                    ValidateSkills(resolvedProfilePath, name);
                    profiles.Add(new ProfileEntry
                    {
                        Name = name,
                        Path = resolvedProfilePath,
                    });
                }
            }

            string? workspaceFile = null;
            if (rootFields.TryGetValue("workspace", out var workspaceElement))
            {
                var workspace = ReadObject(workspaceElement, "workspace", "file");
                var rawFile = ReadString(Require(workspace, "file", "workspace"), "workspace.file");
                if (string.IsNullOrWhiteSpace(rawFile))
                {
                    throw new InputException("workspace.file is required");
                }

                workspaceFile = ResolvePath(rawFile, requestDirectory);
            }

            return new ValidationResult
            {
                Valid = true,
                SchemaVersion = 3,
                TaskKey = key,
                Repositories = repositories,
                PrdPath = prdPath,
                Profiles = profiles,
                WorkspaceFile = workspaceFile,
            };
        }
    }

    private static void ValidateSkills(string profilePath, string profileName)
    {
        var agentsPath = Path.Combine(profilePath, ".agents");
        if (Path.Exists(agentsPath) && !Directory.Exists(agentsPath))
        {
            throw new InputException($"invalid profile '{profileName}': .agents must be a directory");
        }

        var skillsPath = Path.Combine(agentsPath, "skills");
        if (!Directory.Exists(skillsPath))
        {
            if (Path.Exists(skillsPath))
            {
                throw new InputException($"invalid profile '{profileName}': .agents/skills must be a directory");
            }

            return;
        }

        foreach (var skill in Directory.EnumerateFileSystemEntries(skillsPath))
        {
            if (!Directory.Exists(skill) || !File.Exists(Path.Combine(skill, "SKILL.md")))
            {
                throw new InputException($"invalid profile '{profileName}': each entry in .agents/skills must be a skill directory containing SKILL.md");
            }
        }
    }

    private static bool IsValidGitBranch(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = "git",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.ArgumentList.Add("check-ref-format");
        startInfo.ArgumentList.Add("--branch");
        startInfo.ArgumentList.Add(value);

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null)
            {
                throw new OperationalException("failed to start git to validate branch names");
            }

            process.StandardOutput.ReadToEnd();
            process.StandardError.ReadToEnd();
            process.WaitForExit();
            return process.ExitCode == 0;
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            throw new OperationalException("git executable could not be started to validate branch names");
        }
    }

    private static string ResolvePath(string path, string baseDirectory)
    {
        try
        {
            return Path.TrimEndingDirectorySeparator(Path.GetFullPath(path, baseDirectory));
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new InputException($"invalid path '{path}'");
        }
    }

    private static void CheckForDuplicateProperties(JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                var seen = new HashSet<string>(StringComparer.Ordinal);
                foreach (var property in element.EnumerateObject())
                {
                    if (!seen.Add(property.Name))
                    {
                        throw new InputException($"duplicate field '{property.Name}'");
                    }

                    CheckForDuplicateProperties(property.Value);
                }

                break;
            case JsonValueKind.Array:
                foreach (var item in element.EnumerateArray())
                {
                    CheckForDuplicateProperties(item);
                }

                break;
        }
    }

    private static Dictionary<string, JsonElement> ReadObject(JsonElement element, string context, params string[] allowedFields)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new InputException($"{context} must be an object");
        }

        var allowed = new HashSet<string>(allowedFields, StringComparer.Ordinal);
        var fields = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            if (!allowed.Contains(property.Name))
            {
                throw new InputException($"unknown field '{property.Name}' in {context}");
            }

            if (!fields.TryAdd(property.Name, property.Value))
            {
                throw new InputException($"duplicate field '{property.Name}' in {context}");
            }
        }

        return fields;
    }

    private static JsonElement Require(Dictionary<string, JsonElement> fields, string name, string context)
    {
        if (!fields.TryGetValue(name, out var value))
        {
            throw new InputException($"{context} requires '{name}'");
        }

        return value;
    }

    private static string ReadString(JsonElement element, string context)
    {
        if (element.ValueKind != JsonValueKind.String)
        {
            throw new InputException($"{context} must be a string");
        }

        return element.GetString() ?? string.Empty;
    }
}
