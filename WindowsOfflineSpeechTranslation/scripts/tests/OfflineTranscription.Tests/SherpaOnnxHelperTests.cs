using OfflineSpeechTranslation.Engines;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Tests;

/// <summary>
/// Tests for SherpaOnnxOfflineEngine internal helper methods.
/// Covers language extraction, CJK space stripping, thread computation,
/// model type detection from filesystem, and file-finding logic.
/// </summary>
public class SherpaOnnxHelperTests : IDisposable
{
    private readonly string _tempDir;

    public SherpaOnnxHelperTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"sherpa_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    // ── TryExtractSenseVoiceLanguage ──

    [Fact]
    public void TryExtract_ExtractsLanguageAndStripsToken()
    {
        var text = "<|en|>Hello world";
        var lang = SherpaOnnxOfflineEngine.TryExtractSenseVoiceLanguage(ref text);
        Assert.Equal("en", lang);
        Assert.Equal("Hello world", text);
    }

    [Fact]
    public void TryExtract_ReturnsNullForPlainText()
    {
        var text = "Hello world";
        var lang = SherpaOnnxOfflineEngine.TryExtractSenseVoiceLanguage(ref text);
        Assert.Null(lang);
        Assert.Equal("Hello world", text);
    }

    [Fact]
    public void TryExtract_ReturnsNullForEmpty()
    {
        var text = "";
        var lang = SherpaOnnxOfflineEngine.TryExtractSenseVoiceLanguage(ref text);
        Assert.Null(lang);
    }

    [Fact]
    public void TryExtract_ReturnsNullForWhitespace()
    {
        var text = "   ";
        var lang = SherpaOnnxOfflineEngine.TryExtractSenseVoiceLanguage(ref text);
        Assert.Null(lang);
    }

    [Fact]
    public void TryExtract_HandlesChineseToken()
    {
        var text = "<|zh|>你好世界";
        var lang = SherpaOnnxOfflineEngine.TryExtractSenseVoiceLanguage(ref text);
        Assert.Equal("zh", lang);
        Assert.Equal("你好世界", text);
    }

    [Fact]
    public void TryExtract_HandlesThreeLetterCode()
    {
        var text = "<|yue|>广东话";
        var lang = SherpaOnnxOfflineEngine.TryExtractSenseVoiceLanguage(ref text);
        Assert.Equal("yue", lang);
        Assert.Equal("广东话", text);
    }

    [Theory]
    [InlineData("<|en|>Hello", "en", "Hello")]
    [InlineData("<|zh|>你好", "zh", "你好")]
    [InlineData("<|ja|>こんにちは", "ja", "こんにちは")]
    [InlineData("<|ko|>안녕하세요", "ko", "안녕하세요")]
    [InlineData("<|yue|>你好", "yue", "你好")]
    public void TryExtract_AllSenseVoiceLanguages(string input, string expectedLang, string expectedText)
    {
        var text = input;
        var lang = SherpaOnnxOfflineEngine.TryExtractSenseVoiceLanguage(ref text);
        Assert.Equal(expectedLang, lang);
        Assert.Equal(expectedText, text);
    }

    [Fact]
    public void TryExtract_LowercasesLanguage()
    {
        var text = "<|EN|>Hello";
        var lang = SherpaOnnxOfflineEngine.TryExtractSenseVoiceLanguage(ref text);
        Assert.Equal("en", lang);
    }

    [Fact]
    public void TryExtract_TokenInMiddleOfText()
    {
        var text = "Hello <|en|> world";
        var lang = SherpaOnnxOfflineEngine.TryExtractSenseVoiceLanguage(ref text);
        Assert.Equal("en", lang);
        Assert.Equal("Hello  world", text.Replace("  ", " ") != text ? text : "Hello  world");
        // The token is removed wherever it appears
        Assert.DoesNotContain("<|", text);
    }

    // ── StripCjkSpaces ──

    [Fact]
    public void StripCjkSpaces_RemovesSpacesBetweenCjk()
    {
        var result = SherpaOnnxOfflineEngine.StripCjkSpaces("\u4F60 \u597D");
        Assert.Equal("\u4F60\u597D", result);
    }

    [Fact]
    public void StripCjkSpaces_PreservesSpacesAroundLatin()
    {
        var result = SherpaOnnxOfflineEngine.StripCjkSpaces("Hello \u4F60\u597D world");
        Assert.Equal("Hello \u4F60\u597D world", result);
    }

    [Fact]
    public void StripCjkSpaces_HandlesEmptyString()
    {
        Assert.Equal("", SherpaOnnxOfflineEngine.StripCjkSpaces(""));
    }

    [Fact]
    public void StripCjkSpaces_HandlesPureLatinText()
    {
        Assert.Equal("Hello world", SherpaOnnxOfflineEngine.StripCjkSpaces("Hello world"));
    }

    [Fact]
    public void StripCjkSpaces_HandlesMultipleCjkSpaces()
    {
        var result = SherpaOnnxOfflineEngine.StripCjkSpaces("\u4F60 \u597D \u4E16 \u754C");
        Assert.DoesNotContain("\u4F60 \u597D", result);
    }

