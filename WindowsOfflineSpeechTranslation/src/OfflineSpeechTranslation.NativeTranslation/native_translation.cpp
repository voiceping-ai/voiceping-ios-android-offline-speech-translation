#include <algorithm>
#include <cstdint>
#include <cstring>
#include <exception>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include <ctranslate2/models/model_loader.h>
#include <ctranslate2/translator.h>

#include <sentencepiece_processor.h>

#if defined(_WIN32)
#  define OST_EXPORT __declspec(dllexport)
#else
#  define OST_EXPORT
#endif

namespace {

constexpr int kOk = 0;
constexpr int kError = 1;
constexpr int kBufferTooSmall = 2;

static void write_error(char* buf, int buf_len, const std::string& msg) {
  if (!buf || buf_len <= 0) return;
  const int n = std::min<int>(buf_len - 1, static_cast<int>(msg.size()));
  std::memcpy(buf, msg.data(), n);
  buf[n] = '\0';
}

static std::vector<std::string> split_ws(const std::string& s) {
  std::vector<std::string> out;
  std::string cur;
  for (char c : s) {
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      if (!cur.empty()) {
        out.emplace_back(std::move(cur));
        cur.clear();
      }
    } else {
      cur.push_back(c);
    }
  }
  if (!cur.empty()) out.emplace_back(std::move(cur));
  return out;
}

static std::string join_ws(const std::vector<std::string>& tokens) {
  std::ostringstream oss;
  for (size_t i = 0; i < tokens.size(); i++) {
    if (i) oss << ' ';
    oss << tokens[i];
  }
  return oss.str();
}

static bool file_exists(const std::string& path) {
#if defined(_WIN32)
  FILE* f = nullptr;
  if (fopen_s(&f, path.c_str(), "rb") == 0 && f) {
    fclose(f);
    return true;
  }
  return false;
#else
  FILE* f = fopen(path.c_str(), "rb");
  if (f) {
    fclose(f);
    return true;
  }
  return false;
#endif
}

struct TranslatorWrapper {
  explicit TranslatorWrapper(const std::string& model_dir)
      : model_loader(model_dir),
        translator(model_loader),
        has_sentencepiece(false) {
    // Optional: load SentencePiece models from the same folder as the CT2 model.
    // Expected files:
    // - source.spm (or spm.model)
    // - target.spm (or spm.model)
    std::string src_spm = model_dir + "/source.spm";
    std::string tgt_spm = model_dir + "/target.spm";
    std::string shared_spm = model_dir + "/spm.model";

    if (!file_exists(src_spm) && file_exists(shared_spm)) src_spm = shared_spm;
    if (!file_exists(tgt_spm) && file_exists(shared_spm)) tgt_spm = shared_spm;

    if (file_exists(src_spm) && file_exists(tgt_spm)) {
      const auto src_status = sp_src.Load(src_spm);
      const auto tgt_status = sp_tgt.Load(tgt_spm);
      if (src_status.ok() && tgt_status.ok()) {
        has_sentencepiece = true;
      }
    }
  }

  ctranslate2::models::ModelLoader model_loader;
  ctranslate2::Translator translator;
  sentencepiece::SentencePieceProcessor sp_src;
  sentencepiece::SentencePieceProcessor sp_tgt;
  bool has_sentencepiece;
  std::mutex mu;

  std::string translate_text(const std::string& input) {
    std::vector<std::string> src_tokens;
    if (has_sentencepiece) {
      sp_src.Encode(input, &src_tokens);
    } else {
      src_tokens = split_ws(input);
    }

    // Marian/OPUS-MT style models often expect an explicit EOS token.
    if (!src_tokens.empty() && src_tokens.back() != "</s>") {
      src_tokens.push_back("</s>");
    }

    std::lock_guard<std::mutex> lock(mu);
    const auto results = translator.translate_batch({src_tokens});
    if (results.empty()) return std::string();

    auto out_tokens = results[0].output();
    // Strip common special tokens.
    out_tokens.erase(
        std::remove_if(out_tokens.begin(), out_tokens.end(), [](const std::string& t) {
          return t == "</s>" || t == "<pad>";
        }),
        out_tokens.end());

    if (has_sentencepiece) {
      std::string decoded;
      sp_tgt.Decode(out_tokens, &decoded);
      return decoded;
    }
    return join_ws(out_tokens);
  }
};

}  // namespace

extern "C" {

OST_EXPORT int OST_CreateTranslator(
    const char* model_dir_utf8,
    void** out_handle,
    char* error_buf,
    int error_buf_len) {
  if (!out_handle) {
    write_error(error_buf, error_buf_len, "out_handle is null");
    return kError;
  }
  *out_handle = nullptr;

  try {
    if (!model_dir_utf8 || std::strlen(model_dir_utf8) == 0) {
      write_error(error_buf, error_buf_len, "model_dir is empty");
      return kError;
    }
    auto* wrapper = new TranslatorWrapper(std::string(model_dir_utf8));
    *out_handle = wrapper;
    return kOk;
  } catch (const std::exception& e) {
    write_error(error_buf, error_buf_len, e.what());
    return kError;
  } catch (...) {
    write_error(error_buf, error_buf_len, "Unknown error in OST_CreateTranslator");
    return kError;
  }
}

OST_EXPORT int OST_DestroyTranslator(void* handle) {
  try {
    auto* wrapper = reinterpret_cast<TranslatorWrapper*>(handle);
    delete wrapper;
    return kOk;
  } catch (...) {
    return kError;
  }
}

OST_EXPORT int OST_TranslateUtf8(
    void* handle,
    const char* input_utf8,
    char* out_buf,
    int out_buf_len,
    int* out_required_len,
    char* error_buf,
    int error_buf_len) {
  if (out_required_len) *out_required_len = 0;
  try {
    if (!handle) {
      write_error(error_buf, error_buf_len, "handle is null");
      return kError;
    }
    if (!input_utf8) {
      write_error(error_buf, error_buf_len, "input is null");
      return kError;
    }

    auto* wrapper = reinterpret_cast<TranslatorWrapper*>(handle);
    const std::string input(input_utf8);
    const std::string output = wrapper->translate_text(input);

    const int required = static_cast<int>(output.size());
    if (out_required_len) *out_required_len = required;

    if (!out_buf || out_buf_len <= 0) {
      return kOk;  // query mode
    }

    if (out_buf_len < required) {
      write_error(error_buf, error_buf_len, "output buffer too small");
      return kBufferTooSmall;
    }

    if (required > 0) {
      std::memcpy(out_buf, output.data(), required);
    }
    return kOk;
  } catch (const std::exception& e) {
    write_error(error_buf, error_buf_len, e.what());
    return kError;
  } catch (...) {
    write_error(error_buf, error_buf_len, "Unknown error in OST_TranslateUtf8");
    return kError;
  }
}

}  // extern "C"

