package com.voiceping.offlinetranscription.ui.history

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.voiceping.offlinetranscription.data.AppDatabase
import com.voiceping.offlinetranscription.data.TranscriptionEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.File

class HistoryViewModel(
    private val database: AppDatabase,
    private val filesDir: File
) : ViewModel() {

    val records: StateFlow<List<TranscriptionEntity>> = database.transcriptionDao()
        .getAll()
        .stateIn(viewModelScope, SharingStarted.Lazily, emptyList())

    fun deleteRecord(record: TranscriptionEntity) {
        viewModelScope.launch {
            // Delete audio session directory
            record.audioFileName?.let { relPath ->
                val audioFile = File(filesDir, relPath)
                val sessionDir = audioFile.parentFile
                if (sessionDir != null && sessionDir.exists()) {
                    launch(Dispatchers.IO) { sessionDir.deleteRecursively() }
                }
            }
            database.transcriptionDao().delete(record)
        }
    }
}
