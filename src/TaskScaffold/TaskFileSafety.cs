using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

public sealed class CustomFileState
{
    public string Path { get; init; } = string.Empty;

    public bool Exists { get; init; }

    public bool IsFile { get; init; }

    public bool IsReparsePoint { get; init; }

    public string? Sha256 { get; init; }
}

public static class TaskFileSafety
{
    private static readonly string[] ManagedEntries = { "task.json", "PRD.md", "PLAN.md", "STATUS.md", ".ctx", "artifacts", "worktrees" };

    private static readonly Regex WindowsDrivePattern = new(@"^[A-Za-z]:", RegexOptions.CultureInvariant);

    private static readonly Regex WindowsShortNamePattern = new(@"~\d", RegexOptions.CultureInvariant);

    public static StringComparer PathComparer { get; } = OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase
        : StringComparer.Ordinal;

    public static string NormalizeRelativeTaskFilePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new InputException("task file path is required");
        }

        if (Path.IsPathRooted(path) || WindowsDrivePattern.IsMatch(path))
        {
            throw new InputException($"task file path must be relative: '{path}'");
        }

        var segments = path.Replace('\\', '/').Split('/');
        foreach (var segment in segments)
        {
            if (string.IsNullOrWhiteSpace(segment) || segment == "." || segment == ".." ||
                segment.Contains('\0') || segment.Contains(':'))
            {
                throw new InputException($"invalid task file path '{path}'");
            }

            if (OperatingSystem.IsWindows() && WindowsShortNamePattern.IsMatch(segment))
            {
                throw new InputException($"task file path must not use a Windows 8.3 short name: '{path}'");
            }
        }

        return string.Join('/', segments);
    }

    public static string GetCustomFileDestination(string taskPath, string relativePath)
    {
        var taskRoot = Path.GetFullPath(taskPath);
        var platformPath = relativePath.Replace('/', Path.DirectorySeparatorChar);
        var destination = Path.GetFullPath(Path.Combine(taskRoot, platformPath));
        var separator = Path.DirectorySeparatorChar;
        if (!TestPathPrefix(destination, taskRoot + separator))
        {
            throw new InputException($"task file path escapes the task root: '{relativePath}'");
        }

        return destination;
    }

    public static bool TestPathPrefix(string path, string prefix)
    {
        if (path.Length < prefix.Length)
        {
            return false;
        }

        return PathComparer.Equals(path.Substring(0, prefix.Length), prefix);
    }

    public static bool TestCustomPathSafety(string taskPath, string relativePath, bool excludeDestination)
    {
        var segments = relativePath.Split('/');
        var current = Path.GetFullPath(taskPath);
        for (var index = 0; index < segments.Length; index++)
        {
            if (excludeDestination && index == segments.Length - 1)
            {
                break;
            }

            current = Path.GetFullPath(Path.Combine(current, segments[index]));
            if (TryGetAttributes(current, out var attributes) && (attributes & FileAttributes.ReparsePoint) != 0)
            {
                return false;
            }
        }

        return true;
    }

    public static CustomFileState GetCustomFileState(string taskPath, string relativePath)
    {
        var destination = GetCustomFileDestination(taskPath, relativePath);
        if (!TryGetAttributes(destination, out var attributes))
        {
            return new CustomFileState { Path = destination };
        }

        var isReparsePoint = (attributes & FileAttributes.ReparsePoint) != 0;
        var isDirectory = (attributes & FileAttributes.Directory) != 0;
        if (isDirectory || isReparsePoint)
        {
            return new CustomFileState
            {
                Path = destination,
                Exists = true,
                IsFile = false,
                IsReparsePoint = isReparsePoint,
            };
        }

        return new CustomFileState
        {
            Path = destination,
            Exists = true,
            IsFile = true,
            IsReparsePoint = false,
            Sha256 = HashFile(destination),
        };
    }

    public static bool TestManagedTaskFilePath(string? taskPath, string relativePath)
    {
        if (string.IsNullOrWhiteSpace(taskPath))
        {
            var firstSegment = relativePath.Split('/')[0];
            foreach (var entry in ManagedEntries)
            {
                if (StringComparer.OrdinalIgnoreCase.Equals(firstSegment, entry))
                {
                    return true;
                }
            }

            return false;
        }

        var taskRoot = Path.GetFullPath(taskPath);
        var separator = Path.DirectorySeparatorChar;
        var destination = GetCustomFileDestination(taskRoot, relativePath);
        foreach (var entry in ManagedEntries)
        {
            var managedPath = Path.GetFullPath(Path.Combine(taskRoot, entry));
            if (PathComparer.Equals(destination, managedPath) ||
                TestPathPrefix(destination, managedPath + separator) ||
                TestPathPrefix(managedPath, destination + separator))
            {
                return true;
            }
        }

        return false;
    }

    public static void AssertTaskFileDestinations(string taskPath, IEnumerable<string> relativePaths)
    {
        var separator = Path.DirectorySeparatorChar;
        var resolved = new List<(string RelativePath, string Destination)>();
        foreach (var relativePath in relativePaths)
        {
            var destination = GetCustomFileDestination(taskPath, relativePath);
            if (TestManagedTaskFilePath(taskPath, relativePath))
            {
                throw new InputException($"task file path '{relativePath}' collides with a scaffold-managed path");
            }

            foreach (var existing in resolved)
            {
                if (PathComparer.Equals(existing.Destination, destination))
                {
                    throw new InputException($"duplicate task file path '{relativePath}'");
                }

                if (TestPathPrefix(destination, existing.Destination + separator) ||
                    TestPathPrefix(existing.Destination, destination + separator))
                {
                    throw new InputException($"task file path '{relativePath}' conflicts with '{existing.RelativePath}'");
                }
            }

            resolved.Add((relativePath, destination));
        }
    }

    public static bool TestTaskFilePathIsAncestor(string ancestor, string descendant)
    {
        var ancestorSegments = ancestor.Split('/');
        var descendantSegments = descendant.Split('/');
        if (ancestorSegments.Length >= descendantSegments.Length)
        {
            return false;
        }

        for (var index = 0; index < ancestorSegments.Length; index++)
        {
            if (!PathComparer.Equals(ancestorSegments[index], descendantSegments[index]))
            {
                return false;
            }
        }

        return true;
    }

    public static bool TestTaskPathSafety(string tasksRoot, string taskKey, string? repositoryName = null)
    {
        var tasksRootPath = Path.GetFullPath(tasksRoot);
        var taskPath = Path.GetFullPath(Path.Combine(tasksRootPath, taskKey));
        var worktreesPath = Path.GetFullPath(Path.Combine(taskPath, "worktrees"));
        var separator = Path.DirectorySeparatorChar;
        if (!taskPath.StartsWith(tasksRootPath + separator, StringComparison.Ordinal) ||
            !worktreesPath.StartsWith(taskPath + separator, StringComparison.Ordinal))
        {
            return false;
        }

        var paths = new List<string> { tasksRootPath, taskPath, worktreesPath };
        if (!string.IsNullOrEmpty(repositoryName))
        {
            paths.Add(Path.GetFullPath(Path.Combine(tasksRootPath, taskKey, "worktrees", repositoryName)));
        }

        foreach (var path in paths)
        {
            if (TryGetAttributes(path, out var attributes) && (attributes & FileAttributes.ReparsePoint) != 0)
            {
                return false;
            }
        }

        return true;
    }

    public static string NormalizeTaskProfilePath(string path)
    {
        return Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
    }

    public static byte[] GetTaskFileContentBytes(string content)
    {
        return new UTF8Encoding(false).GetBytes(content);
    }

    public static string GetTaskFileContentHash(string content)
    {
        var bytes = GetTaskFileContentBytes(content);
        return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    }

    public static string HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    public static bool TryGetAttributes(string path, out FileAttributes attributes)
    {
        try
        {
            attributes = File.GetAttributes(path);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or PathTooLongException)
        {
            attributes = default;
            return false;
        }
    }
}
