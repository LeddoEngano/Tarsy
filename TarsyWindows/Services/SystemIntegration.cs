using System;
using Microsoft.Win32;

namespace TarsyWindows.Services;

/// <summary>
/// System integration — sleep/wake detection, power events.
/// Mirrors macOS sleep/wake handling via IOKit.
/// </summary>
public class SystemIntegration : IDisposable
{
    private readonly Action _onWake;
    private readonly Action _onSleep;
    private bool _isSubscribed;

    public SystemIntegration(Action onWake, Action onSleep)
    {
        _onWake = onWake;
        _onSleep = onSleep;
    }

    /// <summary>
    /// Start listening for power mode changes (W17.1).
    /// </summary>
    public void Start()
    {
        if (_isSubscribed) return;

        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        _isSubscribed = true;
        Console.WriteLine("[System] Power mode monitoring started");
    }

    /// <summary>
    /// Stop listening for power mode changes.
    /// </summary>
    public void Stop()
    {
        if (!_isSubscribed) return;

        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        _isSubscribed = false;
        Console.WriteLine("[System] Power mode monitoring stopped");
    }

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        switch (e.Mode)
        {
            case PowerModes.Resume:
                Console.WriteLine("[System] Wake detected — re-acquiring resources");
                _onWake();
                break;

            case PowerModes.Suspend:
                Console.WriteLine("[System] Sleep detected");
                _onSleep();
                break;

            case PowerModes.StatusChange:
                // Battery/AC power change — no action needed
                break;
        }
    }

    public void Dispose()
    {
        Stop();
    }
}
