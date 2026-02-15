using OfflineSpeechTranslation.Utilities;

namespace OfflineSpeechTranslation.Tests;

/// <summary>
/// Tests for WavWriter: WAV header correctness, round-trip fidelity,
/// clipping behavior, and edge cases (empty audio, single sample).
/// </summary>
public class WavWriterTests : IDisposable
{
    private readonly string _tempDir;

    public WavWriterTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"wav_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    [Fact]
    public void Write_CreatesValidWavHeader()
    {
        var path = Path.Combine(_tempDir, "test.wav");
        var samples = new float[16000]; // 1 second of silence

        WavWriter.Write(path, samples);

        var bytes = File.ReadAllBytes(path);
        // RIFF header
        Assert.Equal((byte)'R', bytes[0]);
        Assert.Equal((byte)'I', bytes[1]);
        Assert.Equal((byte)'F', bytes[2]);
        Assert.Equal((byte)'F', bytes[3]);

        // WAVE format
        Assert.Equal((byte)'W', bytes[8]);
        Assert.Equal((byte)'A', bytes[9]);
        Assert.Equal((byte)'V', bytes[10]);
        Assert.Equal((byte)'E', bytes[11]);

        // fmt chunk
        Assert.Equal((byte)'f', bytes[12]);
        Assert.Equal((byte)'m', bytes[13]);
        Assert.Equal((byte)'t', bytes[14]);
        Assert.Equal((byte)' ', bytes[15]);

        // PCM format = 1
        var format = BitConverter.ToInt16(bytes, 20);
        Assert.Equal(1, format);

        // 1 channel
        var channels = BitConverter.ToInt16(bytes, 22);
        Assert.Equal(1, channels);

        // 16000 Hz
        var sampleRate = BitConverter.ToInt32(bytes, 24);
        Assert.Equal(16000, sampleRate);

        // 16 bits per sample
        var bitsPerSample = BitConverter.ToInt16(bytes, 34);
        Assert.Equal(16, bitsPerSample);

        // data chunk
        Assert.Equal((byte)'d', bytes[36]);
        Assert.Equal((byte)'a', bytes[37]);
        Assert.Equal((byte)'t', bytes[38]);
        Assert.Equal((byte)'a', bytes[39]);

        // data size = samples * 2 bytes
        var dataSize = BitConverter.ToInt32(bytes, 40);
        Assert.Equal(16000 * 2, dataSize);
    }

    [Fact]
    public void Write_CorrectFileSize()
    {
        var path = Path.Combine(_tempDir, "test.wav");
        int sampleCount = 32000; // 2 seconds
        WavWriter.Write(path, new float[sampleCount]);

        var info = new FileInfo(path);
        // 44 byte header + sampleCount * 2 bytes per sample
        Assert.Equal(44 + sampleCount * 2, info.Length);
    }

    [Fact]
    public void Write_EmptyAudio_CreatesHeaderOnly()
    {
        var path = Path.Combine(_tempDir, "empty.wav");
        WavWriter.Write(path, Array.Empty<float>());

        var info = new FileInfo(path);
        Assert.Equal(44, info.Length); // Header only, no data
    }

    [Fact]
    public void Write_ClampsValues()
    {
        var path = Path.Combine(_tempDir, "clamp.wav");
        var samples = new float[] { -2.0f, -1.0f, 0.0f, 1.0f, 2.0f };
        WavWriter.Write(path, samples);

        var bytes = File.ReadAllBytes(path);
        // Read Int16 values from data section
        var s0 = BitConverter.ToInt16(bytes, 44); // -2.0 clamped to -1.0 = -32767
        var s1 = BitConverter.ToInt16(bytes, 46); // -1.0 = -32767
        var s2 = BitConverter.ToInt16(bytes, 48); // 0.0 = 0
        var s3 = BitConverter.ToInt16(bytes, 50); // 1.0 = 32767
        var s4 = BitConverter.ToInt16(bytes, 52); // 2.0 clamped to 1.0 = 32767

        Assert.Equal(s0, s1); // Both clamped to -1.0
        Assert.Equal(0, s2);
        Assert.Equal(s3, s4); // Both clamped to 1.0
        Assert.Equal(-32767, s0);
        Assert.Equal(32767, s3);
    }

    [Fact]
    public void Write_SingleSample()
    {
        var path = Path.Combine(_tempDir, "single.wav");
        WavWriter.Write(path, new float[] { 0.5f });

        var bytes = File.ReadAllBytes(path);
        Assert.Equal(44 + 2, bytes.Length);

        var sample = BitConverter.ToInt16(bytes, 44);
        // 0.5 * 32767 ≈ 16383
        Assert.Equal(16383, sample);
    }

    [Fact]
    public void Write_RoundTrip_PreservesSilence()
    {
        var path = Path.Combine(_tempDir, "silence.wav");
        var original = new float[16000]; // All zeros
        WavWriter.Write(path, original);

        var read = WavWriter.Read(path);
        Assert.NotNull(read);
        Assert.Equal(original.Length, read!.Length);
        Assert.All(read, sample => Assert.Equal(0f, sample, 4));
    }

    [Fact]
    public void Write_RoundTrip_PreservesSignal()
    {
        var path = Path.Combine(_tempDir, "signal.wav");
        // Generate 440Hz sine wave
        var samples = new float[16000];
        for (int i = 0; i < samples.Length; i++)
            samples[i] = (float)Math.Sin(2.0 * Math.PI * 440.0 * i / 16000.0) * 0.8f;

        WavWriter.Write(path, samples);
        var read = WavWriter.Read(path);

        Assert.NotNull(read);
        Assert.Equal(samples.Length, read!.Length);

        // Int16 quantization introduces error up to 1/32767 ≈ 3e-5
        for (int i = 0; i < samples.Length; i++)
        {
            Assert.InRange(Math.Abs(read[i] - samples[i]), 0, 0.001f);
        }
    }

    [Fact]
    public void Read_NonExistentFile_ReturnsNull()
    {
        var result = WavWriter.Read(Path.Combine(_tempDir, "nonexistent.wav"));
        Assert.Null(result);
    }

    [Fact]
    public void Read_InvalidFile_ReturnsNull()
    {
        var path = Path.Combine(_tempDir, "invalid.wav");
        File.WriteAllText(path, "not a wav file");
        var result = WavWriter.Read(path);
        Assert.Null(result);
    }

    [Fact]
    public void Write_LargeFile_Succeeds()
    {
        var path = Path.Combine(_tempDir, "large.wav");
        // 30 seconds at 16kHz = 480,000 samples
        var samples = new float[480_000];
        WavWriter.Write(path, samples);

        var info = new FileInfo(path);
        Assert.Equal(44 + 480_000 * 2, info.Length);
    }
}
