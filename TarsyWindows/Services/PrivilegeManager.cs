using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace TarsyWindows.Services;

/// <summary>
/// Privilege escalation via UAC — mirrors macOS SudoPasswordManager.
/// Unlike macOS where sudo prompts are intercepted, Windows UAC runs on a secure desktop.
/// This service validates commands against a whitelist and can run them elevated via runas.
/// </summary>
public static class PrivilegeManager
{
    // ── Command Whitelist (W15.2) ──

    private static readonly Dictionary<string, HashSet<string>> Whitelist = new()
    {
        ["packageManagers"] = new(StringComparer.OrdinalIgnoreCase)
        {
            "npm", "npx", "pnpm", "yarn", "bun", "pip", "pip3",
            "cargo", "go", "gem", "composer", "dotnet", "nuget",
            "choco", "scoop", "winget",
        },
        ["filePermissions"] = new(StringComparer.OrdinalIgnoreCase)
        {
            "icacls", "takeown", "attrib",
        },
        ["processControl"] = new(StringComparer.OrdinalIgnoreCase)
        {
            "taskkill", "tasklist", "sc", "net",
        },
        ["devTools"] = new(StringComparer.OrdinalIgnoreCase)
        {
            "git", "node", "python", "python3", "ruby", "java", "javac",
            "docker", "docker-compose", "kubectl", "terraform",
            "make", "cmake", "msbuild", "gradle",
        },
    };

    // ── Dangerous Patterns (W15.3) ──

    private static readonly Regex[] DangerousPatterns = new[]
    {
        new Regex(@"[;&|]{1,2}", RegexOptions.Compiled),      // ; && || |
        new Regex(@"\$\(", RegexOptions.Compiled),              // $(...)
        new Regex(@"\$\{", RegexOptions.Compiled),              // ${...}
        new Regex(@"`", RegexOptions.Compiled),                 // backtick substitution
        new Regex(@">\s*/dev/", RegexOptions.Compiled),         // redirect to /dev/
        new Regex(@">\s*\\\\", RegexOptions.Compiled),          // redirect to UNC
        new Regex(@"[><]{2,}", RegexOptions.Compiled),          // >> << etc.
        new Regex(@"format\s+[a-z]:", RegexOptions.IgnoreCase | RegexOptions.Compiled), // format C:
        new Regex(@"del\s+/[sfq]", RegexOptions.IgnoreCase | RegexOptions.Compiled),   // del /s /f /q
        new Regex(@"rmdir\s+/s", RegexOptions.IgnoreCase | RegexOptions.Compiled),     // rmdir /s
    };

    /// <summary>
    /// Validate a command against the whitelist.
    /// Returns (allowed, reason).
    /// </summary>
    public static (bool allowed, string reason) ValidateCommand(string command)
    {
        if (string.IsNullOrWhiteSpace(command))
            return (false, "Empty command");

        var trimmed = command.Trim();

        // Check for dangerous patterns
        foreach (var pattern in DangerousPatterns)
        {
            if (pattern.IsMatch(trimmed))
                return (false, $"Dangerous pattern detected: {pattern}");
        }

        // Extract the executable name
        var executable = ExtractExecutable(trimmed);
        if (string.IsNullOrEmpty(executable))
            return (false, "Could not determine executable");

        // Strip .exe/.cmd/.bat extension for matching
        var baseName = Path.GetFileNameWithoutExtension(executable);

        // Check whitelist
        foreach (var (category, commands) in Whitelist)
        {
            if (commands.Contains(baseName))
                return (true, $"Allowed ({category})");
        }

        return (false, $"Command '{baseName}' not in whitelist. Elevated commands must be from: " +
            string.Join(", ", Whitelist.Values.SelectMany(v => v).OrderBy(v => v).Distinct()));
    }

    /// <summary>
    /// Run a command elevated using runas verb.
    /// This triggers a UAC prompt on the Windows machine.
    /// </summary>
    public static async Task<(bool success, string output)> RunElevated(
        string command, string workingDirectory, int timeoutMs = 30000)
    {
        var (allowed, reason) = ValidateCommand(command);
        if (!allowed)
            return (false, $"Command rejected: {reason}");

        var executable = ExtractExecutable(command);
        var arguments = ExtractArguments(command);

        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = executable,
                Arguments = arguments,
                WorkingDirectory = workingDirectory,
                Verb = "runas", // Triggers UAC prompt
                UseShellExecute = true, // Required for runas
                CreateNoWindow = false, // UAC dialog needs a window
            };

            process.Start();

