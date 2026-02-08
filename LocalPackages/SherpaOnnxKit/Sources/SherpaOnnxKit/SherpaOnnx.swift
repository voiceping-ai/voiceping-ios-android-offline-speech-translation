/// swift-api-examples/SherpaOnnx.swift
/// Copyright (c)  2023  Xiaomi Corporation

import Foundation  // For NSString
@_exported import sherpa_onnx

/// Convert a String from swift to a `const char*` so that we can pass it to
/// the C language.
///
/// - Parameters:
///   - s: The String to convert.
/// - Returns: A pointer that can be passed to C as `const char*`

public func toCPointer(_ s: String) -> UnsafePointer<Int8>! {
  let cs = (s as NSString).utf8String
  return UnsafePointer<Int8>(cs)
}

/// Return an instance of SherpaOnnxOnlineTransducerModelConfig.
///
/// Please refer to
/// https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/index.html
/// to download the required `.onnx` files.
///
/// - Parameters:
///   - encoder: Path to encoder.onnx
///   - decoder: Path to decoder.onnx
///   - joiner: Path to joiner.onnx
///
/// - Returns: Return an instance of SherpaOnnxOnlineTransducerModelConfig
public func sherpaOnnxOnlineTransducerModelConfig(
  encoder: String = "",
  decoder: String = "",
  joiner: String = ""
) -> SherpaOnnxOnlineTransducerModelConfig {
  return SherpaOnnxOnlineTransducerModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    joiner: toCPointer(joiner)
  )
}

/// Return an instance of SherpaOnnxOnlineParaformerModelConfig.
///
/// Please refer to
/// https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-paraformer/index.html
/// to download the required `.onnx` files.
///
/// - Parameters:
///   - encoder: Path to encoder.onnx
///   - decoder: Path to decoder.onnx
///
/// - Returns: Return an instance of SherpaOnnxOnlineParaformerModelConfig
public func sherpaOnnxOnlineParaformerModelConfig(
  encoder: String = "",
  decoder: String = ""
) -> SherpaOnnxOnlineParaformerModelConfig {
  return SherpaOnnxOnlineParaformerModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder)
  )
}

public func sherpaOnnxOnlineZipformer2CtcModelConfig(
  model: String = ""
) -> SherpaOnnxOnlineZipformer2CtcModelConfig {
  return SherpaOnnxOnlineZipformer2CtcModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOnlineNemoCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOnlineNemoCtcModelConfig {
  return SherpaOnnxOnlineNemoCtcModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOnlineToneCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOnlineToneCtcModelConfig {
  return SherpaOnnxOnlineToneCtcModelConfig(
    model: toCPointer(model)
  )
}

/// Return an instance of SherpaOnnxOnlineModelConfig.
///
/// Please refer to
/// https://k2-fsa.github.io/sherpa/onnx/pretrained_models/index.html
/// to download the required `.onnx` files.
///
/// - Parameters:
///   - tokens: Path to tokens.txt
///   - numThreads:  Number of threads to use for neural network computation.
///
/// - Returns: Return an instance of SherpaOnnxOnlineTransducerModelConfig
public func sherpaOnnxOnlineModelConfig(
  tokens: String,
  transducer: SherpaOnnxOnlineTransducerModelConfig = sherpaOnnxOnlineTransducerModelConfig(),
  paraformer: SherpaOnnxOnlineParaformerModelConfig = sherpaOnnxOnlineParaformerModelConfig(),
  zipformer2Ctc: SherpaOnnxOnlineZipformer2CtcModelConfig =
    sherpaOnnxOnlineZipformer2CtcModelConfig(),
  numThreads: Int = 1,
  provider: String = "cpu",
  debug: Int = 0,
  modelType: String = "",
  modelingUnit: String = "cjkchar",
  bpeVocab: String = "",
  tokensBuf: String = "",
  tokensBufSize: Int = 0,
  nemoCtc: SherpaOnnxOnlineNemoCtcModelConfig = sherpaOnnxOnlineNemoCtcModelConfig(),
  toneCtc: SherpaOnnxOnlineToneCtcModelConfig = sherpaOnnxOnlineToneCtcModelConfig()
) -> SherpaOnnxOnlineModelConfig {
  return SherpaOnnxOnlineModelConfig(
    transducer: transducer,
    paraformer: paraformer,
    zipformer2_ctc: zipformer2Ctc,
    tokens: toCPointer(tokens),
    num_threads: Int32(numThreads),
    provider: toCPointer(provider),
    debug: Int32(debug),
    model_type: toCPointer(modelType),
    modeling_unit: toCPointer(modelingUnit),
    bpe_vocab: toCPointer(bpeVocab),
    tokens_buf: toCPointer(tokensBuf),
    tokens_buf_size: Int32(tokensBufSize),
    nemo_ctc: nemoCtc,
    t_one_ctc: toneCtc
  )
}

public func sherpaOnnxFeatureConfig(
  sampleRate: Int = 16000,
  featureDim: Int = 80
) -> SherpaOnnxFeatureConfig {
  return SherpaOnnxFeatureConfig(
    sample_rate: Int32(sampleRate),
    feature_dim: Int32(featureDim))
}

public func sherpaOnnxOnlineCtcFstDecoderConfig(
  graph: String = "",
  maxActive: Int = 3000
) -> SherpaOnnxOnlineCtcFstDecoderConfig {
  return SherpaOnnxOnlineCtcFstDecoderConfig(
    graph: toCPointer(graph),
    max_active: Int32(maxActive))
}

public func sherpaOnnxHomophoneReplacerConfig(
  dictDir: String = "",
  lexicon: String = "",
  ruleFsts: String = ""
) -> SherpaOnnxHomophoneReplacerConfig {
  return SherpaOnnxHomophoneReplacerConfig(
    dict_dir: toCPointer(dictDir),
    lexicon: toCPointer(lexicon),
    rule_fsts: toCPointer(ruleFsts))
}

public func sherpaOnnxOnlineRecognizerConfig(
  featConfig: SherpaOnnxFeatureConfig,
  modelConfig: SherpaOnnxOnlineModelConfig,
  enableEndpoint: Bool = false,
  rule1MinTrailingSilence: Float = 2.4,
  rule2MinTrailingSilence: Float = 1.2,
  rule3MinUtteranceLength: Float = 30,
  decodingMethod: String = "greedy_search",
  maxActivePaths: Int = 4,
  hotwordsFile: String = "",
  hotwordsScore: Float = 1.5,
  ctcFstDecoderConfig: SherpaOnnxOnlineCtcFstDecoderConfig = sherpaOnnxOnlineCtcFstDecoderConfig(),
  ruleFsts: String = "",
  ruleFars: String = "",
  blankPenalty: Float = 0.0,
  hotwordsBuf: String = "",
  hotwordsBufSize: Int = 0,
  hr: SherpaOnnxHomophoneReplacerConfig = sherpaOnnxHomophoneReplacerConfig()
) -> SherpaOnnxOnlineRecognizerConfig {
  return SherpaOnnxOnlineRecognizerConfig(
    feat_config: featConfig,
    model_config: modelConfig,
    decoding_method: toCPointer(decodingMethod),
    max_active_paths: Int32(maxActivePaths),
    enable_endpoint: enableEndpoint ? 1 : 0,
    rule1_min_trailing_silence: rule1MinTrailingSilence,
    rule2_min_trailing_silence: rule2MinTrailingSilence,
    rule3_min_utterance_length: rule3MinUtteranceLength,
    hotwords_file: toCPointer(hotwordsFile),
    hotwords_score: hotwordsScore,
    ctc_fst_decoder_config: ctcFstDecoderConfig,
    rule_fsts: toCPointer(ruleFsts),
    rule_fars: toCPointer(ruleFars),
    blank_penalty: blankPenalty,
    hotwords_buf: toCPointer(hotwordsBuf),
    hotwords_buf_size: Int32(hotwordsBufSize),
    hr: hr
  )
}

/// Wrapper for recognition result.
///
/// Usage:
///
///  let result = recognizer.getResult()
///  print("text: \(result.text)")
///
public class SherpaOnnxOnlineRecongitionResult {
  /// A pointer to the underlying counterpart in C
  private let result: UnsafePointer<SherpaOnnxOnlineRecognizerResult>

  private lazy var _text: String = {
    guard let cstr = result.pointee.text else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _tokens: [String] = {
    guard let tokensPointer = result.pointee.tokens_arr else { return [] }
    return (0..<count).compactMap { index in
      guard let ptr = tokensPointer[index] else { return nil }
      return String(cString: ptr)
    }
  }()

  private lazy var _timestamps: [Float] = {
    guard let timestampsPointer = result.pointee.timestamps else { return [] }
    return (0..<count).map { index in timestampsPointer[index] }
  }()

  public init(result: UnsafePointer<SherpaOnnxOnlineRecognizerResult>) {
    self.result = result
  }

  deinit {
    SherpaOnnxDestroyOnlineRecognizerResult(result)
  }

  /// Return the actual recognition result.
  /// For English models, it contains words separated by spaces.
  /// For Chinese models, it contains Chinese words.
  public var text: String { _text }

  public var count: Int { Int(result.pointee.count) }

  public var tokens: [String] { _tokens }

  public var timestamps: [Float] { _timestamps }
}

public class SherpaOnnxRecognizer {
  /// A pointer to the underlying counterpart in C
  private let recognizer: OpaquePointer
  private var stream: OpaquePointer
  private let lock = NSLock()  // for thread-safe stream replacement

  /// Constructor taking a model config. Returns nil if the C library
  /// fails to create the recognizer (e.g. missing model files).
  public init?(
    config: UnsafePointer<SherpaOnnxOnlineRecognizerConfig>
  ) {
    guard let rec = SherpaOnnxCreateOnlineRecognizer(config) else {
      return nil
    }
    self.recognizer = rec
    guard let s = SherpaOnnxCreateOnlineStream(rec) else {
      SherpaOnnxDestroyOnlineRecognizer(rec)
      return nil
    }
    self.stream = s
  }

  deinit {
    SherpaOnnxDestroyOnlineStream(stream)
    SherpaOnnxDestroyOnlineRecognizer(recognizer)
  }

  /// Decode wave samples.
  ///
  /// - Parameters:
  ///   - samples: Audio samples normalized to the range [-1, 1]
  ///   - sampleRate: Sample rate of the input audio samples. Must match
  ///                 the one expected by the model.
  public func acceptWaveform(samples: [Float], sampleRate: Int = 16_000) {
    SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), samples, Int32(samples.count))
  }

  public func isReady() -> Bool {
    return SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0
  }

  /// If there are enough number of feature frames, it invokes the neural
  /// network computation and decoding. Otherwise, it is a no-op.
  public func decode() {
    SherpaOnnxDecodeOnlineStream(recognizer, stream)
  }

  /// Get the decoding results so far
  public func getResult() -> SherpaOnnxOnlineRecongitionResult {
    guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else {
      fatalError("SherpaOnnxGetOnlineStreamResult returned nil")
    }
    return SherpaOnnxOnlineRecongitionResult(result: result)
  }

  /// Reset the recognizer, which clears the neural network model state
  /// and the state for decoding.
  /// If hotwords is an empty string, it just recreates the decoding stream
  /// If hotwords is not empty, it will create a new decoding stream with
  /// the given hotWords appended to the default hotwords.
  public func reset(hotwords: String? = nil) {
    guard let words = hotwords, !words.isEmpty else {
      SherpaOnnxOnlineStreamReset(recognizer, stream)
      return
    }

    words.withCString { cString in
      guard let newStream = SherpaOnnxCreateOnlineStreamWithHotwords(recognizer, cString) else {
        // Fall back to plain reset if hotwords stream creation fails
        SherpaOnnxOnlineStreamReset(recognizer, stream)
        return
      }
      lock.lock()
      // lock while release and replace stream
      SherpaOnnxDestroyOnlineStream(stream)
      stream = newStream
      lock.unlock()
    }
  }

  /// Signal that no more audio samples would be available.
  /// After this call, you cannot call acceptWaveform() any more.
  public func inputFinished() {
    SherpaOnnxOnlineStreamInputFinished(stream)
  }

  /// Return true is an endpoint has been detected.
  public func isEndpoint() -> Bool {
    return SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) != 0
  }
}

