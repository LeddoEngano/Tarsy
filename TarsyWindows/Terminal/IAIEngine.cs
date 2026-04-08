using System;
using System.Threading.Tasks;

namespace TarsyWindows.Terminal;

/// <summary>
/// Interface for AI coding engines — mirrors macOS AIEngineProtocol.
/// </summary>
public interface IAIEngine : IDisposable
{
    string SessionId { get; }
    string EngineName { get; }
    bool IsRunning { get; }

    Task Start(string workingDirectory, string? model = null);
    Task SendMessage(string message);
    Task RespondToQuestion(string response);
    void Interrupt();
    void Terminate();
}
