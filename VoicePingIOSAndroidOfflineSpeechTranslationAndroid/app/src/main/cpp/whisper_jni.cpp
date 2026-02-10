#include <jni.h>
#include <android/log.h>
#include <string>
#include <vector>
#include "whisper.h"

#define TAG "WhisperJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_jima_offlinetranscription_service_WhisperLib_initContext(
        JNIEnv *env, jobject /* this */, jstring model_path) {
    const char *path = env->GetStringUTFChars(model_path, nullptr);
    LOGI("Loading model from: %s", path);

    struct whisper_context_params cparams = whisper_context_default_params();
    struct whisper_context *ctx = whisper_init_from_file_with_params(path, cparams);

    env->ReleaseStringUTFChars(model_path, path);

    if (ctx == nullptr) {
        LOGE("Failed to initialize whisper context");
        return 0;
    }

    LOGI("Model loaded successfully");
    return reinterpret_cast<jlong>(ctx);
}

JNIEXPORT jint JNICALL
Java_com_jima_offlinetranscription_service_WhisperLib_transcribe(
        JNIEnv *env, jobject /* this */,
        jlong context_ptr, jfloatArray audio_data,
        jint num_threads, jboolean translate, jstring language) {

    auto *ctx = reinterpret_cast<struct whisper_context *>(context_ptr);
    if (ctx == nullptr) {
        LOGE("Context is null");
        return -1;
    }

    jfloat *audio = env->GetFloatArrayElements(audio_data, nullptr);
    jsize audio_len = env->GetArrayLength(audio_data);

    const char *lang = env->GetStringUTFChars(language, nullptr);

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = num_threads;
    params.translate = translate;
    params.language = lang;
    params.no_timestamps = false;
    params.print_realtime = false;
    params.print_progress = false;
    params.print_special = false;
    params.print_timestamps = false;

    int result = whisper_full(ctx, params, audio, audio_len);

    env->ReleaseFloatArrayElements(audio_data, audio, JNI_ABORT);
    env->ReleaseStringUTFChars(language, lang);

    if (result != 0) {
        LOGE("whisper_full failed with code: %d", result);
    }

    return result;
}

JNIEXPORT jint JNICALL
Java_com_jima_offlinetranscription_service_WhisperLib_getSegmentCount(
        JNIEnv *env, jobject /* this */, jlong context_ptr) {
    auto *ctx = reinterpret_cast<struct whisper_context *>(context_ptr);
    if (ctx == nullptr) return 0;
    return whisper_full_n_segments(ctx);
}

JNIEXPORT jstring JNICALL
Java_com_jima_offlinetranscription_service_WhisperLib_getSegmentText(
        JNIEnv *env, jobject /* this */, jlong context_ptr, jint index) {
    auto *ctx = reinterpret_cast<struct whisper_context *>(context_ptr);
    if (ctx == nullptr) return env->NewStringUTF("");

    const char *text = whisper_full_get_segment_text(ctx, index);
    return env->NewStringUTF(text);
}

JNIEXPORT jlong JNICALL
Java_com_jima_offlinetranscription_service_WhisperLib_getSegmentStartTime(
        JNIEnv *env, jobject /* this */, jlong context_ptr, jint index) {
    auto *ctx = reinterpret_cast<struct whisper_context *>(context_ptr);
    if (ctx == nullptr) return 0;
    return whisper_full_get_segment_t0(ctx, index);
}

JNIEXPORT jlong JNICALL
Java_com_jima_offlinetranscription_service_WhisperLib_getSegmentEndTime(
        JNIEnv *env, jobject /* this */, jlong context_ptr, jint index) {
    auto *ctx = reinterpret_cast<struct whisper_context *>(context_ptr);
    if (ctx == nullptr) return 0;
    return whisper_full_get_segment_t1(ctx, index);
}

JNIEXPORT void JNICALL
Java_com_jima_offlinetranscription_service_WhisperLib_freeContext(
        JNIEnv *env, jobject /* this */, jlong context_ptr) {
    auto *ctx = reinterpret_cast<struct whisper_context *>(context_ptr);
    if (ctx != nullptr) {
        whisper_free(ctx);
        LOGI("Context freed");
    }
}

} // extern "C"