            using var cts = new CancellationTokenSource(timeoutMs);
            await process.WaitForExitAsync(cts.Token);

            return process.ExitCode == 0
                ? (true, $"Command completed (exit code {process.ExitCode})")
                : (false, $"Command failed (exit code {process.ExitCode})");
        }
        catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            // ERROR_CANCELLED — user declined UAC prompt
            return (false, "UAC elevation was declined by the user");
        }
        catch (Exception ex)
        {
            return (false, $"Elevation error: {ex.Message}");
        }
    }

    /// <summary>
    /// Run a whitelisted command without elevation (normal execution with output capture).
    /// </summary>
    public static async Task<(bool success, string output)> RunWhitelisted(
        string command, string workingDirectory, int timeoutMs = 30000)
    {
        var (allowed, reason) = ValidateCommand(command);
        if (!allowed)
            return (false, $"Command rejected: {reason}");

        var executable = ExtractExecutable(command);
        var arguments = ExtractArguments(command);

        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = executable,
                WorkingDirectory = workingDirectory,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };

            // Use ArgumentList for safe argument passing
            foreach (var arg in SplitArguments(arguments))
                process.StartInfo.ArgumentList.Add(arg);

            process.Start();

            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();

            using var cts = new CancellationTokenSource(timeoutMs);

            if (!Task.WaitAll(new Task[] { stdoutTask, stderrTask }, timeoutMs))
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                return (false, "Command timed out");
            }

            await process.WaitForExitAsync(cts.Token);

            var stdout = stdoutTask.IsCompletedSuccessfully ? stdoutTask.Result : "";
            var stderr = stderrTask.IsCompletedSuccessfully ? stderrTask.Result : "";

            var output = new StringBuilder();
            if (!string.IsNullOrEmpty(stdout)) output.Append(stdout);
            if (!string.IsNullOrEmpty(stderr))
            {
                if (output.Length > 0) output.AppendLine();
                output.Append(stderr);
            }

            return (process.ExitCode == 0, output.ToString());
        }
        catch (Exception ex)
        {
            return (false, $"Execution error: {ex.Message}");
        }
    }

    /// <summary>
    /// Handle a sudo:request from the client — validate and execute.
    /// </summary>
    public static async Task<(bool success, string output)> HandleSudoRequest(
        string command, string workingDirectory)
    {
        var (allowed, reason) = ValidateCommand(command);
        if (!allowed)
            return (false, reason);

        // On Windows, try normal execution first — most dev commands don't need elevation
        var result = await RunWhitelisted(command, workingDirectory);

        if (!result.success && result.output.Contains("Access is denied", StringComparison.OrdinalIgnoreCase))
        {
            // Needs elevation — inform client
            return (false, "This command requires administrator privileges. " +
                "Please run Tarsy as administrator or approve the UAC prompt on the Windows machine.");
        }

        return result;
    }

    // ── Helpers ──

    private static string ExtractExecutable(string command)
    {
        var trimmed = command.Trim();

        // Handle quoted executable
        if (trimmed.StartsWith('"'))
        {
            var endQuote = trimmed.IndexOf('"', 1);
            return endQuote > 0 ? trimmed[1..endQuote] : trimmed[1..];
        }

        var spaceIdx = trimmed.IndexOf(' ');
        return spaceIdx > 0 ? trimmed[..spaceIdx] : trimmed;
    }

    private static string ExtractArguments(string command)
    {
        var trimmed = command.Trim();

        if (trimmed.StartsWith('"'))
        {
            var endQuote = trimmed.IndexOf('"', 1);
            return endQuote > 0 && endQuote + 1 < trimmed.Length
                ? trimmed[(endQuote + 2)..].Trim()
                : "";
        }

        var spaceIdx = trimmed.IndexOf(' ');
        return spaceIdx > 0 ? trimmed[(spaceIdx + 1)..].Trim() : "";
    }

    private static string[] SplitArguments(string arguments)
    {
        if (string.IsNullOrWhiteSpace(arguments))
            return Array.Empty<string>();

        var args = new List<string>();
        var current = new StringBuilder();
        var inQuotes = false;

        for (int i = 0; i < arguments.Length; i++)
        {
            var c = arguments[i];

            if (c == '"')
            {
                inQuotes = !inQuotes;
            }
            else if (c == ' ' && !inQuotes)
            {
                if (current.Length > 0)
                {
                    args.Add(current.ToString());
                    current.Clear();
                }
            }
            else
            {
                current.Append(c);
            }
        }

        if (current.Length > 0)
            args.Add(current.ToString());

        return args.ToArray();
    }
}
