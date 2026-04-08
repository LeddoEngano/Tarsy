using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace TarsyWindows.Services;

/// <summary>
/// Git operations — executes git.exe with array-based arguments.
/// Mirrors macOS DaemonManager git handlers.
/// </summary>
public static class GitService
{
    private static string? _gitPath;

    /// <summary>
    /// Find git.exe — checks PATH, then common install locations.
    /// </summary>
    public static string? FindGit()
    {
        if (_gitPath != null) return _gitPath;

        // Try PATH first via where.exe
        try
        {
            var result = RunProcess("where.exe", new[] { "git.exe" }, null, 5000);
            if (result.exitCode == 0)
            {
                var firstLine = result.output.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim();
                if (firstLine != null && File.Exists(firstLine))
                {
                    _gitPath = firstLine;
                    return _gitPath;
                }
            }
        }
        catch { }

        // Check common locations
        string[] commonPaths =
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Git", "bin", "git.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Git", "bin", "git.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Git", "bin", "git.exe"),
            @"C:\Program Files\Git\bin\git.exe",
            @"C:\Program Files (x86)\Git\bin\git.exe",
        };

        foreach (var p in commonPaths)
        {
            if (File.Exists(p))
            {
                _gitPath = p;
                return _gitPath;
            }
        }

        return null;
    }

    /// <summary>
    /// Create a checkpoint (stash or commit) for safety before AI operations.
    /// </summary>
    public static async Task<(bool success, string message)> Checkpoint(string workingDir, string label)
    {
        var git = FindGit();
        if (git == null) return (false, "git not found");

        // Check for changes
        var status = await RunGitAsync(git, workingDir, "status", "--porcelain");
        if (string.IsNullOrWhiteSpace(status.output))
            return (true, "No changes to checkpoint");

        // Stage all and create a checkpoint commit
        await RunGitAsync(git, workingDir, "add", "-A");
        var commitMsg = $"[tarsy-checkpoint] {label} — {DateTime.UtcNow:yyyy-MM-dd HH:mm:ss UTC}";
        var result = await RunGitAsync(git, workingDir, "commit", "-m", commitMsg, "--no-verify");

        return result.exitCode == 0
            ? (true, $"Checkpoint created: {commitMsg}")
            : (false, result.output);
    }

    /// <summary>
    /// Get diff (staged + unstaged changes).
    /// </summary>
    public static async Task<string> Diff(string workingDir)
    {
        var git = FindGit();
        if (git == null) return "git not found";

        var unstaged = await RunGitAsync(git, workingDir, "diff");
        var staged = await RunGitAsync(git, workingDir, "diff", "--cached");

        var sb = new StringBuilder();
        if (!string.IsNullOrWhiteSpace(staged.output))
        {
            sb.AppendLine("=== Staged Changes ===");
            sb.AppendLine(staged.output);
        }
        if (!string.IsNullOrWhiteSpace(unstaged.output))
        {
            sb.AppendLine("=== Unstaged Changes ===");
            sb.AppendLine(unstaged.output);
        }
        if (sb.Length == 0)
            sb.AppendLine("No changes");

        return sb.ToString();
    }

    /// <summary>
    /// Rollback to a specific commit (hard reset).
    /// </summary>
    public static async Task<(bool success, string message)> Rollback(string workingDir, string commitHash)
    {
        var git = FindGit();
        if (git == null) return (false, "git not found");

        var result = await RunGitAsync(git, workingDir, "reset", "--hard", commitHash);
        return result.exitCode == 0
            ? (true, $"Rolled back to {commitHash}")
            : (false, result.output);
    }

    /// <summary>
    /// Get commit history.
    /// </summary>
    public static async Task<string> History(string workingDir, int count = 50)
    {
        var git = FindGit();
        if (git == null) return "git not found";

        var result = await RunGitAsync(git, workingDir,
            "log", $"-{count}", "--pretty=format:%H|%h|%an|%ae|%ai|%s", "--no-merges");
        return result.output;
    }

    /// <summary>
    /// Get diff for a specific file.
    /// </summary>
    public static async Task<string> FileDiff(string workingDir, string filePath)
    {
        var git = FindGit();
        if (git == null) return "git not found";

        var result = await RunGitAsync(git, workingDir, "diff", "HEAD", "--", filePath);
        if (string.IsNullOrWhiteSpace(result.output))
        {
            // Try staged diff
            result = await RunGitAsync(git, workingDir, "diff", "--cached", "--", filePath);
        }
        return string.IsNullOrWhiteSpace(result.output) ? "No changes for this file" : result.output;
    }

    /// <summary>
    /// List branches with current branch indicator.
    /// </summary>
    public static async Task<string> Branches(string workingDir)
    {
        var git = FindGit();
        if (git == null) return "git not found";

        var result = await RunGitAsync(git, workingDir, "branch", "-a", "--format=%(refname:short)|%(HEAD)|%(upstream:short)");
        return result.output;
    }

    /// <summary>
    /// Checkout a branch.
    /// </summary>
    public static async Task<(bool success, string message)> Checkout(string workingDir, string branchName)
    {
        var git = FindGit();
        if (git == null) return (false, "git not found");

        var result = await RunGitAsync(git, workingDir, "checkout", branchName);
        return result.exitCode == 0
            ? (true, $"Switched to {branchName}")
            : (false, result.output);
    }

    /// <summary>
    /// Pull from remote.
    /// </summary>
    public static async Task<(bool success, string message)> Pull(string workingDir)
    {
        var git = FindGit();
        if (git == null) return (false, "git not found");

        var result = await RunGitAsync(git, workingDir, "pull", "--ff-only");
        return result.exitCode == 0
            ? (true, result.output)
            : (false, result.output);
    }

    /// <summary>
    /// Stage files.
    /// </summary>
    public static async Task<(bool success, string message)> Stage(string workingDir, string[] files)
    {
        var git = FindGit();
        if (git == null) return (false, "git not found");

        var args = new List<string> { "add", "--" };
        args.AddRange(files);

        var result = await RunGitAsync(git, workingDir, args.ToArray());
        return result.exitCode == 0
            ? (true, $"Staged {files.Length} file(s)")
            : (false, result.output);
    }

    /// <summary>
    /// Discard changes for specific files.
    /// </summary>
    public static async Task<(bool success, string message)> Discard(string workingDir, string[] files)
    {
        var git = FindGit();
        if (git == null) return (false, "git not found");

        var args = new List<string> { "checkout", "--" };
        args.AddRange(files);

        var result = await RunGitAsync(git, workingDir, args.ToArray());
        return result.exitCode == 0
            ? (true, $"Discarded changes for {files.Length} file(s)")
            : (false, result.output);
    }

    // ── Helpers ──

    private static Task<(int exitCode, string output)> RunGitAsync(string gitPath, string workingDir, params string[] args)
    {
        return Task.Run(() => RunProcess(gitPath, args, workingDir, 30000));
    }

    private static (int exitCode, string output) RunProcess(string fileName, string[] args, string? workingDir, int timeoutMs)
    {
        using var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = fileName,
            WorkingDirectory = workingDir ?? "",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };

        foreach (var arg in args)
            process.StartInfo.ArgumentList.Add(arg);

        process.Start();

        // Read both streams concurrently to avoid deadlock
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();

        if (!Task.WaitAll(new Task[] { stdoutTask, stderrTask }, timeoutMs))
        {
            try { process.Kill(entireProcessTree: true); } catch { }
        }
        process.WaitForExit(timeoutMs);

        var output = new StringBuilder();
        var stdout = stdoutTask.IsCompletedSuccessfully ? stdoutTask.Result : "";
        var stderr = stderrTask.IsCompletedSuccessfully ? stderrTask.Result : "";
        output.Append(stdout);
        if (!string.IsNullOrEmpty(stderr))
        {
            if (output.Length > 0) output.AppendLine();
            output.Append(stderr);
        }

        return (process.ExitCode, output.ToString());
    }
}
