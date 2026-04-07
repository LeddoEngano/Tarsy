using System;
using System.Runtime.InteropServices;

namespace TarsyWindows.Services;

/// <summary>
/// Prevents Windows from sleeping while Tarsy is running.
/// Uses SetThreadExecutionState Win32 API.
/// </summary>
public static class SleepPrevention
{
    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint esFlags);

    private const uint ES_CONTINUOUS = 0x80000000;
    private const uint ES_SYSTEM_REQUIRED = 0x00000001;
    private const uint ES_DISPLAY_REQUIRED = 0x00000002;

    public static void Prevent()
    {
        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
        Console.WriteLine("[Sleep] Prevention enabled");
    }

    public static void Release()
    {
        SetThreadExecutionState(ES_CONTINUOUS);
        Console.WriteLine("[Sleep] Prevention released");
    }
}
