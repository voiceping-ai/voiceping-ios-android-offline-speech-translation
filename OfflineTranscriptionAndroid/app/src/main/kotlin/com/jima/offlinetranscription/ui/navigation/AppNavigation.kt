package com.voiceping.offlinetranscription.ui.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.voiceping.offlinetranscription.data.AppDatabase
import com.voiceping.offlinetranscription.data.TranscriptionEntity
import com.voiceping.offlinetranscription.model.ModelState
import com.voiceping.offlinetranscription.service.WhisperEngine
import com.voiceping.offlinetranscription.ui.history.HistoryDetailScreen
import com.voiceping.offlinetranscription.ui.history.HistoryScreen
import com.voiceping.offlinetranscription.ui.history.HistoryViewModel
import com.voiceping.offlinetranscription.ui.setup.ModelSetupScreen
import com.voiceping.offlinetranscription.ui.setup.ModelSetupViewModel
import com.voiceping.offlinetranscription.ui.transcription.TranscriptionScreen
import com.voiceping.offlinetranscription.ui.transcription.TranscriptionViewModel
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.launch

object Routes {
    const val SETUP = "setup"
    const val MAIN = "main"
    const val TRANSCRIBE = "transcribe"
    const val HISTORY = "history"
    const val HISTORY_DETAIL = "history/{recordId}"
}

@Composable
fun AppNavigation(
    engine: WhisperEngine,
    database: AppDatabase
) {
    val modelState by engine.modelState.collectAsState()
    val navController = rememberNavController()

    val startDestination = if (modelState == ModelState.Loaded) Routes.MAIN else Routes.SETUP

    // Watch for model state changes to navigate
    LaunchedEffect(modelState) {
        if (modelState == ModelState.Loaded) {
            val currentRoute = navController.currentBackStackEntry?.destination?.route
            if (currentRoute == Routes.SETUP) {
                navController.navigate(Routes.MAIN) {
                    popUpTo(Routes.SETUP) { inclusive = true }
                }
            }
        }
    }

    NavHost(navController = navController, startDestination = startDestination) {
        composable(Routes.SETUP) {
            val viewModel = remember { ModelSetupViewModel(engine) }
            ModelSetupScreen(viewModel = viewModel)
        }

        composable(Routes.MAIN) {
            MainTabScreen(
                engine = engine,
                database = database,
                onChangeModel = {
                    engine.unloadModel()
                    engine.clearError()
                    navController.navigate(Routes.SETUP) {
                        popUpTo(Routes.MAIN) { inclusive = true }
                    }
                }
            )
        }

        composable(
            Routes.HISTORY_DETAIL,
            arguments = listOf(navArgument("recordId") { type = NavType.StringType })
        ) { backStackEntry ->
            val recordId = backStackEntry.arguments?.getString("recordId") ?: return@composable
            var record by remember { mutableStateOf<TranscriptionEntity?>(null) }
            LaunchedEffect(recordId) {
                record = database.transcriptionDao().getById(recordId)
            }
            record?.let {
                HistoryDetailScreen(record = it, onBack = { navController.popBackStack() })
            }
        }
    }
}

@Composable
fun MainTabScreen(
    engine: WhisperEngine,
    database: AppDatabase,
    onChangeModel: () -> Unit
) {
    var selectedTab by remember { mutableIntStateOf(0) }
    val tabs = listOf("Transcribe" to Icons.Filled.Mic, "History" to Icons.Filled.History)

    // Shared navigation for history detail
    val navController = rememberNavController()

    Scaffold(
        bottomBar = {
            NavigationBar {
                tabs.forEachIndexed { index, (title, icon) ->
                    NavigationBarItem(
                        icon = { Icon(icon, contentDescription = title) },
                        label = { Text(title) },
                        selected = selectedTab == index,
                        onClick = { selectedTab = index }
                    )
                }
            }
        }
    ) { paddingValues ->
        val context = LocalContext.current
        when (selectedTab) {
            0 -> {
                val viewModel = remember { TranscriptionViewModel(engine, database, context.filesDir) }
                Box(modifier = Modifier.padding(bottom = paddingValues.calculateBottomPadding())) {
                    TranscriptionScreen(viewModel = viewModel, onChangeModel = onChangeModel)
                }
            }
            1 -> {
                val viewModel = remember { HistoryViewModel(database, context.filesDir) }
                NavHost(
                    navController = navController,
                    startDestination = "history_list",
                    modifier = Modifier.padding(paddingValues)
                ) {
                    composable("history_list") {
                        HistoryScreen(
                            viewModel = viewModel,
                            onRecordClick = { id ->
                                navController.navigate("history_detail/$id")
                            }
                        )
                    }
                    composable(
                        "history_detail/{recordId}",
                        arguments = listOf(navArgument("recordId") { type = NavType.StringType })
                    ) { backStackEntry ->
                        val recordId = backStackEntry.arguments?.getString("recordId") ?: return@composable
                        var record by remember { mutableStateOf<TranscriptionEntity?>(null) }
                        LaunchedEffect(recordId) {
                            record = database.transcriptionDao().getById(recordId)
                        }
                        record?.let {
                            HistoryDetailScreen(record = it, onBack = { navController.popBackStack() })
                        }
                    }
                }
            }
        }
    }
}
