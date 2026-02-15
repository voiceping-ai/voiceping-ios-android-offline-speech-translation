using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Tests;

public class ASRResultTests
{
    [Fact]
    public void Empty_ReturnsEmptyResult()
    {
        var empty = ASRResult.Empty;

        Assert.Equal("", empty.Text);
        Assert.Empty(empty.Segments);
        Assert.Null(empty.DetectedLanguage);
        Assert.Equal(0, empty.InferenceTimeMs);
    }

    [Fact]
    public void ASRSegment_RecordEquality()
    {
        var s1 = new ASRSegment("hello", 0, 1000, "en");
        var s2 = new ASRSegment("hello", 0, 1000, "en");
        Assert.Equal(s1, s2);
    }

    [Fact]
    public void ASRResult_WithInferenceTime()
    {
        var result = new ASRResult("test", [new("test", 0, 1000)], "en", 150.5);
        var updated = result with { InferenceTimeMs = 200.0 };

        Assert.Equal(150.5, result.InferenceTimeMs);
        Assert.Equal(200.0, updated.InferenceTimeMs);
        Assert.Equal("test", updated.Text);
    }
}