// For offline APIs

public func sherpaOnnxOfflineTransducerModelConfig(
  encoder: String = "",
  decoder: String = "",
  joiner: String = ""
) -> SherpaOnnxOfflineTransducerModelConfig {
  return SherpaOnnxOfflineTransducerModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    joiner: toCPointer(joiner)
  )
}

public func sherpaOnnxOfflineParaformerModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineParaformerModelConfig {
  return SherpaOnnxOfflineParaformerModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOfflineZipformerCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineZipformerCtcModelConfig {
  return SherpaOnnxOfflineZipformerCtcModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOfflineWenetCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineWenetCtcModelConfig {
  return SherpaOnnxOfflineWenetCtcModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineOmnilingualAsrCtcModelConfig {
  return SherpaOnnxOfflineOmnilingualAsrCtcModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOfflineMedAsrCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineMedAsrCtcModelConfig {
  return SherpaOnnxOfflineMedAsrCtcModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOfflineNemoEncDecCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineNemoEncDecCtcModelConfig {
  return SherpaOnnxOfflineNemoEncDecCtcModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOfflineDolphinModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineDolphinModelConfig {
  return SherpaOnnxOfflineDolphinModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOfflineWhisperModelConfig(
  encoder: String = "",
  decoder: String = "",
  language: String = "",
  task: String = "transcribe",
  tailPaddings: Int = -1
) -> SherpaOnnxOfflineWhisperModelConfig {
  return SherpaOnnxOfflineWhisperModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    language: toCPointer(language),
    task: toCPointer(task),
    tail_paddings: Int32(tailPaddings)
  )
}

public func sherpaOnnxOfflineCanaryModelConfig(
  encoder: String = "",
  decoder: String = "",
  srcLang: String = "en",
  tgtLang: String = "en",
  usePnc: Bool = true
) -> SherpaOnnxOfflineCanaryModelConfig {
  return SherpaOnnxOfflineCanaryModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    src_lang: toCPointer(srcLang),
    tgt_lang: toCPointer(tgtLang),
    use_pnc: usePnc ? 1 : 0
  )
}

public func sherpaOnnxOfflineFireRedAsrModelConfig(
  encoder: String = "",
  decoder: String = ""
) -> SherpaOnnxOfflineFireRedAsrModelConfig {
  return SherpaOnnxOfflineFireRedAsrModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder)
  )
}

public func sherpaOnnxOfflineMoonshineModelConfig(
  preprocessor: String = "",
  encoder: String = "",
  uncachedDecoder: String = "",
  cachedDecoder: String = ""
) -> SherpaOnnxOfflineMoonshineModelConfig {
  return SherpaOnnxOfflineMoonshineModelConfig(
    preprocessor: toCPointer(preprocessor),
    encoder: toCPointer(encoder),
    uncached_decoder: toCPointer(uncachedDecoder),
    cached_decoder: toCPointer(cachedDecoder)
  )
}

public func sherpaOnnxOfflineTdnnModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineTdnnModelConfig {
  return SherpaOnnxOfflineTdnnModelConfig(
    model: toCPointer(model)
  )
}

public func sherpaOnnxOfflineSenseVoiceModelConfig(
  model: String = "",
  language: String = "",
  useInverseTextNormalization: Bool = false
) -> SherpaOnnxOfflineSenseVoiceModelConfig {
  return SherpaOnnxOfflineSenseVoiceModelConfig(
    model: toCPointer(model),
    language: toCPointer(language),
    use_itn: useInverseTextNormalization ? 1 : 0
  )
}

public func sherpaOnnxOfflineLMConfig(
  model: String = "",
  scale: Float = 1.0
) -> SherpaOnnxOfflineLMConfig {
  return SherpaOnnxOfflineLMConfig(
    model: toCPointer(model),
    scale: scale
  )
}

public func sherpaOnnxOfflineFunASRNanoModelConfig(
  encoderAdaptor: String = "",
  llm: String = "",
  embedding: String = "",
  tokenizer: String = "",
  systemPrompt: String = "You are a helpful assistant.",
  userPrompt: String = "语音转写：",
  maxNewTokens: Int = 512,
  temperature: Float = 1e-6,
  topP: Float = 0.8,
  seed: Int = 42
) -> SherpaOnnxOfflineFunASRNanoModelConfig {
  return SherpaOnnxOfflineFunASRNanoModelConfig(
    encoder_adaptor: toCPointer(encoderAdaptor),
    llm: toCPointer(llm),
    embedding: toCPointer(embedding),
    tokenizer: toCPointer(tokenizer),
    system_prompt: toCPointer(systemPrompt),
    user_prompt: toCPointer(userPrompt),
    max_new_tokens: Int32(maxNewTokens),
    temperature: temperature,
    top_p: topP,
    seed: Int32(seed)
  )
}

public func sherpaOnnxOfflineModelConfig(
  tokens: String,
  transducer: SherpaOnnxOfflineTransducerModelConfig = sherpaOnnxOfflineTransducerModelConfig(),
  paraformer: SherpaOnnxOfflineParaformerModelConfig = sherpaOnnxOfflineParaformerModelConfig(),
  nemoCtc: SherpaOnnxOfflineNemoEncDecCtcModelConfig = sherpaOnnxOfflineNemoEncDecCtcModelConfig(),
  whisper: SherpaOnnxOfflineWhisperModelConfig = sherpaOnnxOfflineWhisperModelConfig(),
  tdnn: SherpaOnnxOfflineTdnnModelConfig = sherpaOnnxOfflineTdnnModelConfig(),
  numThreads: Int = 1,
  provider: String = "cpu",
  debug: Int = 0,
  modelType: String = "",
  modelingUnit: String = "cjkchar",
  bpeVocab: String = "",
  teleSpeechCtc: String = "",
  senseVoice: SherpaOnnxOfflineSenseVoiceModelConfig = sherpaOnnxOfflineSenseVoiceModelConfig(),
  moonshine: SherpaOnnxOfflineMoonshineModelConfig = sherpaOnnxOfflineMoonshineModelConfig(),
  fireRedAsr: SherpaOnnxOfflineFireRedAsrModelConfig = sherpaOnnxOfflineFireRedAsrModelConfig(),
  dolphin: SherpaOnnxOfflineDolphinModelConfig = sherpaOnnxOfflineDolphinModelConfig(),
  zipformerCtc: SherpaOnnxOfflineZipformerCtcModelConfig =
    sherpaOnnxOfflineZipformerCtcModelConfig(),
  canary: SherpaOnnxOfflineCanaryModelConfig = sherpaOnnxOfflineCanaryModelConfig(),
  wenetCtc: SherpaOnnxOfflineWenetCtcModelConfig =
    sherpaOnnxOfflineWenetCtcModelConfig(),
  omnilingual: SherpaOnnxOfflineOmnilingualAsrCtcModelConfig =
    sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(),
  medasr: SherpaOnnxOfflineMedAsrCtcModelConfig =
    sherpaOnnxOfflineMedAsrCtcModelConfig(),
  funasrNano: SherpaOnnxOfflineFunASRNanoModelConfig =
    sherpaOnnxOfflineFunASRNanoModelConfig()
) -> SherpaOnnxOfflineModelConfig {
  return SherpaOnnxOfflineModelConfig(
    transducer: transducer,
    paraformer: paraformer,
    nemo_ctc: nemoCtc,
    whisper: whisper,
    tdnn: tdnn,
    tokens: toCPointer(tokens),
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider),
    model_type: toCPointer(modelType),
    modeling_unit: toCPointer(modelingUnit),
    bpe_vocab: toCPointer(bpeVocab),
    telespeech_ctc: toCPointer(teleSpeechCtc),
    sense_voice: senseVoice,
    moonshine: moonshine,
    fire_red_asr: fireRedAsr,
    dolphin: dolphin,
    zipformer_ctc: zipformerCtc,
    canary: canary,
    wenet_ctc: wenetCtc,
    omnilingual: omnilingual,
    medasr: medasr,
    funasr_nano: funasrNano
  )
}

public func sherpaOnnxOfflineRecognizerConfig(
  featConfig: SherpaOnnxFeatureConfig,
  modelConfig: SherpaOnnxOfflineModelConfig,
  lmConfig: SherpaOnnxOfflineLMConfig = sherpaOnnxOfflineLMConfig(),
  decodingMethod: String = "greedy_search",
  maxActivePaths: Int = 4,
  hotwordsFile: String = "",
  hotwordsScore: Float = 1.5,
  ruleFsts: String = "",
  ruleFars: String = "",
  blankPenalty: Float = 0.0,
  hr: SherpaOnnxHomophoneReplacerConfig = sherpaOnnxHomophoneReplacerConfig()
) -> SherpaOnnxOfflineRecognizerConfig {
  return SherpaOnnxOfflineRecognizerConfig(
    feat_config: featConfig,
    model_config: modelConfig,
    lm_config: lmConfig,
    decoding_method: toCPointer(decodingMethod),
    max_active_paths: Int32(maxActivePaths),
    hotwords_file: toCPointer(hotwordsFile),
    hotwords_score: hotwordsScore,
    rule_fsts: toCPointer(ruleFsts),
    rule_fars: toCPointer(ruleFars),
    blank_penalty: blankPenalty,
    hr: hr
  )
}

public class SherpaOnnxOfflineRecongitionResult {
  /// A pointer to the underlying counterpart in C
  public let result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>

  private lazy var _text: String = {
    guard let cstr = result.pointee.text else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _timestamps: [Float] = {
    guard let p = result.pointee.timestamps else { return [] }
    return (0..<result.pointee.count).map { p[Int($0)] }
  }()

  private lazy var _durations: [Float] = {
    guard let p = result.pointee.durations else { return [] }
    return (0..<result.pointee.count).map { p[Int($0)] }
  }()

  private lazy var _lang: String = {
    guard let cstr = result.pointee.lang else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _emotion: String = {
    guard let cstr = result.pointee.emotion else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _event: String = {
    guard let cstr = result.pointee.event else { return "" }
    return String(cString: cstr)
  }()

  /// Return the actual recognition result.
  /// For English models, it contains words separated by spaces.
  /// For Chinese models, it contains Chinese words.
  public var text: String { _text }
  public var count: Int { Int(result.pointee.count) }
  public var timestamps: [Float] { _timestamps }

  // Non-empty for TDT models. Empty for all other non-TDT models
  public var durations: [Float] { _durations }

  // For SenseVoice models, it can be zh, en, ja, yue, ko
  // where zh is for Chinese
  // en is for English
  // ja is for Japanese
  // yue is for Cantonese
  // ko is for Korean
  public var lang: String { _lang }

  // for SenseVoice models
  public var emotion: String { _emotion }

  // for SenseVoice models
  public var event: String { _event }

  public init(result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>) {
    self.result = result
  }

  deinit {
    SherpaOnnxDestroyOfflineRecognizerResult(result)
  }
}

public class SherpaOnnxOfflineRecognizer {
  /// A pointer to the underlying counterpart in C
  private let recognizer: OpaquePointer

  /// Returns nil if the C library fails to create the recognizer
  /// (e.g. missing or invalid model files).
  public init?(
    config: UnsafePointer<SherpaOnnxOfflineRecognizerConfig>
  ) {
    guard let ptr = SherpaOnnxCreateOfflineRecognizer(config) else {
      return nil
    }
    self.recognizer = ptr
  }

  deinit {
    SherpaOnnxDestroyOfflineRecognizer(recognizer)
  }

  /// Decode wave samples.
  ///
  /// - Parameters:
  ///   - samples: Audio samples normalized to the range [-1, 1]
  ///   - sampleRate: Sample rate of the input audio samples. Must match
  ///                 the one expected by the model.
  public func decode(samples: [Float], sampleRate: Int = 16_000) -> SherpaOnnxOfflineRecongitionResult {
    guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
      fatalError("Failed to create offline stream")
    }

    defer { SherpaOnnxDestroyOfflineStream(stream) }

    SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), samples, Int32(samples.count))

    SherpaOnnxDecodeOfflineStream(recognizer, stream)

    guard let resultPtr = SherpaOnnxGetOfflineStreamResult(stream) else {
      fatalError("Failed to get offline recognition result")
    }

    return SherpaOnnxOfflineRecongitionResult(result: resultPtr)
  }

  public func setConfig(config: UnsafePointer<SherpaOnnxOfflineRecognizerConfig>) {
    SherpaOnnxOfflineRecognizerSetConfig(recognizer, config)
  }
}

public func sherpaOnnxSileroVadModelConfig(
  model: String = "",
  threshold: Float = 0.5,
  minSilenceDuration: Float = 0.25,
  minSpeechDuration: Float = 0.5,
  windowSize: Int = 512,
  maxSpeechDuration: Float = 5.0
) -> SherpaOnnxSileroVadModelConfig {
  return SherpaOnnxSileroVadModelConfig(
    model: toCPointer(model),
    threshold: threshold,
    min_silence_duration: minSilenceDuration,
    min_speech_duration: minSpeechDuration,
    window_size: Int32(windowSize),
    max_speech_duration: maxSpeechDuration
  )
}

public func sherpaOnnxTenVadModelConfig(
  model: String = "",
  threshold: Float = 0.5,
  minSilenceDuration: Float = 0.25,
  minSpeechDuration: Float = 0.5,
  windowSize: Int = 256,
  maxSpeechDuration: Float = 5.0
) -> SherpaOnnxTenVadModelConfig {
  return SherpaOnnxTenVadModelConfig(
    model: toCPointer(model),
    threshold: threshold,
    min_silence_duration: minSilenceDuration,
    min_speech_duration: minSpeechDuration,
    window_size: Int32(windowSize),
    max_speech_duration: maxSpeechDuration
  )
}

public func sherpaOnnxVadModelConfig(
  sileroVad: SherpaOnnxSileroVadModelConfig = sherpaOnnxSileroVadModelConfig(),
  sampleRate: Int32 = 16000,
  numThreads: Int = 1,
  provider: String = "cpu",
  debug: Int = 0,
  tenVad: SherpaOnnxTenVadModelConfig = sherpaOnnxTenVadModelConfig()
) -> SherpaOnnxVadModelConfig {
  return SherpaOnnxVadModelConfig(
    silero_vad: sileroVad,
    sample_rate: sampleRate,
    num_threads: Int32(numThreads),
    provider: toCPointer(provider),
    debug: Int32(debug),
    ten_vad: tenVad
  )
}

public class SherpaOnnxCircularBufferWrapper {
  private let buffer: OpaquePointer

  public init(capacity: Int) {
    guard let ptr = SherpaOnnxCreateCircularBuffer(Int32(capacity)) else {
      fatalError("Failed to create SherpaOnnxCircularBuffer")
    }
    self.buffer = ptr
  }

  deinit {
    SherpaOnnxDestroyCircularBuffer(buffer)
  }

  public func push(samples: [Float]) {
    guard !samples.isEmpty else { return }
    SherpaOnnxCircularBufferPush(buffer, samples, Int32(samples.count))
  }

  public func get(startIndex: Int, n: Int) -> [Float] {
    guard startIndex >= 0 else { return [] }
    guard n > 0 else { return [] }

    guard let ptr = SherpaOnnxCircularBufferGet(buffer, Int32(startIndex), Int32(n)) else {
      return []
    }
    defer { SherpaOnnxCircularBufferFree(ptr) }

    return Array(UnsafeBufferPointer(start: ptr, count: n))
  }

  public func pop(n: Int) {
    guard n > 0 else { return }
    SherpaOnnxCircularBufferPop(buffer, Int32(n))
  }

  public func size() -> Int {
    return Int(SherpaOnnxCircularBufferSize(buffer))
  }

  public func reset() {
    SherpaOnnxCircularBufferReset(buffer)
  }
}

public class SherpaOnnxSpeechSegmentWrapper {
  private let p: UnsafePointer<SherpaOnnxSpeechSegment>

  public init(p: UnsafePointer<SherpaOnnxSpeechSegment>) {
    self.p = p
  }

  deinit {
    SherpaOnnxDestroySpeechSegment(p)
  }

  public var start: Int {
    Int(p.pointee.start)
  }

  public var n: Int {
    Int(p.pointee.n)
  }

  lazy var samples: [Float] = {
    Array(UnsafeBufferPointer(start: p.pointee.samples, count: n))
  }()
}

public class SherpaOnnxVoiceActivityDetectorWrapper {
  /// A pointer to the underlying counterpart in C
  private let vad: OpaquePointer

  public init(config: UnsafePointer<SherpaOnnxVadModelConfig>, buffer_size_in_seconds: Float) {
    guard let vad = SherpaOnnxCreateVoiceActivityDetector(config, buffer_size_in_seconds) else {
      fatalError("SherpaOnnxCreateVoiceActivityDetector returned nil")
    }
    self.vad = vad
  }

  deinit {
    SherpaOnnxDestroyVoiceActivityDetector(vad)
  }

  public func acceptWaveform(samples: [Float]) {
    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, samples, Int32(samples.count))
  }

  public func isEmpty() -> Bool {
    return SherpaOnnxVoiceActivityDetectorEmpty(vad) == 1
  }

  public func isSpeechDetected() -> Bool {
    return SherpaOnnxVoiceActivityDetectorDetected(vad) == 1
  }

  public func pop() {
    SherpaOnnxVoiceActivityDetectorPop(vad)
  }

  public func clear() {
    SherpaOnnxVoiceActivityDetectorClear(vad)
  }

  public func front() -> SherpaOnnxSpeechSegmentWrapper {
    guard let p = SherpaOnnxVoiceActivityDetectorFront(vad) else {
      fatalError("SherpaOnnxVoiceActivityDetectorFront returned nil")
    }
    return SherpaOnnxSpeechSegmentWrapper(p: p)
  }

  public func reset() {
    SherpaOnnxVoiceActivityDetectorReset(vad)
  }

  public func flush() {
    SherpaOnnxVoiceActivityDetectorFlush(vad)
  }
}

// offline tts
public func sherpaOnnxOfflineTtsVitsModelConfig(
  model: String = "",
  lexicon: String = "",
  tokens: String = "",
  dataDir: String = "",
  noiseScale: Float = 0.667,
  noiseScaleW: Float = 0.8,
  lengthScale: Float = 1.0,
  dictDir: String = ""
) -> SherpaOnnxOfflineTtsVitsModelConfig {
  return SherpaOnnxOfflineTtsVitsModelConfig(
    model: toCPointer(model),
    lexicon: toCPointer(lexicon),
    tokens: toCPointer(tokens),
    data_dir: toCPointer(dataDir),
    noise_scale: noiseScale,
    noise_scale_w: noiseScaleW,
    length_scale: lengthScale,
    dict_dir: toCPointer(dictDir)
  )
}

public func sherpaOnnxOfflineTtsMatchaModelConfig(
  acousticModel: String = "",
  vocoder: String = "",
  lexicon: String = "",
  tokens: String = "",
  dataDir: String = "",
  noiseScale: Float = 0.667,
  lengthScale: Float = 1.0,
  dictDir: String = ""
) -> SherpaOnnxOfflineTtsMatchaModelConfig {
  return SherpaOnnxOfflineTtsMatchaModelConfig(
    acoustic_model: toCPointer(acousticModel),
    vocoder: toCPointer(vocoder),
    lexicon: toCPointer(lexicon),
    tokens: toCPointer(tokens),
    data_dir: toCPointer(dataDir),
    noise_scale: noiseScale,
    length_scale: lengthScale,
    dict_dir: toCPointer(dictDir)
  )
}

public func sherpaOnnxOfflineTtsKokoroModelConfig(
  model: String = "",
  voices: String = "",
  tokens: String = "",
  dataDir: String = "",
  lengthScale: Float = 1.0,
  dictDir: String = "",
  lexicon: String = "",
  lang: String = ""
) -> SherpaOnnxOfflineTtsKokoroModelConfig {
  return SherpaOnnxOfflineTtsKokoroModelConfig(
    model: toCPointer(model),
    voices: toCPointer(voices),
    tokens: toCPointer(tokens),
    data_dir: toCPointer(dataDir),
    length_scale: lengthScale,
    dict_dir: toCPointer(dictDir),
    lexicon: toCPointer(lexicon),
    lang: toCPointer(lang)
  )
}

public func sherpaOnnxOfflineTtsKittenModelConfig(
  model: String = "",
  voices: String = "",
  tokens: String = "",
  dataDir: String = "",
  lengthScale: Float = 1.0
) -> SherpaOnnxOfflineTtsKittenModelConfig {
  return SherpaOnnxOfflineTtsKittenModelConfig(
    model: toCPointer(model),
    voices: toCPointer(voices),
    tokens: toCPointer(tokens),
    data_dir: toCPointer(dataDir),
    length_scale: lengthScale
  )
}

public func sherpaOnnxOfflineTtsZipvoiceModelConfig(
  tokens: String = "",
  encoder: String = "",
  decoder: String = "",
  vocoder: String = "",
  dataDir: String = "",
  lexicon: String = "",
  featScale: Float = 0.1,
  tShift: Float = 0.5,
  targetRms: Float = 0.1,
  guidanceScale: Float = 1.0
) -> SherpaOnnxOfflineTtsZipvoiceModelConfig {
  return SherpaOnnxOfflineTtsZipvoiceModelConfig(
    tokens: toCPointer(tokens),
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    vocoder: toCPointer(vocoder),
    data_dir: toCPointer(dataDir),
    lexicon: toCPointer(lexicon),
    feat_scale: featScale,
    t_shift: tShift,
    target_rms: targetRms,
    guidance_scale: guidanceScale
  )
}

public func sherpaOnnxOfflineTtsModelConfig(
  vits: SherpaOnnxOfflineTtsVitsModelConfig = sherpaOnnxOfflineTtsVitsModelConfig(),
  matcha: SherpaOnnxOfflineTtsMatchaModelConfig = sherpaOnnxOfflineTtsMatchaModelConfig(),
  kokoro: SherpaOnnxOfflineTtsKokoroModelConfig = sherpaOnnxOfflineTtsKokoroModelConfig(),
  numThreads: Int = 1,
  debug: Int = 0,
  provider: String = "cpu",
  kitten: SherpaOnnxOfflineTtsKittenModelConfig = sherpaOnnxOfflineTtsKittenModelConfig(),
  zipvoice: SherpaOnnxOfflineTtsZipvoiceModelConfig = sherpaOnnxOfflineTtsZipvoiceModelConfig()
) -> SherpaOnnxOfflineTtsModelConfig {
  return SherpaOnnxOfflineTtsModelConfig(
    vits: vits,
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider),
    matcha: matcha,
    kokoro: kokoro,
    kitten: kitten,
    zipvoice: zipvoice
  )
}

