package com.voiceping.offlinetranscription.model

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ModelStateTest {

    @Test
    fun allStates_exist() {
        val states = ModelState.entries
        assertEquals(5, states.size)
    }

    @Test
    fun unloaded_exists() {
        val state = ModelState.valueOf("Unloaded")
        assertEquals(ModelState.Unloaded, state)
    }

    @Test
    fun downloading_exists() {
        val state = ModelState.valueOf("Downloading")
        assertEquals(ModelState.Downloading, state)
    }

    @Test
    fun downloaded_exists() {
        val state = ModelState.valueOf("Downloaded")
        assertEquals(ModelState.Downloaded, state)
    }

    @Test
    fun loading_exists() {
        val state = ModelState.valueOf("Loading")
        assertEquals(ModelState.Loading, state)
    }

    @Test
    fun loaded_exists() {
        val state = ModelState.valueOf("Loaded")
        assertEquals(ModelState.Loaded, state)
    }

    @Test
    fun entries_containsAllExpectedStates() {
        val expected = setOf(
            ModelState.Unloaded,
            ModelState.Downloading,
            ModelState.Downloaded,
            ModelState.Loading,
            ModelState.Loaded
        )
        assertEquals(expected, ModelState.entries.toSet())
    }

    @Test
    fun ordinal_valuesAreSequential() {
        assertEquals(0, ModelState.Unloaded.ordinal)
        assertEquals(1, ModelState.Downloading.ordinal)
        assertEquals(2, ModelState.Downloaded.ordinal)
        assertEquals(3, ModelState.Loading.ordinal)
        assertEquals(4, ModelState.Loaded.ordinal)
    }

    @Test
    fun name_returnsCorrectString() {
        assertEquals("Unloaded", ModelState.Unloaded.name)
        assertEquals("Downloading", ModelState.Downloading.name)
        assertEquals("Downloaded", ModelState.Downloaded.name)
        assertEquals("Loading", ModelState.Loading.name)
        assertEquals("Loaded", ModelState.Loaded.name)
    }
}
