using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace TarsyWindows.Stream;

/// <summary>
/// Remote input injection via Win32 SendInput — mirrors macOS RemoteInputService.
/// Accepts relative coordinates (0-1) and maps to absolute screen coordinates.
/// </summary>
public static class RemoteInputService
{
    // ── Win32 Interop ──

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    private const int SM_CXSCREEN = 0;
    private const int SM_CYSCREEN = 1;

    private const uint INPUT_MOUSE = 0;
    private const uint INPUT_KEYBOARD = 1;

    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_WHEEL = 0x0800;
    private const uint MOUSEEVENTF_HWHEEL = 0x1000;
    private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;

    private const uint KEYEVENTF_UNICODE = 0x0004;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    private const ushort VK_BACK = 0x08;
    private const ushort VK_RETURN = 0x0D;
    private const ushort VK_TAB = 0x09;
    private const ushort VK_ESCAPE = 0x1B;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public INPUTUNION u;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public int mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    // ── Coordinate mapping ──

    private static (int x, int y) RelativeToAbsolute(double relX, double relY)
    {
        var screenWidth = GetSystemMetrics(SM_CXSCREEN);
        var screenHeight = GetSystemMetrics(SM_CYSCREEN);

        // Absolute coordinates for SendInput use 0-65535 range
        var absX = (int)(relX * 65535.0);
        var absY = (int)(relY * 65535.0);

        return (absX, absY);
    }

    private static void MoveTo(double relX, double relY)
    {
        var (absX, absY) = RelativeToAbsolute(relX, relY);
        var input = new INPUT
        {
            type = INPUT_MOUSE,
            u = new INPUTUNION
            {
                mi = new MOUSEINPUT
                {
                    dx = absX,
                    dy = absY,
                    dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE,
                }
            }
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    // ── Mouse actions ──

    /// <summary>
    /// Single tap (left click) at relative coordinates.
    /// </summary>
    public static async Task Tap(double relX, double relY)
    {
        MoveTo(relX, relY);
        await Task.Delay(10);

        SendMouseEvent(MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE, relX, relY);
        await Task.Delay(30);
        SendMouseEvent(MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE, relX, relY);
    }

    /// <summary>
    /// Double-tap (double click) at relative coordinates.
    /// </summary>
    public static async Task DoubleTap(double relX, double relY)
    {
        await Tap(relX, relY);
        await Task.Delay(20);
        await Tap(relX, relY);
    }

    /// <summary>
    /// Long-press (right click) at relative coordinates.
    /// </summary>
    public static async Task LongPress(double relX, double relY)
    {
        MoveTo(relX, relY);
        await Task.Delay(10);

        SendMouseEvent(MOUSEEVENTF_RIGHTDOWN | MOUSEEVENTF_ABSOLUTE, relX, relY);
        await Task.Delay(30);
        SendMouseEvent(MOUSEEVENTF_RIGHTUP | MOUSEEVENTF_ABSOLUTE, relX, relY);
    }

    /// <summary>
    /// Drag from one point to another with interpolated steps.
    /// </summary>
    public static async Task Drag(double startX, double startY, double endX, double endY)
    {
        MoveTo(startX, startY);
        await Task.Delay(10);

        SendMouseEvent(MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE, startX, startY);

        // 10 interpolated move steps
        const int steps = 10;
        for (int i = 1; i <= steps; i++)
        {
            var t = (double)i / steps;
            var x = startX + (endX - startX) * t;
            var y = startY + (endY - startY) * t;
            MoveTo(x, y);
            await Task.Delay(10);
        }

        SendMouseEvent(MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE, endX, endY);
    }

    /// <summary>
    /// Scroll at position. deltaX/deltaY in abstract units (multiplied by 3 for WHEEL_DELTA=120).
    /// </summary>
    public static void Scroll(double relX, double relY, double deltaX, double deltaY)
    {
        MoveTo(relX, relY);

        var size = Marshal.SizeOf<INPUT>();

        // Vertical scroll
        if (Math.Abs(deltaY) > 0.001)
        {
            var input = new INPUT
            {
                type = INPUT_MOUSE,
                u = new INPUTUNION
                {
                    mi = new MOUSEINPUT
                    {
                        mouseData = (int)(deltaY * 120 * 3),
                        dwFlags = MOUSEEVENTF_WHEEL,
                    }
                }
            };
            SendInput(1, new[] { input }, size);
        }

        // Horizontal scroll
        if (Math.Abs(deltaX) > 0.001)
        {
            var input = new INPUT
            {
                type = INPUT_MOUSE,
                u = new INPUTUNION
                {
                    mi = new MOUSEINPUT
                    {
                        mouseData = (int)(deltaX * 120 * 3),
                        dwFlags = MOUSEEVENTF_HWHEEL,
                    }
                }
            };
            SendInput(1, new[] { input }, size);
        }
    }

    // ── Keyboard ──

    /// <summary>
    /// Type text using KEYEVENTF_UNICODE for full UTF-16 support.
    /// Special keys: backspace, enter, tab, escape handled via VK codes.
    /// </summary>
    public static async Task TypeText(string text)
    {
        var size = Marshal.SizeOf<INPUT>();

        foreach (var ch in text)
        {
            ushort vk = ch switch
            {
                '\b' => VK_BACK,
                '\r' or '\n' => VK_RETURN,
                '\t' => VK_TAB,
                '\x1b' => VK_ESCAPE,
                _ => 0,
            };

            if (vk != 0)
            {
                // Use virtual key code
                var down = new INPUT
                {
                    type = INPUT_KEYBOARD,
                    u = new INPUTUNION { ki = new KEYBDINPUT { wVk = vk } }
                };
                var up = new INPUT
                {
                    type = INPUT_KEYBOARD,
                    u = new INPUTUNION { ki = new KEYBDINPUT { wVk = vk, dwFlags = KEYEVENTF_KEYUP } }
                };
                SendInput(2, new[] { down, up }, size);
            }
            else
            {
                // Use Unicode scan code
                var down = new INPUT
                {
                    type = INPUT_KEYBOARD,
                    u = new INPUTUNION { ki = new KEYBDINPUT { wScan = ch, dwFlags = KEYEVENTF_UNICODE } }
                };
                var up = new INPUT
                {
                    type = INPUT_KEYBOARD,
                    u = new INPUTUNION { ki = new KEYBDINPUT { wScan = ch, dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP } }
                };
                SendInput(2, new[] { down, up }, size);
            }

            await Task.Delay(3); // 3ms between chars
        }
    }

    // ── Helper ──

    private static void SendMouseEvent(uint flags, double relX, double relY)
    {
        var (absX, absY) = RelativeToAbsolute(relX, relY);
        var input = new INPUT
        {
            type = INPUT_MOUSE,
            u = new INPUTUNION
            {
                mi = new MOUSEINPUT
                {
                    dx = absX,
                    dy = absY,
                    dwFlags = flags,
                }
            }
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }
}