public func sherpaOnnxOfflineTtsConfig(
  model: SherpaOnnxOfflineTtsModelConfig,
  ruleFsts: String = "",
  ruleFars: String = "",
  maxNumSentences: Int = 1,
  silenceScale: Float = 0.2
) -> SherpaOnnxOfflineTtsConfig {
  return SherpaOnnxOfflineTtsConfig(
    model: model,
    rule_fsts: toCPointer(ruleFsts),
    max_num_sentences: Int32(maxNumSentences),
    rule_fars: toCPointer(ruleFars),
    silence_scale: silenceScale
  )
}

public class SherpaOnnxWaveWrapper {
  public let wave: UnsafePointer<SherpaOnnxWave>!

  public class func readWave(filename: String) -> SherpaOnnxWaveWrapper {
    let wave = SherpaOnnxReadWave(toCPointer(filename))
    return SherpaOnnxWaveWrapper(wave: wave)
  }

  public init(wave: UnsafePointer<SherpaOnnxWave>!) {
    self.wave = wave
  }

  deinit {
    if let wave {
      SherpaOnnxFreeWave(wave)
    }
  }

  public var numSamples: Int {
    return Int(wave.pointee.num_samples)
  }

  public var sampleRate: Int {
    return Int(wave.pointee.sample_rate)
  }