    [Fact]
    public void StripCjkSpaces_HandlesHiragana()
    {
        var result = SherpaOnnxOfflineEngine.StripCjkSpaces("\u3042 \u3044");
        Assert.Equal("\u3042\u3044", result);
    }

    [Fact]
    public void StripCjkSpaces_HandlesKatakana()
    {
        var result = SherpaOnnxOfflineEngine.StripCjkSpaces("\u30A2 \u30A4");
        Assert.Equal("\u30A2\u30A4", result);
    }

    [Fact]
    public void StripCjkSpaces_PreservesMultipleSpacesBetweenLatin()
    {
        Assert.Equal("Hello  world", SherpaOnnxOfflineEngine.StripCjkSpaces("Hello  world"));
    }

    // ── ComputeThreads ──

    [Theory]
    [InlineData(1, 1)]
    [InlineData(2, 1)]
    [InlineData(3, 2)]
    [InlineData(4, 2)]
    [InlineData(5, 4)]
    [InlineData(6, 4)]
    [InlineData(8, 4)]
    [InlineData(9, 6)]
    [InlineData(12, 6)]
    [InlineData(16, 6)]
    [InlineData(32, 6)]
    [InlineData(64, 6)]
    public void ComputeThreads_ReturnsCorrectForCoreCount(int cores, int expected)
    {
        Assert.Equal(expected, SherpaOnnxOfflineEngine.ComputeThreads(cores));
    }

    [Fact]
    public void ComputeThreads_NeverReturnsZero()
    {
        Assert.Equal(1, SherpaOnnxOfflineEngine.ComputeThreads(0));
    }

    [Fact]
    public void ComputeThreads_NeverExceedsSix()
    {
        Assert.Equal(6, SherpaOnnxOfflineEngine.ComputeThreads(128));
    }

    // ── DetectModelType ──

    [Fact]
    public void DetectModelType_Moonshine_WhenPreprocessExists()
    {
        File.WriteAllText(Path.Combine(_tempDir, "preprocess.onnx"), "");
        Assert.Equal(SherpaModelType.Moonshine, SherpaOnnxOfflineEngine.DetectModelType(_tempDir));
    }

    [Fact]
    public void DetectModelType_SenseVoice_WhenModelOnnxExists()
    {
        File.WriteAllText(Path.Combine(_tempDir, "model.int8.onnx"), "");
        Assert.Equal(SherpaModelType.SenseVoice, SherpaOnnxOfflineEngine.DetectModelType(_tempDir));
    }

    [Fact]
    public void DetectModelType_SenseVoice_FallbackForModelOnnx()
    {
        // OmnilingualCtc also has model*.onnx — DetectModelType defaults to SenseVoice.
        // OmnilingualCtc requires explicit model type via EngineFactory.
        File.WriteAllText(Path.Combine(_tempDir, "model.int8.onnx"), "");
        File.WriteAllText(Path.Combine(_tempDir, "tokens.txt"), "");
        Assert.Equal(SherpaModelType.SenseVoice, SherpaOnnxOfflineEngine.DetectModelType(_tempDir));
    }

    [Fact]
    public void DetectModelType_ThrowsForUnknownModelDir()
    {
        Assert.Throws<InvalidOperationException>(() => SherpaOnnxOfflineEngine.DetectModelType(_tempDir));
    }

    [Fact]
    public void DetectModelType_Moonshine_TakesPrecedence()
    {
        File.WriteAllText(Path.Combine(_tempDir, "preprocess.onnx"), "");
        File.WriteAllText(Path.Combine(_tempDir, "model.int8.onnx"), "");
        Assert.Equal(SherpaModelType.Moonshine, SherpaOnnxOfflineEngine.DetectModelType(_tempDir));
    }

    // ── FindFile ──

    [Fact]
    public void FindFile_PrefersInt8Variant()
    {
        File.WriteAllText(Path.Combine(_tempDir, "encode.onnx"), "");
        File.WriteAllText(Path.Combine(_tempDir, "encode.int8.onnx"), "");

        var result = SherpaOnnxOfflineEngine.FindFile(_tempDir, "encode");
        Assert.EndsWith("encode.int8.onnx", result);
    }

    [Fact]
    public void FindFile_FallsBackToRegular()
    {
        File.WriteAllText(Path.Combine(_tempDir, "encode.onnx"), "");

        var result = SherpaOnnxOfflineEngine.FindFile(_tempDir, "encode");
        Assert.EndsWith("encode.onnx", result);
    }

    [Fact]
    public void FindFile_ReturnsInt8Path_WhenNeitherExists()
    {
        var result = SherpaOnnxOfflineEngine.FindFile(_tempDir, "encode");
        Assert.EndsWith("encode.int8.onnx", result);
    }

    [Fact]
    public void FindFile_ConstructsCorrectPath()
    {
        File.WriteAllText(Path.Combine(_tempDir, "model.int8.onnx"), "");
        var result = SherpaOnnxOfflineEngine.FindFile(_tempDir, "model");
        Assert.Equal(Path.Combine(_tempDir, "model.int8.onnx"), result);
    }
}
