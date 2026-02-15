using System.Runtime.InteropServices;

namespace OfflineSpeechTranslation.Interop;

/// <summary>
/// P/Invoke declarations for whisper.cpp shared library.
/// Mirrors the Android JNI bridge (whisper_jni.cpp).
/// whisper.dll must be built from whisper.cpp v1.8.3 with BUILD_SHARED_LIBS=ON.
/// </summary>
internal static class WhisperNative
{
    private const string LibName = "whisper";

    // ── Context lifecycle ──

    [DllImport(LibName, EntryPoint = "whisper_init_from_file_with_params", CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr InitFromFile(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string pathModel,
        WhisperContextParams cparams);

    [DllImport(LibName, EntryPoint = "whisper_free", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void Free(IntPtr ctx);

    // ── Default params ──

    [DllImport(LibName, EntryPoint = "whisper_context_default_params", CallingConvention = CallingConvention.Cdecl)]
    internal static extern WhisperContextParams ContextDefaultParams();

    [DllImport(LibName, EntryPoint = "whisper_full_default_params", CallingConvention = CallingConvention.Cdecl)]
    internal static extern WhisperFullParams FullDefaultParams(int strategy);

    // ── Full transcription ──

    [DllImport(LibName, EntryPoint = "whisper_full", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int Full(
        IntPtr ctx,
        WhisperFullParams wparams,
        [In] float[] samples,
        int nSamples);

    // ── Segment access ──

    [DllImport(LibName, EntryPoint = "whisper_full_n_segments", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int FullNSegments(IntPtr ctx);

    [DllImport(LibName, EntryPoint = "whisper_full_get_segment_text", CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr FullGetSegmentText(IntPtr ctx, int iSegment);

    [DllImport(LibName, EntryPoint = "whisper_full_get_segment_t0", CallingConvention = CallingConvention.Cdecl)]
    internal static extern long FullGetSegmentT0(IntPtr ctx, int iSegment);

    [DllImport(LibName, EntryPoint = "whisper_full_get_segment_t1", CallingConvention = CallingConvention.Cdecl)]
    internal static extern long FullGetSegmentT1(IntPtr ctx, int iSegment);

    // ── Language detection ──

    [DllImport(LibName, EntryPoint = "whisper_full_lang_id", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int FullLangId(IntPtr ctx);

    [DllImport(LibName, EntryPoint = "whisper_lang_str", CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr LangStr(int id);

    // ── Sampling strategies ──
    internal const int WHISPER_SAMPLING_GREEDY = 0;
    internal const int WHISPER_SAMPLING_BEAM_SEARCH = 1;
}

/// <summary>
/// whisper_context_params — matches the C struct layout.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal struct WhisperContextParams
{
    [MarshalAs(UnmanagedType.I1)]
    public bool use_gpu;
    [MarshalAs(UnmanagedType.I1)]
    public bool flash_attn;
    public int gpu_device;
    [MarshalAs(UnmanagedType.I1)]
    public bool dtw_token_timestamps;
    public int dtw_aheads_preset;
    public int dtw_n_top;
    public int dtw_aheads_n;
    public IntPtr dtw_aheads; // struct pointer, unused
    public IntPtr dtw_mem_size;
}

/// <summary>
/// whisper_full_params — matches the C struct layout for whisper.cpp v1.8.3.
/// IMPORTANT: Field order, types, and sizes must exactly match whisper.h.
/// Always initialize via whisper_full_default_params() and override specific fields.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal struct WhisperFullParams
{
    public int strategy;

    public int n_threads;
    public int n_max_text_ctx;
    public int offset_ms;
    public int duration_ms;

    [MarshalAs(UnmanagedType.I1)]
    public bool translate;
    [MarshalAs(UnmanagedType.I1)]
    public bool no_context;
    [MarshalAs(UnmanagedType.I1)]
    public bool no_timestamps;
    [MarshalAs(UnmanagedType.I1)]
    public bool single_segment;
    [MarshalAs(UnmanagedType.I1)]
    public bool print_special;
    [MarshalAs(UnmanagedType.I1)]
    public bool print_progress;
    [MarshalAs(UnmanagedType.I1)]
    public bool print_realtime;
    [MarshalAs(UnmanagedType.I1)]
    public bool print_timestamps;

    [MarshalAs(UnmanagedType.I1)]
    public bool token_timestamps;
    public float thold_pt;
    public float thold_ptsum;
    public int max_len;
    [MarshalAs(UnmanagedType.I1)]
    public bool split_on_word;
    public int max_tokens;

    // speed_up was removed in whisper.cpp v1.8.x
    [MarshalAs(UnmanagedType.I1)]
    public bool debug_mode;
    public int audio_ctx;

    [MarshalAs(UnmanagedType.I1)]
    public bool tdrz_enable;

    // suppress_regex is const char* (pointer), NOT bool
    public IntPtr suppress_regex;

    public IntPtr initial_prompt;

    [MarshalAs(UnmanagedType.I1)]
    public bool carry_initial_prompt;

    public IntPtr prompt_tokens;
    public int prompt_n_tokens;

    public IntPtr language;
    [MarshalAs(UnmanagedType.I1)]
    public bool detect_language;

    [MarshalAs(UnmanagedType.I1)]
    public bool suppress_blank;
    [MarshalAs(UnmanagedType.I1)]
    public bool suppress_nst; // renamed from suppress_non_speech_tokens
    public float temperature;
    public float max_initial_ts;
    public float length_penalty;

    // temperature_inc is float, not int
    public float temperature_inc;
    public float entropy_thold;
    public float logprob_thold;
    public float no_speech_thold;

    // greedy params
    public int greedy_best_of;

    // beam_search params
    public int beam_search_beam_size;
    public float beam_search_patience;

    // callbacks (function pointers — set to IntPtr.Zero)
    public IntPtr new_segment_callback;
    public IntPtr new_segment_callback_user_data;
    public IntPtr progress_callback;
    public IntPtr progress_callback_user_data;
    public IntPtr encoder_begin_callback;
    public IntPtr encoder_begin_callback_user_data;
    public IntPtr abort_callback;
    public IntPtr abort_callback_user_data;
    public IntPtr logits_filter_callback;
    public IntPtr logits_filter_callback_user_data;

    public IntPtr grammar_rules;
    public IntPtr n_grammar_rules;  // size_t
    public IntPtr i_start_rule;     // size_t
    public float grammar_penalty;

    // VAD fields (added in v1.8.x)
    [MarshalAs(UnmanagedType.I1)]
    public bool vad;
    public IntPtr vad_model_path;
    // whisper_vad_params inlined — matches struct whisper_vad_params exactly
    public float vad_threshold;
    public int vad_min_speech_duration_ms;
    public int vad_min_silence_duration_ms;
    public float vad_max_speech_duration_s;
    public int vad_speech_pad_ms;
    public float vad_samples_overlap;
}
