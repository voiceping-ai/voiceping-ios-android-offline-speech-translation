package com.voiceping.offlinetranscription.data

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
import java.util.UUID

@Entity(tableName = "transcriptions")
data class TranscriptionEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val text: String,
    val createdAt: Long = System.currentTimeMillis(),
    val durationSeconds: Double,
    val modelUsed: String,
    val language: String? = null,
    @ColumnInfo(defaultValue = "NULL") val audioFileName: String? = null
)