  public var samples: [Float] {
    if numSamples == 0 {
      return []
    } else {
      return [Float](UnsafeBufferPointer(start: wave.pointee.samples, count: numSamples))
    }
  }
}

public class SherpaOnnxGeneratedAudioWrapper {
  /// A pointer to the underlying counterpart in C
  public let audio: UnsafePointer<SherpaOnnxGeneratedAudio>!

  public init(audio: UnsafePointer<SherpaOnnxGeneratedAudio>!) {
    self.audio = audio
  }

  deinit {
    if let audio {
      SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)
    }
  }

  public var n: Int32 {
    return audio.pointee.n
  }

  public var sampleRate: Int32 {
    return audio.pointee.sample_rate
  }

  public var samples: [Float] {
    if let p = audio.pointee.samples {
      return [Float](UnsafeBufferPointer(start: p, count: Int(n)))
    } else {
      return []
    }
  }

  public func save(filename: String) -> Int32 {
    return SherpaOnnxWriteWave(audio.pointee.samples, n, sampleRate, toCPointer(filename))
  }
}

public typealias TtsCallbackWithArg = (
  @convention(c) (
    UnsafePointer<Float>?,  // const float* samples
    Int32,  // int32_t n
    UnsafeMutableRawPointer?  // void *arg
  ) -> Int32
)?

