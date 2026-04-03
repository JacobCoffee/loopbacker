cmake_minimum_required(VERSION 3.20)
project(Loopbacker VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Always build for the native architecture. Without this, an x86_64 cmake
# running under Rosetta will produce an x86_64 binary that coreaudiod's
# arm64e XPC helper cannot load.
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Target architecture" FORCE)

add_library(Loopbacker MODULE
    src/PluginEntry.cpp
    src/LoopbackerDriver.cpp
)

target_include_directories(Loopbacker PRIVATE src)

find_library(COREAUDIO_FRAMEWORK CoreAudio REQUIRED)
find_library(COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)

target_link_libraries(Loopbacker PRIVATE
    ${COREAUDIO_FRAMEWORK}
    ${COREFOUNDATION_FRAMEWORK}
)

set_target_properties(Loopbacker PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION "driver"
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
    PREFIX ""
    SUFFIX ""
)

# Ad-hoc code sign the driver bundle so coreaudiod will load it.
# Without a valid signature the HAL refuses to dlopen the binary.
add_custom_command(TARGET Loopbacker POST_BUILD
    COMMAND codesign --force --sign - "$<TARGET_BUNDLE_DIR:Loopbacker>"
    COMMENT "Ad-hoc signing Loopbacker.driver"
)
