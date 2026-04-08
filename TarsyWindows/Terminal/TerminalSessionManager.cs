using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;

namespace TarsyWindows.Terminal;

/// <summary>
/// Manages multiple terminal sessions — mirrors macOS TerminalSessionManager.
/// </summary>
public class TerminalSessionManager : IDisposable
{
    private readonly ConcurrentDictionary<string, TerminalSession> _sessions = new();
    private readonly Action<string, string> _onOutput; // (sessionId, data)
    private readonly Action<string> _onExit; // (sessionId)

    public TerminalSessionManager(Action<string, string> onOutput, Action<string> onExit)
    {
        _onOutput = onOutput;
        _onExit = onExit;
    }

    /// <summary>
    /// Create and start a new terminal session.
    /// </summary>
    public string Create(string? workingDirectory = null)
    {
        var sessionId = Guid.NewGuid().ToString();
        var session = new TerminalSession(sessionId, workingDirectory, _onOutput, (id) =>
        {
            _sessions.TryRemove(id, out _);
            _onExit(id);
        });

        _sessions.TryAdd(sessionId, session);
        session.Start();

        Console.WriteLine($"[Terminal] Created session {sessionId}");
        return sessionId;
    }

    /// <summary>
    /// Send input to a terminal session.
    /// </summary>
    public bool SendInput(string sessionId, string data)
    {
        if (_sessions.TryGetValue(sessionId, out var session))
        {
            session.WriteInput(data);
            return true;
        }
        return false;
    }

    /// <summary>
    /// Interrupt (Ctrl+C) a terminal session.
    /// </summary>
    public bool Interrupt(string sessionId)
    {
        if (_sessions.TryGetValue(sessionId, out var session))
        {
            session.Interrupt();
            return true;
        }
        return false;
    }

    /// <summary>
    /// Close and destroy a terminal session.
    /// </summary>
    public bool Close(string sessionId)
    {
        if (_sessions.TryRemove(sessionId, out var session))
        {
            session.Dispose();
            Console.WriteLine($"[Terminal] Closed session {sessionId}");
            return true;
        }
        return false;
    }

    /// <summary>
    /// List all active sessions.
    /// </summary>
    public List<Dictionary<string, string>> ListSessions()
    {
        return _sessions.Values
            .Where(s => s.IsRunning)
            .Select(s => new Dictionary<string, string>
            {
                ["sessionId"] = s.SessionId,
                ["workingDirectory"] = s.WorkingDirectory ?? "",
                ["running"] = s.IsRunning.ToString(),
            })
            .ToList();
    }

    public void Dispose()
    {
        foreach (var (_, session) in _sessions)
        {
            session.Dispose();
        }
        _sessions.Clear();
    }
}