public class SherpaOnnxOfflineTtsWrapper {
  /// A pointer to the underlying counterpart in C
  public let tts: OpaquePointer!

  /// Constructor taking a model config
  public init(
    config: UnsafePointer<SherpaOnnxOfflineTtsConfig>!
  ) {
    tts = SherpaOnnxCreateOfflineTts(config)
  }

  deinit {
    if let tts {
      SherpaOnnxDestroyOfflineTts(tts)
    }
  }

  public func generate(text: String, sid: Int = 0, speed: Float = 1.0) -> SherpaOnnxGeneratedAudioWrapper {
    let audio: UnsafePointer<SherpaOnnxGeneratedAudio>? = SherpaOnnxOfflineTtsGenerate(
      tts, toCPointer(text), Int32(sid), speed)

    return SherpaOnnxGeneratedAudioWrapper(audio: audio)
  }

  public func generateWithCallbackWithArg(
    text: String, callback: TtsCallbackWithArg, arg: UnsafeMutableRawPointer, sid: Int = 0,
    speed: Float = 1.0
  ) -> SherpaOnnxGeneratedAudioWrapper {
    let audio: UnsafePointer<SherpaOnnxGeneratedAudio>? =
      SherpaOnnxOfflineTtsGenerateWithCallbackWithArg(
        tts, toCPointer(text), Int32(sid), speed, callback, arg)

    return SherpaOnnxGeneratedAudioWrapper(audio: audio)
  }
}

