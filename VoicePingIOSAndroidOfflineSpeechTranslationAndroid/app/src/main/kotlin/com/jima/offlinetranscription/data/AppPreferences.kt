package com.voiceping.offlinetranscription.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.dataStore by preferencesDataStore(name = "app_preferences")

class AppPreferences(private val context: Context) {

    companion object {
        private val SELECTED_MODEL_ID = stringPreferencesKey("selected_model_id")
        private val LAST_MODEL_PATH = stringPreferencesKey("last_model_path")
        private val USE_VAD = booleanPreferencesKey("use_vad")
        private val ENABLE_TIMESTAMPS = booleanPreferencesKey("enable_timestamps")
        private val TRANSLATION_ENABLED = booleanPreferencesKey("translation_enabled")
        private val SPEAK_TRANSLATED_AUDIO = booleanPreferencesKey("speak_translated_audio")
        private val TRANSLATION_SOURCE_LANGUAGE = stringPreferencesKey("translation_source_language")
        private val TRANSLATION_TARGET_LANGUAGE = stringPreferencesKey("translation_target_language")
        private val TTS_RATE = stringPreferencesKey("tts_rate")
        private val TRANSLATION_PROVIDER = stringPreferencesKey("translation_provider")
    }

    val selectedModelId: Flow<String?> = context.dataStore.data.map { it[SELECTED_MODEL_ID] }
    val lastModelPath: Flow<String?> = context.dataStore.data.map { it[LAST_MODEL_PATH] }
    val useVAD: Flow<Boolean> = context.dataStore.data.map { it[USE_VAD] ?: true }
    val enableTimestamps: Flow<Boolean> = context.dataStore.data.map { it[ENABLE_TIMESTAMPS] ?: true }
    val translationEnabled: Flow<Boolean> = context.dataStore.data.map { it[TRANSLATION_ENABLED] ?: true }
    val speakTranslatedAudio: Flow<Boolean> = context.dataStore.data.map { it[SPEAK_TRANSLATED_AUDIO] ?: true }
    val translationSourceLanguage: Flow<String> = context.dataStore.data.map { it[TRANSLATION_SOURCE_LANGUAGE] ?: "en" }
    val translationTargetLanguage: Flow<String> = context.dataStore.data.map { it[TRANSLATION_TARGET_LANGUAGE] ?: "ja" }
    val ttsRate: Flow<Float> = context.dataStore.data.map { prefs ->
        prefs[TTS_RATE]?.toFloatOrNull() ?: 1.0f
    }
    val translationProvider: Flow<String> = context.dataStore.data.map { it[TRANSLATION_PROVIDER] ?: "ML_KIT" }

    suspend fun setSelectedModelId(id: String) {
        context.dataStore.edit { it[SELECTED_MODEL_ID] = id }
    }

    suspend fun setLastModelPath(path: String) {
        context.dataStore.edit { it[LAST_MODEL_PATH] = path }
    }

    suspend fun setUseVAD(enabled: Boolean) {
        context.dataStore.edit { it[USE_VAD] = enabled }
    }

    suspend fun setEnableTimestamps(enabled: Boolean) {
        context.dataStore.edit { it[ENABLE_TIMESTAMPS] = enabled }
    }

    suspend fun setTranslationEnabled(enabled: Boolean) {
        context.dataStore.edit { it[TRANSLATION_ENABLED] = enabled }
    }

    suspend fun setSpeakTranslatedAudio(enabled: Boolean) {
        context.dataStore.edit { it[SPEAK_TRANSLATED_AUDIO] = enabled }
    }

    suspend fun setTranslationSourceLanguage(languageCode: String) {
        context.dataStore.edit { it[TRANSLATION_SOURCE_LANGUAGE] = languageCode }
    }

    suspend fun setTranslationTargetLanguage(languageCode: String) {
        context.dataStore.edit { it[TRANSLATION_TARGET_LANGUAGE] = languageCode }
    }

    suspend fun setTtsRate(rate: Float) {
        context.dataStore.edit { it[TTS_RATE] = rate.toString() }
    }

    suspend fun setTranslationProvider(provider: String) {
        context.dataStore.edit { it[TRANSLATION_PROVIDER] = provider }
    }
}
