using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Windows.Forms;

namespace TarsyWindows.UI;

/// <summary>
/// A logo control that fades in and scales up on first display.
/// Uses ColorMatrix for opacity and scales the draw rectangle for size animation.
/// </summary>
internal class AnimatedLogo : Panel
{
    private readonly Image? _image;
    private readonly System.Windows.Forms.Timer _timer;
    private float _progress; // 0.0 → 1.0
    private const int DurationMs = 600;
    private const int FrameMs = 16;
    private DateTime _startTime;

    public AnimatedLogo(Image? image, int size)
    {
        _image = image;
        Size = new Size(size, size);
        BackColor = Color.Transparent;
        DoubleBuffered = true;

        _timer = new System.Windows.Forms.Timer { Interval = FrameMs };
        _timer.Tick += OnTick;
    }

    /// <summary>
    /// Start the entrance animation. Call after the control is shown.
    /// </summary>
    public void Play()
    {
        _progress = 0f;
        _startTime = DateTime.UtcNow;
        _timer.Start();
        Invalidate();
    }

    private void OnTick(object? sender, EventArgs e)
    {
        var elapsed = (DateTime.UtcNow - _startTime).TotalMilliseconds;
        _progress = Math.Min(1f, (float)(elapsed / DurationMs));

        if (_progress >= 1f)
        {
            _progress = 1f;
            _timer.Stop();
        }

        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (_image == null) return;

        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;

        // Eased progress (ease-out cubic)
        float t = _progress;
        float eased = 1f - (float)Math.Pow(1f - t, 3);

        // Scale: start at 0.6, end at 1.0
        float scale = 0.6f + 0.4f * eased;
        // Opacity: start at 0, end at 1
        float alpha = eased;

        // Compute draw rect (centered)
        int targetSize = (int)(Width * scale);
        int x = (Width - targetSize) / 2;
        int y = (Height - targetSize) / 2;
        var rect = new Rectangle(x, y, targetSize, targetSize);

        // Draw with alpha via ColorMatrix
        var cm = new ColorMatrix { Matrix33 = alpha };
        using var attrs = new ImageAttributes();
        attrs.SetColorMatrix(cm);
        g.DrawImage(_image, rect, 0, 0, _image.Width, _image.Height, GraphicsUnit.Pixel, attrs);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _timer.Dispose();
        base.Dispose(disposing);
    }
}