// spoken language identification

public func sherpaOnnxSpokenLanguageIdentificationWhisperConfig(
  encoder: String,
  decoder: String,
  tailPaddings: Int = -1
) -> SherpaOnnxSpokenLanguageIdentificationWhisperConfig {
  return SherpaOnnxSpokenLanguageIdentificationWhisperConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    tail_paddings: Int32(tailPaddings))
}

public func sherpaOnnxSpokenLanguageIdentificationConfig(
  whisper: SherpaOnnxSpokenLanguageIdentificationWhisperConfig,
  numThreads: Int = 1,
  debug: Int = 0,
  provider: String = "cpu"
) -> SherpaOnnxSpokenLanguageIdentificationConfig {
  return SherpaOnnxSpokenLanguageIdentificationConfig(
    whisper: whisper,
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider))
}

public class SherpaOnnxSpokenLanguageIdentificationResultWrapper {
  /// A pointer to the underlying counterpart in C
  public let result: UnsafePointer<SherpaOnnxSpokenLanguageIdentificationResult>!

  /// Return the detected language.
  /// en for English
  /// zh for Chinese
  /// es for Spanish
  /// de for German
  /// etc.
  public var lang: String {
    return String(cString: result.pointee.lang)
  }

  public init(result: UnsafePointer<SherpaOnnxSpokenLanguageIdentificationResult>!) {
    self.result = result
  }

  deinit {
    if let result {
      SherpaOnnxDestroySpokenLanguageIdentificationResult(result)
    }
  }
}

public class SherpaOnnxSpokenLanguageIdentificationWrapper {
  /// A pointer to the underlying counterpart in C
  public let slid: OpaquePointer!

  public init(
    config: UnsafePointer<SherpaOnnxSpokenLanguageIdentificationConfig>!
  ) {
    slid = SherpaOnnxCreateSpokenLanguageIdentification(config)
  }

  deinit {
    if let slid {
      SherpaOnnxDestroySpokenLanguageIdentification(slid)
    }
  }

  public func decode(samples: [Float], sampleRate: Int = 16000)
    -> SherpaOnnxSpokenLanguageIdentificationResultWrapper
  {
    let stream: OpaquePointer! = SherpaOnnxSpokenLanguageIdentificationCreateOfflineStream(slid)
    SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), samples, Int32(samples.count))

    let result: UnsafePointer<SherpaOnnxSpokenLanguageIdentificationResult>? =
      SherpaOnnxSpokenLanguageIdentificationCompute(
        slid,
        stream)

    SherpaOnnxDestroyOfflineStream(stream)
    return SherpaOnnxSpokenLanguageIdentificationResultWrapper(result: result)
  }
}

// keyword spotting

public class SherpaOnnxKeywordResultWrapper {
  /// A pointer to the underlying counterpart in C
  public let result: UnsafePointer<SherpaOnnxKeywordResult>!

  public var keyword: String {
    return String(cString: result.pointee.keyword)
  }

  public var count: Int32 {
    return result.pointee.count
  }

  public var tokens: [String] {
    if let tokensPointer = result.pointee.tokens_arr {
      var tokens: [String] = []
      for index in 0..<count {
        if let tokenPointer = tokensPointer[Int(index)] {
          let token = String(cString: tokenPointer)
          tokens.append(token)
        }
      }
      return tokens
    } else {
      let tokens: [String] = []
      return tokens
    }
  }

  public init(result: UnsafePointer<SherpaOnnxKeywordResult>!) {
    self.result = result
  }

  deinit {
    if let result {
      SherpaOnnxDestroyKeywordResult(result)
    }
  }
}

