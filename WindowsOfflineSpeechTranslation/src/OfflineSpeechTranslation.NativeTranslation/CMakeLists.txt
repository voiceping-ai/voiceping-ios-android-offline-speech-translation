cmake_minimum_required(VERSION 3.21)

project(OfflineSpeechTranslationNativeTranslation LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# This project intentionally uses find_package to keep the repo lightweight.
# Build prerequisites (Windows):
# - Install/build CTranslate2 (CMake package: ctranslate2)
# - Install/build sentencepiece (CMake package: sentencepiece)
#
# Then build:
#   cmake -S . -B build -A x64 -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="C:\\path\\to\\installed\\packages"
#   cmake --build build --config Release

find_package(ctranslate2 CONFIG REQUIRED)
find_package(sentencepiece CONFIG REQUIRED)

add_library(OfflineSpeechTranslation.NativeTranslation SHARED native_translation.cpp)

target_link_libraries(OfflineSpeechTranslation.NativeTranslation
  PRIVATE
    CTranslate2::ctranslate2
    sentencepiece::sentencepiece
)

target_compile_definitions(OfflineSpeechTranslation.NativeTranslation PRIVATE NOMINMAX)

