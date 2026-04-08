using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace TarsyWindows.Stream;

/// <summary>
/// Screen capture service using GDI+ BitBlt as a reliable baseline.
/// Windows.Graphics.Capture (WinRT) requires additional COM interop and a DispatcherQueue,
/// so we use GDI+ for maximum compatibility across Windows 10/11 and RDP sessions.
///
/// Captures frames as raw bitmaps, then pipes to ffmpeg for H.264 encoding.
/// This approach works on any Windows machine with ffmpeg available.
/// </summary>
public class ScreenCaptureService : IDisposable
{
    // ── Win32 Interop ──

    [DllImport("user32.dll")]
    private static extern IntPtr GetDesktopWindow();

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindowDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr hDC);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleBitmap(IntPtr hDC, int nWidth, int nHeight);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);

    [DllImport("gdi32.dll")]
    private static extern bool BitBlt(IntPtr hdcDest, int nXDest, int nYDest, int nWidth, int nHeight,
        IntPtr hdcSrc, int nXSrc, int nYSrc, uint dwRop);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(IntPtr hDC);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    private const uint SRCCOPY = 0x00CC0020;
    private const int SM_CXSCREEN = 0;
    private const int SM_CYSCREEN = 1;

    // ── State ──

    private CancellationTokenSource? _cts;
    private Process? _ffmpeg;
    private readonly Action<byte[], bool> _onFrame; // (h264Data, isKeyframe)
    private bool _isCapturing;

    // Adaptive bitrate
    private int _targetFps = 24;
    private int _targetBitrate = 3_000_000; // 3 Mbps default (relay)
    private int _initialBitrate = 3_000_000;
    private double _scale = 0.85;
    private int _frameCount;
    private int _droppedFrames;

    public bool IsCapturing => _isCapturing;

    public ScreenCaptureService(Action<byte[], bool> onFrame)
    {
        _onFrame = onFrame;
    }

    /// <summary>
    /// Start capturing with given quality parameters.
    /// </summary>
    public void Start(bool isLan = false)
    {
        if (_isCapturing) return;

        if (isLan)
        {
            _targetFps = 30;
            _targetBitrate = 6_000_000;
            _scale = 1.0;
        }
        else
        {
            _targetFps = 24;
            _targetBitrate = 3_000_000;
            _scale = 0.85;
        }

        _isCapturing = true;
        _initialBitrate = _targetBitrate;
        _cts = new CancellationTokenSource();
        _frameCount = 0;
        _droppedFrames = 0;

        _ = CaptureLoop(_cts.Token);
    }

    public void Stop()
    {
        _isCapturing = false;
        _cts?.Cancel();
        StopFfmpeg();
    }

    /// <summary>
    /// Take a single screenshot, returns JPEG bytes.
    /// </summary>
    public byte[]? TakeScreenshot()
    {
        try
        {
            using var bitmap = CaptureScreen();
            if (bitmap == null) return null;

            using var ms = new MemoryStream();
            var jpegEncoder = GetJpegEncoder();
            using var qualityParam = new EncoderParameters(1);
            qualityParam.Param[0] = new EncoderParameter(Encoder.Quality, 70L);

            bitmap.Save(ms, jpegEncoder, qualityParam);
            return ms.ToArray();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[ScreenCapture] Screenshot error: {ex.Message}");
            return null;
        }
    }

    public void Dispose()
    {
        Stop();
        _cts?.Dispose();
    }

    // ── Capture Loop ──

    private async Task CaptureLoop(CancellationToken ct)
    {
        Console.WriteLine($"[ScreenCapture] Starting capture: {_targetFps}fps, {_targetBitrate / 1000}kbps, scale={_scale}");

        var ffmpegPath = FindFfmpeg();
        if (ffmpegPath == null)
        {
            Console.WriteLine("[ScreenCapture] ffmpeg not found — falling back to JPEG frame mode");
            await JpegFallbackLoop(ct);
            return;
        }

        var screenWidth = GetSystemMetrics(SM_CXSCREEN);
        var screenHeight = GetSystemMetrics(SM_CYSCREEN);
        var outWidth = (int)(screenWidth * _scale) / 2 * 2; // ensure even
        var outHeight = (int)(screenHeight * _scale) / 2 * 2;

        // Start ffmpeg for H.264 encoding
        _ffmpeg = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = ffmpegPath,
                Arguments = $"-f rawvideo -pix_fmt bgra -s {screenWidth}x{screenHeight} -r {_targetFps} -i pipe:0 " +
                    $"-c:v libx264 -preset ultrafast -tune zerolatency " +
                    $"-b:v {_targetBitrate} -maxrate {_targetBitrate * 3} -bufsize {_targetBitrate} " +
                    $"-vf scale={outWidth}:{outHeight} " +
                    $"-g {_targetFps * 2} -keyint_min {_targetFps} " +
                    $"-f h264 -bsf:v dump_extra pipe:1",
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            }
        };

        _ffmpeg.Start();

        // Read H.264 output
        _ = ReadH264Output(_ffmpeg.StandardOutput.BaseStream, ct);
        // Consume stderr to prevent pipe blocking
        _ = Task.Run(async () => { try { await _ffmpeg.StandardError.ReadToEndAsync(ct); } catch { } }, ct);

        var frameInterval = TimeSpan.FromMilliseconds(1000.0 / _targetFps);

        try
        {
            while (!ct.IsCancellationRequested && _isCapturing)
            {
                var sw = Stopwatch.StartNew();

                try
                {
                    using var bitmap = CaptureScreen();
                    if (bitmap != null)
                    {
                        var bmpData = bitmap.LockBits(
                            new Rectangle(0, 0, bitmap.Width, bitmap.Height),
                            ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);

                        var stride = bmpData.Stride;
                        var bytes = new byte[stride * bitmap.Height];
                        Marshal.Copy(bmpData.Scan0, bytes, 0, bytes.Length);
                        bitmap.UnlockBits(bmpData);

                        await _ffmpeg.StandardInput.BaseStream.WriteAsync(bytes, 0, bytes.Length, ct);
                        await _ffmpeg.StandardInput.BaseStream.FlushAsync(ct);
                        _frameCount++;
                    }
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    _droppedFrames++;
                    AdjustBitrate();
                }

                var elapsed = sw.Elapsed;
                if (elapsed < frameInterval)
                {
                    await Task.Delay(frameInterval - elapsed, ct);
                }
            }
        }
        catch (OperationCanceledException) { }

        StopFfmpeg();
        Console.WriteLine($"[ScreenCapture] Stopped. Frames: {_frameCount}, dropped: {_droppedFrames}");
    }

    /// <summary>
    /// Fallback: send JPEG frames with H264 prefix when ffmpeg is not available.
    /// </summary>
    private async Task JpegFallbackLoop(CancellationToken ct)
    {
        var frameInterval = TimeSpan.FromMilliseconds(1000.0 / Math.Min(_targetFps, 10));

        try
        {
            while (!ct.IsCancellationRequested && _isCapturing)
            {
                var sw = Stopwatch.StartNew();

                var jpegBytes = TakeScreenshot();
                if (jpegBytes != null)
                {
                    _onFrame(jpegBytes, true); // All JPEG frames are "keyframes"
                    _frameCount++;
                }

                var elapsed = sw.Elapsed;
                if (elapsed < frameInterval)
                    await Task.Delay(frameInterval - elapsed, ct);
            }
        }
        catch (OperationCanceledException) { }
    }

    private async Task ReadH264Output(System.IO.Stream stream, CancellationToken ct)
    {
        var buffer = new byte[256 * 1024]; // 256KB read buffer

        try
        {
            while (!ct.IsCancellationRequested)
            {
                var bytesRead = await stream.ReadAsync(buffer, 0, buffer.Length, ct);
                if (bytesRead == 0) break;

                var frameData = new byte[bytesRead];
                Buffer.BlockCopy(buffer, 0, frameData, 0, bytesRead);

                // Check if this contains a keyframe (SPS NAL = 0x67 after start code)
                bool isKeyframe = ContainsKeyframe(frameData);

                _onFrame(frameData, isKeyframe);
            }
        }
        catch (OperationCanceledException) { }
        catch { }
    }

    private static bool ContainsKeyframe(byte[] data)
    {
        // Look for Annex B start code followed by SPS NAL unit type (0x67 or type 5 IDR)
        for (int i = 0; i < data.Length - 4; i++)
        {
            if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1)
            {
                if (i + 4 < data.Length)
                {
                    var nalType = data[i + 4] & 0x1F;
                    if (nalType == 7 || nalType == 5) // SPS or IDR
                        return true;
                }
            }
        }
        return false;
    }

    // ── Adaptive Bitrate ──

    private void AdjustBitrate()
    {
        if (_droppedFrames >= 2 && _frameCount > 10)
        {
            _targetBitrate = Math.Max(_initialBitrate / 5, (int)(_targetBitrate * 0.75));
            _droppedFrames = 0;
            Console.WriteLine($"[ScreenCapture] Bitrate reduced to {_targetBitrate / 1000}kbps");
        }
        else if (_frameCount > 10 && _droppedFrames == 0)
        {
            _targetBitrate = Math.Min(_initialBitrate * 3, (int)(_targetBitrate * 1.25));
            Console.WriteLine($"[ScreenCapture] Bitrate increased to {_targetBitrate / 1000}kbps");
        }
    }

    // ── Screen Capture ──

    private static Bitmap? CaptureScreen()
    {
        var width = GetSystemMetrics(SM_CXSCREEN);
        var height = GetSystemMetrics(SM_CYSCREEN);

        var hDesktop = GetDesktopWindow();
        var hDC = IntPtr.Zero;
        var hMemDC = IntPtr.Zero;
        var hBitmap = IntPtr.Zero;

        try
        {
            hDC = GetWindowDC(hDesktop);
            hMemDC = CreateCompatibleDC(hDC);
            hBitmap = CreateCompatibleBitmap(hDC, width, height);
            var hOld = SelectObject(hMemDC, hBitmap);

            BitBlt(hMemDC, 0, 0, width, height, hDC, 0, 0, SRCCOPY);

            SelectObject(hMemDC, hOld);

            var bitmap = Image.FromHbitmap(hBitmap);
            return bitmap;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[ScreenCapture] Capture error: {ex.Message}");
            return null;
        }
        finally
        {
            if (hBitmap != IntPtr.Zero) DeleteObject(hBitmap);
            if (hMemDC != IntPtr.Zero) DeleteDC(hMemDC);
            if (hDC != IntPtr.Zero) ReleaseDC(hDesktop, hDC);
        }
    }

    private static ImageCodecInfo GetJpegEncoder()
    {
        foreach (var codec in ImageCodecInfo.GetImageEncoders())
        {
            if (codec.FormatID == ImageFormat.Jpeg.Guid)
                return codec;
        }
        throw new InvalidOperationException("JPEG encoder not found");
    }

    private void StopFfmpeg()
    {
        try
        {
            if (_ffmpeg is { HasExited: false })
            {
                _ffmpeg.StandardInput.Close();
                _ffmpeg.WaitForExit(3000);
                if (!_ffmpeg.HasExited)
                    _ffmpeg.Kill();
            }
            _ffmpeg?.Dispose();
            _ffmpeg = null;
        }
        catch { }
    }

    private static string? FindFfmpeg()
    {
        // Check PATH
        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "where.exe",
                    Arguments = "ffmpeg.exe",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                }
            };
            process.Start();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(3000);

            var firstLine = output.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim();
            if (firstLine != null && File.Exists(firstLine))
                return firstLine;
        }
        catch { }

        // Common locations
        string[] paths =
        {
            @"C:\ffmpeg\bin\ffmpeg.exe",
            @"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "scoop", "shims", "ffmpeg.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "ffmpeg", "bin", "ffmpeg.exe"),
        };

        foreach (var p in paths)
        {
            if (File.Exists(p)) return p;
        }

        return null;
    }
}
