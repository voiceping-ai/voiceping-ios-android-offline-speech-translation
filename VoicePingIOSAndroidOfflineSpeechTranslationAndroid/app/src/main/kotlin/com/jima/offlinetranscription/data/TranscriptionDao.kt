package com.voiceping.offlinetranscription.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Delete
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface TranscriptionDao {
    @Query("SELECT * FROM transcriptions ORDER BY createdAt DESC")
    fun getAll(): Flow<List<TranscriptionEntity>>

    @Query("SELECT * FROM transcriptions WHERE id = :id")
    suspend fun getById(id: String): TranscriptionEntity?

    @Insert
    suspend fun insert(transcription: TranscriptionEntity)

    @Delete
    suspend fun delete(transcription: TranscriptionEntity)
}
