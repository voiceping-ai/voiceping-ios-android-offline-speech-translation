using OfflineSpeechTranslation.Services;

namespace OfflineSpeechTranslation.Tests;

/// <summary>
/// Tests for SystemMetrics: initialization, CPU/memory measurement.
/// </summary>
public class SystemMetricsTests
{
    [Fact]
    public void Constructor_InitializesWithZeroCpu()
    {
        var metrics = new SystemMetrics();
        Assert.Equal(0.0, metrics.CpuPercent);
    }

    [Fact]
    public void Constructor_InitializesWithZeroMemory()
    {
        var metrics = new SystemMetrics();
        Assert.Equal(0, metrics.MemoryBytes);
    }

    [Fact]
    public void Update_PopulatesMemory()
    {
        var metrics = new SystemMetrics();
        metrics.Update();

        // After update, memory should be non-zero (process is running)
        Assert.True(metrics.MemoryBytes > 0, "Memory bytes should be positive after update");
    }

    [Fact]
    public void Update_MemoryMB_IsPositive()
    {
        var metrics = new SystemMetrics();
        metrics.Update();

        Assert.True(metrics.MemoryMB > 0, "Memory in MB should be positive");
    }

    [Fact]
    public void Update_CpuPercent_IsNonNegative()
    {
        var metrics = new SystemMetrics();
        // Do some work to generate CPU time
        var sum = 0.0;
        for (int i = 0; i < 1_000_000; i++) sum += Math.Sqrt(i);
        _ = sum;

        metrics.Update();
        Assert.True(metrics.CpuPercent >= 0.0, "CPU percent should be non-negative");
    }

    [Fact]
    public void MemoryMB_IsCorrectConversion()
    {
        var metrics = new SystemMetrics();
        metrics.Update();

        var expectedMB = metrics.MemoryBytes / (1024.0 * 1024.0);
        Assert.Equal(expectedMB, metrics.MemoryMB, 6);
    }

    [Fact]
    public void MultipleUpdates_DoNotThrow()
    {
        var metrics = new SystemMetrics();
        for (int i = 0; i < 10; i++)
        {
            var ex = Record.Exception(() => metrics.Update());
            Assert.Null(ex);
        }
    }
}
