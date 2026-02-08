package com.voiceping.offlinetranscription.ui.setup

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.voiceping.offlinetranscription.model.ModelInfo
import com.voiceping.offlinetranscription.service.WhisperEngine
import kotlinx.coroutines.launch

class ModelSetupViewModel(val engine: WhisperEngine) : ViewModel() {

    val modelState = engine.modelState
    val downloadProgress = engine.downloadProgress
    val selectedModel = engine.selectedModel
    val lastError = engine.lastError

    fun selectAndSetup(model: ModelInfo) {
        engine.setSelectedModel(model)
        engine.launchSetup()
    }

    fun isModelDownloaded(model: ModelInfo): Boolean = engine.isModelDownloaded(model)
}
