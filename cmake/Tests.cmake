# These adapters use C/CF or their own C++ implementation. Open Screen C++ test
# targets remain in GN, with the pinned compiler and standard library.
function(applescreen_native_test name)
    add_executable(${name} ${ARGN})
    target_compile_options(${name} PRIVATE -fobjc-arc -UNDEBUG -Wall -Wextra -Wunguarded-availability-new)
    target_include_directories(${name} PRIVATE "${PROJECT_SOURCE_DIR}/src" "${PROJECT_SOURCE_DIR}/native")
    target_link_libraries(${name} PRIVATE "-framework Foundation" "-framework AVFoundation"
        "-framework CoreMedia" "-framework CoreVideo" "-framework CoreGraphics" "-framework AudioToolbox" "-framework QuartzCore")
    add_test(NAME ${name} COMMAND ${name})
    set_tests_properties(${name} PROPERTIES TIMEOUT 30)
endfunction()
applescreen_native_test(bonjour_test tests/bonjour_test.mm native/discovery/CastBonjour.mm)
applescreen_native_test(native_playback_test tests/native_playback_test.mm native/media/PlaybackSession.mm)
applescreen_native_test(file_source_test tests/file_source_test.m src/media/FileSource.m src/media/ScreenSource.m)
target_link_libraries(file_source_test PRIVATE "-framework ScreenCaptureKit")
applescreen_native_test(decoded_media_test tests/decoded_media_test.mm native/media/DecodedMedia.mm)
# Fixtures run on the host architecture even in an explicit universal package build.
list(FIND CMAKE_OSX_ARCHITECTURES "${CMAKE_HOST_SYSTEM_PROCESSOR}" _host_index)
if(_host_index EQUAL -1)
    list(GET CMAKE_OSX_ARCHITECTURES 0 _test_arch)
else()
    set(_test_arch "${CMAKE_HOST_SYSTEM_PROCESSOR}")
endif()
set_target_properties(decoded_media_test PROPERTIES OSX_ARCHITECTURES "${_test_arch}")
set(_test_ffmpeg "${APPLESCREEN_CODEC_ROOT}/${_test_arch}/${CMAKE_BUILD_TYPE}/current/ffmpeg")
target_include_directories(decoded_media_test PRIVATE "${_test_ffmpeg}/include")
target_link_libraries(decoded_media_test PRIVATE
    "${_test_ffmpeg}/lib/libswscale.a" "${_test_ffmpeg}/lib/libswresample.a" "${_test_ffmpeg}/lib/libavutil.a"
    "-framework VideoToolbox" "-framework CoreServices")
add_dependencies(decoded_media_test codecs_${_test_arch})
add_test(NAME dependency_preparation
    COMMAND "${Python3_EXECUTABLE}" -m unittest discover -s "${PROJECT_SOURCE_DIR}/tests" -p test_prepare_openscreen.py)
set_tests_properties(dependency_preparation PROPERTIES TIMEOUT 60 LABELS portable)
set_tests_properties(bonjour_test PROPERTIES LABELS native)
set_tests_properties(native_playback_test file_source_test decoded_media_test PROPERTIES LABELS native)
add_custom_target(applescreen_tests DEPENDS bonjour_test native_playback_test file_source_test decoded_media_test)
if(EXISTS "${PROJECT_SOURCE_DIR}/tests/runtime_session_test.mm")
    applescreen_native_test(runtime_session_test tests/runtime_session_test.mm)
    target_link_libraries(runtime_session_test PRIVATE ApplescreenCast)
    add_dependencies(applescreen_tests runtime_session_test)
endif()
# Explicit separate-process integration fixture; requires selected local
# credentials and a receiver peer, so it is not an unconditional CTest entry.
add_executable(cast_native_smoke tests/cast_native_smoke.m src/media/FileSource.m src/media/ScreenSource.m
    src/FormRows.m src/VideoWindowController.m)
target_compile_options(cast_native_smoke PRIVATE -fobjc-arc -UNDEBUG -Wall -Wextra)
target_include_directories(cast_native_smoke PRIVATE "${PROJECT_SOURCE_DIR}/src")
target_link_libraries(cast_native_smoke PRIVATE ApplescreenCast "-framework Cocoa"
    "-framework AVFoundation" "-framework CoreMedia" "-framework CoreVideo"
    "-framework CoreGraphics" "-framework QuartzCore" "-framework UniformTypeIdentifiers" "-framework ScreenCaptureKit")
add_dependencies(applescreen_tests cast_native_smoke)
# Protocol adapters are C++ inside the GN toolchain; do not link their headers
# into a CMake/system-libc++ test executable.
add_custom_target(cast_protocol_tests
    COMMAND "${APPLESCREEN_INTEGRATION}/openscreen/third_party/ninja/ninja"
        -C "${CMAKE_BINARY_DIR}/gn/${_test_arch}" sender_session_test receiver_session_test media_timeline_test
    BYPRODUCTS "${CMAKE_BINARY_DIR}/gn/${_test_arch}/sender_session_test"
        "${CMAKE_BINARY_DIR}/gn/${_test_arch}/receiver_session_test"
        "${CMAKE_BINARY_DIR}/gn/${_test_arch}/media_timeline_test"
    DEPENDS cast_core_${_test_arch} VERBATIM USES_TERMINAL)
add_dependencies(applescreen_tests cast_protocol_tests)
foreach(_test sender_session_test receiver_session_test media_timeline_test)
    add_test(NAME ${_test} COMMAND "${CMAKE_BINARY_DIR}/gn/${_test_arch}/${_test}")
    set_tests_properties(${_test} PROPERTIES TIMEOUT 30 LABELS native)
endforeach()
set_tests_properties(media_timeline_test PROPERTIES LABELS portable)
add_executable(runtime_loopback_test tests/runtime_loopback_test.mm src/media/FileSource.m)
target_compile_options(runtime_loopback_test PRIVATE -fobjc-arc -UNDEBUG -Wall -Wextra)
target_include_directories(runtime_loopback_test PRIVATE "${PROJECT_SOURCE_DIR}/src")
target_link_libraries(runtime_loopback_test PRIVATE ApplescreenCast "-framework Foundation"
    "-framework AVFoundation" "-framework CoreMedia" "-framework CoreVideo" "-framework CoreGraphics")
add_dependencies(applescreen_tests runtime_loopback_test)
# The imported GN dylib advertises @rpath. Tests run outside the app bundle, so
# their build rpath must name the architecture/universal core install directory.
foreach(_test runtime_session_test runtime_loopback_test cast_native_smoke)
    set_target_properties(${_test} PROPERTIES BUILD_RPATH "$<TARGET_FILE_DIR:ApplescreenCast>")
endforeach()
