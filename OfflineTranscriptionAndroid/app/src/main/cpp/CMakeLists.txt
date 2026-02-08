cmake_minimum_required(VERSION 3.22.1)
project(whisper_jni)

set(WHISPER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../whisper.cpp)

# Build whisper.cpp as a library
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)

add_subdirectory(${WHISPER_DIR} ${CMAKE_CURRENT_BINARY_DIR}/whisper.cpp)

# Build JNI bridge
add_library(whisper_jni SHARED whisper_jni.cpp)

target_include_directories(whisper_jni PRIVATE
    ${WHISPER_DIR}/include
    ${WHISPER_DIR}/ggml/include
)

target_link_libraries(whisper_jni
    whisper
    log
)
