using System.Diagnostics;

namespace OfflineSpeechTranslation.Services;

/// <summary>
/// Tracks CPU and memory usage. Port of iOS SystemMetrics.swift.
/// </summary>
public sealed class SystemMetrics
{
    private TimeSpan _lastCpuTime;
    private DateTime _lastWallTime;

    public double CpuPercent { get; private set; }
    public long MemoryBytes { get; private set; }
    public double MemoryMB => MemoryBytes / (1024.0 * 1024.0);

    public SystemMetrics()
    {
        using var proc = Process.GetCurrentProcess();
        _lastCpuTime = proc.TotalProcessorTime;
        _lastWallTime = DateTime.UtcNow;
    }

    public void Update()
    {
        using var proc = Process.GetCurrentProcess();
        var now = DateTime.UtcNow;
        var cpuTime = proc.TotalProcessorTime;

        var wallDelta = (now - _lastWallTime).TotalMilliseconds;
        var cpuDelta = (cpuTime - _lastCpuTime).TotalMilliseconds;

        if (wallDelta > 0)
        {
            CpuPercent = (cpuDelta / wallDelta) * 100.0 / Environment.ProcessorCount;
        }

        _lastCpuTime = cpuTime;
        _lastWallTime = now;
        MemoryBytes = proc.WorkingSet64;
    }
}