public func sherpaOnnxKeywordSpotterConfig(
  featConfig: SherpaOnnxFeatureConfig,
  modelConfig: SherpaOnnxOnlineModelConfig,
  keywordsFile: String,
  maxActivePaths: Int = 4,
  numTrailingBlanks: Int = 1,
  keywordsScore: Float = 1.0,
  keywordsThreshold: Float = 0.25,
  keywordsBuf: String = "",
  keywordsBufSize: Int = 0
) -> SherpaOnnxKeywordSpotterConfig {
  return SherpaOnnxKeywordSpotterConfig(
    feat_config: featConfig,
    model_config: modelConfig,
    max_active_paths: Int32(maxActivePaths),
    num_trailing_blanks: Int32(numTrailingBlanks),
    keywords_score: keywordsScore,
    keywords_threshold: keywordsThreshold,
    keywords_file: toCPointer(keywordsFile),
    keywords_buf: toCPointer(keywordsBuf),
    keywords_buf_size: Int32(keywordsBufSize)
  )
}

public class SherpaOnnxKeywordSpotterWrapper {
  /// A pointer to the underlying counterpart in C
  public let spotter: OpaquePointer!
  public var stream: OpaquePointer!

  public init(
    config: UnsafePointer<SherpaOnnxKeywordSpotterConfig>!
  ) {
    spotter = SherpaOnnxCreateKeywordSpotter(config)
    stream = SherpaOnnxCreateKeywordStream(spotter)
  }

  deinit {
    if let stream {
      SherpaOnnxDestroyOnlineStream(stream)
    }

    if let spotter {
      SherpaOnnxDestroyKeywordSpotter(spotter)
    }
  }

  public func acceptWaveform(samples: [Float], sampleRate: Int = 16000) {
    SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), samples, Int32(samples.count))
  }

  public func isReady() -> Bool {
    return SherpaOnnxIsKeywordStreamReady(spotter, stream) == 1 ? true : false
  }

  public func decode() {
    SherpaOnnxDecodeKeywordStream(spotter, stream)
  }

  public func reset() {
    SherpaOnnxResetKeywordStream(spotter, stream)
  }

  public func getResult() -> SherpaOnnxKeywordResultWrapper {
    let result: UnsafePointer<SherpaOnnxKeywordResult>? = SherpaOnnxGetKeywordResult(
      spotter, stream)
    return SherpaOnnxKeywordResultWrapper(result: result)
  }

  /// Signal that no more audio samples would be available.
  /// After this call, you cannot call acceptWaveform() any more.
  public func inputFinished() {
    SherpaOnnxOnlineStreamInputFinished(stream)
  }
}

// Punctuation

public func sherpaOnnxOfflinePunctuationModelConfig(
  ctTransformer: String,
  numThreads: Int = 1,
  debug: Int = 0,
  provider: String = "cpu"
) -> SherpaOnnxOfflinePunctuationModelConfig {
  return SherpaOnnxOfflinePunctuationModelConfig(
    ct_transformer: toCPointer(ctTransformer),
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider)
  )
}

public func sherpaOnnxOfflinePunctuationConfig(
  model: SherpaOnnxOfflinePunctuationModelConfig
) -> SherpaOnnxOfflinePunctuationConfig {
  return SherpaOnnxOfflinePunctuationConfig(
    model: model
  )
}

public class SherpaOnnxOfflinePunctuationWrapper {
  /// A pointer to the underlying counterpart in C
  public let ptr: OpaquePointer!

  /// Constructor taking a model config
  public init(
    config: UnsafePointer<SherpaOnnxOfflinePunctuationConfig>!
  ) {
    ptr = SherpaOnnxCreateOfflinePunctuation(config)
  }

  deinit {
    if let ptr {
      SherpaOnnxDestroyOfflinePunctuation(ptr)
    }
  }

  public func addPunct(text: String) -> String {
    let cText = SherpaOfflinePunctuationAddPunct(ptr, toCPointer(text))
    let ans = String(cString: cText!)
    SherpaOfflinePunctuationFreeText(cText)
    return ans
  }
}

public func sherpaOnnxOnlinePunctuationModelConfig(
  cnnBiLstm: String,
  bpeVocab: String,
  numThreads: Int = 1,
  debug: Int = 0,
  provider: String = "cpu"
) -> SherpaOnnxOnlinePunctuationModelConfig {
  return SherpaOnnxOnlinePunctuationModelConfig(
    cnn_bilstm: toCPointer(cnnBiLstm),
    bpe_vocab: toCPointer(bpeVocab),
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider))
}

public func sherpaOnnxOnlinePunctuationConfig(
  model: SherpaOnnxOnlinePunctuationModelConfig
) -> SherpaOnnxOnlinePunctuationConfig {
  return SherpaOnnxOnlinePunctuationConfig(model: model)
}

public class SherpaOnnxOnlinePunctuationWrapper {
  /// A pointer to the underlying counterpart in C
  public let ptr: OpaquePointer!

  /// Constructor taking a model config
  public init(
    config: UnsafePointer<SherpaOnnxOnlinePunctuationConfig>!
  ) {
    ptr = SherpaOnnxCreateOnlinePunctuation(config)
  }

  deinit {
    if let ptr {
      SherpaOnnxDestroyOnlinePunctuation(ptr)
    }
  }

  public func addPunct(text: String) -> String {
    let cText = SherpaOnnxOnlinePunctuationAddPunct(ptr, toCPointer(text))
    let ans = String(cString: cText!)
    SherpaOnnxOnlinePunctuationFreeText(cText)
    return ans
  }
}

public func sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: String)
  -> SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig
{
  return SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: toCPointer(model))
}

public func sherpaOnnxOfflineSpeakerSegmentationModelConfig(
  pyannote: SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig,
  numThreads: Int = 1,
  debug: Int = 0,
  provider: String = "cpu"
) -> SherpaOnnxOfflineSpeakerSegmentationModelConfig {
  return SherpaOnnxOfflineSpeakerSegmentationModelConfig(
    pyannote: pyannote,
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider)
  )
}

public func sherpaOnnxFastClusteringConfig(numClusters: Int = -1, threshold: Float = 0.5)
  -> SherpaOnnxFastClusteringConfig
{
  return SherpaOnnxFastClusteringConfig(num_clusters: Int32(numClusters), threshold: threshold)
}

public func sherpaOnnxSpeakerEmbeddingExtractorConfig(
  model: String,
  numThreads: Int = 1,
  debug: Int = 0,
  provider: String = "cpu"
) -> SherpaOnnxSpeakerEmbeddingExtractorConfig {
  return SherpaOnnxSpeakerEmbeddingExtractorConfig(
    model: toCPointer(model),
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider)
  )
}

public func sherpaOnnxOfflineSpeakerDiarizationConfig(
  segmentation: SherpaOnnxOfflineSpeakerSegmentationModelConfig,
  embedding: SherpaOnnxSpeakerEmbeddingExtractorConfig,
  clustering: SherpaOnnxFastClusteringConfig,
  minDurationOn: Float = 0.3,
  minDurationOff: Float = 0.5
) -> SherpaOnnxOfflineSpeakerDiarizationConfig {
  return SherpaOnnxOfflineSpeakerDiarizationConfig(
    segmentation: segmentation,
    embedding: embedding,
    clustering: clustering,
    min_duration_on: minDurationOn,
    min_duration_off: minDurationOff
  )
}

public struct SherpaOnnxOfflineSpeakerDiarizationSegmentWrapper {
  public var start: Float = 0
  public var end: Float = 0
  public var speaker: Int = 0
}

public class SherpaOnnxOfflineSpeakerDiarizationWrapper {
  /// A pointer to the underlying counterpart in C
  public let impl: OpaquePointer!

