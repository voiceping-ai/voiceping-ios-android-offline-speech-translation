using NAudio.Wave.SampleProviders;

using NAudio.Wave;

namespace OfflineSpeechTranslation.Utilities;

/// <summary>
/// Writes 16kHz mono 16-bit PCM WAV from Float32 samples.
/// Port of iOS WAVWriter.swift / Android WavWriter.kt.
/// </summary>
public static class WavWriter
{
    private const int SampleRate = 16000;
    private const short BitsPerSample = 16;
    private const short NumChannels = 1;

    /// <summary>
    /// Write a WAV file from Float32 audio samples.
    /// </summary>
    public static void Write(string path, float[] samples)
    {
        int dataSize = samples.Length * 2; // 16-bit = 2 bytes per sample
        int fileSize = 44 + dataSize;

        using var fs = new FileStream(path, FileMode.Create, FileAccess.Write);
        using var bw = new BinaryWriter(fs);

        // RIFF header
        bw.Write("RIFF"u8);
        bw.Write(fileSize - 8);
        bw.Write("WAVE"u8);

        // fmt chunk
        bw.Write("fmt "u8);
        bw.Write(16); // chunk size
        bw.Write((short)1); // PCM format
        bw.Write(NumChannels);
        bw.Write(SampleRate);
        bw.Write(SampleRate * NumChannels * BitsPerSample / 8); // byte rate
        bw.Write((short)(NumChannels * BitsPerSample / 8)); // block align
        bw.Write(BitsPerSample);

        // data chunk
        bw.Write("data"u8);
        bw.Write(dataSize);

        // Convert Float32 → Int16 and write in chunks
        const int chunkSize = 4096;
        for (int i = 0; i < samples.Length; i += chunkSize)
        {
            int count = Math.Min(chunkSize, samples.Length - i);
            for (int j = 0; j < count; j++)
            {
                float clamped = Math.Clamp(samples[i + j], -1.0f, 1.0f);
                short sample = (short)(clamped * 32767);
                bw.Write(sample);
            }
        }
    }

    /// <summary>
    /// Read a WAV file into Float32 samples (16kHz mono assumed).
    /// Returns null if format is incompatible.
    /// </summary>
    public static float[]? Read(string path)
    {
        try
        {
            using var reader = new NAudio.Wave.WaveFileReader(path);
            var provider = reader.ToSampleProvider();

            var samples = new List<float>();
            var buffer = new float[4096];
            int read;
            while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
            {
                for (int i = 0; i < read; i++)
                    samples.Add(buffer[i]);
            }
            return samples.ToArray();
        }
        catch
        {
            return null;
        }
    }
}