  public init(
    config: UnsafePointer<SherpaOnnxOfflineSpeakerDiarizationConfig>!
  ) {
    impl = SherpaOnnxCreateOfflineSpeakerDiarization(config)
  }

  deinit {
    if let impl {
      SherpaOnnxDestroyOfflineSpeakerDiarization(impl)
    }
  }

  public var sampleRate: Int {
    return Int(SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(impl))
  }

  // only config.clustering is used. All other fields are ignored
  public func setConfig(config: UnsafePointer<SherpaOnnxOfflineSpeakerDiarizationConfig>!) {
    SherpaOnnxOfflineSpeakerDiarizationSetConfig(impl, config)
  }

  public func process(samples: [Float]) -> [SherpaOnnxOfflineSpeakerDiarizationSegmentWrapper] {
    let result = SherpaOnnxOfflineSpeakerDiarizationProcess(
      impl, samples, Int32(samples.count))

    if result == nil {
      return []
    }

    let numSegments = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))

    let p: UnsafePointer<SherpaOnnxOfflineSpeakerDiarizationSegment>? =
      SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result)

    if p == nil {
      return []
    }

    var ans: [SherpaOnnxOfflineSpeakerDiarizationSegmentWrapper] = []
    for i in 0..<numSegments {
      ans.append(
        SherpaOnnxOfflineSpeakerDiarizationSegmentWrapper(
          start: p![i].start, end: p![i].end, speaker: Int(p![i].speaker)))
    }

    SherpaOnnxOfflineSpeakerDiarizationDestroySegment(p)
    SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result)

    return ans
  }
}

public class SherpaOnnxOnlineStreamWrapper {
  /// A pointer to the underlying counterpart in C
  public let impl: OpaquePointer!
  public init(impl: OpaquePointer!) {
    self.impl = impl
  }

  deinit {
    if let impl {
      SherpaOnnxDestroyOnlineStream(impl)
    }
  }

  public func acceptWaveform(samples: [Float], sampleRate: Int = 16000) {
    SherpaOnnxOnlineStreamAcceptWaveform(impl, Int32(sampleRate), samples, Int32(samples.count))
  }

  public func inputFinished() {
    SherpaOnnxOnlineStreamInputFinished(impl)
  }
}

public class SherpaOnnxSpeakerEmbeddingExtractorWrapper {
  /// A pointer to the underlying counterpart in C
  public let impl: OpaquePointer!

  public init(
    config: UnsafePointer<SherpaOnnxSpeakerEmbeddingExtractorConfig>!
  ) {
    impl = SherpaOnnxCreateSpeakerEmbeddingExtractor(config)
  }

  deinit {
    if let impl {
      SherpaOnnxDestroySpeakerEmbeddingExtractor(impl)
    }
  }

  public var dim: Int {
    return Int(SherpaOnnxSpeakerEmbeddingExtractorDim(impl))
  }

  public func createStream() -> SherpaOnnxOnlineStreamWrapper {
    let newStream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(impl)
    return SherpaOnnxOnlineStreamWrapper(impl: newStream)
  }

  public func isReady(stream: SherpaOnnxOnlineStreamWrapper) -> Bool {
    return SherpaOnnxSpeakerEmbeddingExtractorIsReady(impl, stream.impl) == 1 ? true : false
  }

  public func compute(stream: SherpaOnnxOnlineStreamWrapper) -> [Float] {
    if !isReady(stream: stream) {
      return []
    }

    let p = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(impl, stream.impl)

    defer {
      SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(p)
    }

    return [Float](UnsafeBufferPointer(start: p, count: dim))
  }
}

public func sherpaOnnxOfflineSpeechDenoiserGtcrnModelConfig(model: String = "")
  -> SherpaOnnxOfflineSpeechDenoiserGtcrnModelConfig
{
  return SherpaOnnxOfflineSpeechDenoiserGtcrnModelConfig(model: toCPointer(model))
}

public func sherpaOnnxOfflineSpeechDenoiserModelConfig(
  gtcrn: SherpaOnnxOfflineSpeechDenoiserGtcrnModelConfig =
    sherpaOnnxOfflineSpeechDenoiserGtcrnModelConfig(),
  numThreads: Int = 1,
  provider: String = "cpu",
  debug: Int = 0
) -> SherpaOnnxOfflineSpeechDenoiserModelConfig {
  return SherpaOnnxOfflineSpeechDenoiserModelConfig(
    gtcrn: gtcrn,
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider)
  )
}

public func sherpaOnnxOfflineSpeechDenoiserConfig(
  model: SherpaOnnxOfflineSpeechDenoiserModelConfig =
    sherpaOnnxOfflineSpeechDenoiserModelConfig()
) -> SherpaOnnxOfflineSpeechDenoiserConfig {
  return SherpaOnnxOfflineSpeechDenoiserConfig(
    model: model)
}

public class SherpaOnnxDenoisedAudioWrapper {
  /// A pointer to the underlying counterpart in C
  public let audio: UnsafePointer<SherpaOnnxDenoisedAudio>!

  public init(audio: UnsafePointer<SherpaOnnxDenoisedAudio>!) {
    self.audio = audio
  }

  deinit {
    if let audio {
      SherpaOnnxDestroyDenoisedAudio(audio)
    }
  }

  public var n: Int32 {
    return audio.pointee.n
  }

  public var sampleRate: Int32 {
    return audio.pointee.sample_rate
  }

  public var samples: [Float] {
    if let p = audio.pointee.samples {
      var samples: [Float] = []
      for index in 0..<n {
        samples.append(p[Int(index)])
      }
      return samples
    } else {
      let samples: [Float] = []
      return samples
    }
  }

  public func save(filename: String) -> Int32 {
    return SherpaOnnxWriteWave(audio.pointee.samples, n, sampleRate, toCPointer(filename))
  }
}

public class SherpaOnnxOfflineSpeechDenoiserWrapper {
  /// A pointer to the underlying counterpart in C
  public let impl: OpaquePointer!

  /// Constructor taking a model config
  public init(
    config: UnsafePointer<SherpaOnnxOfflineSpeechDenoiserConfig>!
  ) {
    impl = SherpaOnnxCreateOfflineSpeechDenoiser(config)
  }

  deinit {
    if let impl {
      SherpaOnnxDestroyOfflineSpeechDenoiser(impl)
    }
  }

  public func run(samples: [Float], sampleRate: Int) -> SherpaOnnxDenoisedAudioWrapper {
    let audio: UnsafePointer<SherpaOnnxDenoisedAudio>? = SherpaOnnxOfflineSpeechDenoiserRun(
      impl, samples, Int32(samples.count), Int32(sampleRate))

    return SherpaOnnxDenoisedAudioWrapper(audio: audio)
  }

  public var sampleRate: Int {
    return Int(SherpaOnnxOfflineSpeechDenoiserGetSampleRate(impl))
  }
}

public func getSherpaOnnxVersion() -> String {
  return String(cString: SherpaOnnxGetVersionStr())
}

public func getSherpaOnnxGitSha1() -> String {
  return String(cString: SherpaOnnxGetGitSha1())
}

public func getSherpaOnnxGitDate() -> String {
  return String(cString: SherpaOnnxGetGitDate())
}
