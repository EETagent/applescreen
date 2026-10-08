# All state below lives under an isolated solution/cache. The sibling checkout
# and a parent's .gclient are never inputs to a mutation.
set(APPLESCREEN_DEPENDENCY_ROOT "${CMAKE_BINARY_DIR}/dependencies" CACHE PATH "Isolated dependency workspace")
set(APPLESCREEN_DEPOT_TOOLS "" CACHE PATH "Existing depot_tools directory containing gclient")
set(APPLESCREEN_PRISTINE "${APPLESCREEN_DEPENDENCY_ROOT}/pristine" CACHE PATH "Pristine Open Screen solution")
set(APPLESCREEN_INTEGRATION "${APPLESCREEN_DEPENDENCY_ROOT}/integration" CACHE PATH "Disposable Open Screen integration solution")
set(APPLESCREEN_CODEC_ROOT "${APPLESCREEN_DEPENDENCY_ROOT}/codecs" CACHE PATH "Per-dependency codec build cache")
option(APPLESCREEN_AV1_SENDER "Enable optional AV1 sender encoder" OFF)
if(NOT EXISTS "${APPLESCREEN_DEPOT_TOOLS}/gclient")
    find_program(_gclient NAMES gclient)
    if(_gclient)
        get_filename_component(APPLESCREEN_DEPOT_TOOLS "${_gclient}" DIRECTORY)
    else()
        message(FATAL_ERROR "Set APPLESCREEN_DEPOT_TOOLS to depot_tools; it will not be updated")
    endif()
endif()
set(_scripts "${PROJECT_SOURCE_DIR}/scripts")
add_custom_target(openscreen_prepare
    COMMAND "${Python3_EXECUTABLE}" "${_scripts}/prepare_openscreen.py" sync
        --workspace "${APPLESCREEN_PRISTINE}" --depot-tools "${APPLESCREEN_DEPOT_TOOLS}"
    COMMAND "${Python3_EXECUTABLE}" "${_scripts}/prepare_openscreen.py" integrate
        --workspace "${APPLESCREEN_INTEGRATION}" --pristine "${APPLESCREEN_PRISTINE}"
        --depot-tools "${APPLESCREEN_DEPOT_TOOLS}"
    VERBATIM USES_TERMINAL)
set(_core_slices)
set(_core_targets)
set(_av1_option)
if(APPLESCREEN_AV1_SENDER)
    set(_av1_option --av1-sender)
endif()
foreach(_arch IN LISTS CMAKE_OSX_ARCHITECTURES)
    if(NOT _arch MATCHES "^(arm64|x86_64)$")
        message(FATAL_ERROR "Unsupported architecture: ${_arch}")
    endif()
    set(_codec_base "${APPLESCREEN_CODEC_ROOT}/${_arch}/${CMAKE_BUILD_TYPE}")
    set(_core "${CMAKE_BINARY_DIR}/core/${_arch}/libapplescreen_cast.dylib")
    add_custom_target(codecs_${_arch}
        COMMAND "${Python3_EXECUTABLE}" "${_scripts}/build_codecs.py"
            --workspace "${APPLESCREEN_CODEC_ROOT}" --openscreen "${APPLESCREEN_PRISTINE}/openscreen"
            --arch "${_arch}" --configuration "${CMAKE_BUILD_TYPE}" ${_av1_option}
        BYPRODUCTS "${_codec_base}/codecs.json"
            "${_codec_base}/current/ffmpeg/lib/libavutil.a"
            "${_codec_base}/current/ffmpeg/lib/libswscale.a"
            "${_codec_base}/current/ffmpeg/lib/libswresample.a"
        DEPENDS openscreen_prepare VERBATIM USES_TERMINAL)
    add_custom_target(cast_core_${_arch}
        COMMAND "${Python3_EXECUTABLE}" "${_scripts}/build_core.py"
            --integration "${APPLESCREEN_INTEGRATION}" --codecs "${_codec_base}/codecs.json"
            --output "${CMAKE_BINARY_DIR}/gn/${_arch}" --install "${CMAKE_BINARY_DIR}/core/${_arch}" ${_av1_option}
        BYPRODUCTS "${_core}"
        DEPENDS codecs_${_arch} VERBATIM USES_TERMINAL)
    list(APPEND _core_slices "${_core}")
    list(APPEND _core_targets cast_core_${_arch})
endforeach()
list(LENGTH _core_slices _slice_count)
if(_slice_count GREATER 1)
    set(APPLESCREEN_CORE_LIBRARY "${CMAKE_BINARY_DIR}/core/universal/libapplescreen_cast.dylib")
    add_custom_command(OUTPUT "${APPLESCREEN_CORE_LIBRARY}"
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_BINARY_DIR}/core/universal"
        COMMAND xcrun lipo -create ${_core_slices} -output "${APPLESCREEN_CORE_LIBRARY}"
        COMMAND xcrun lipo "${APPLESCREEN_CORE_LIBRARY}" -verify_arch arm64
        COMMAND xcrun lipo "${APPLESCREEN_CORE_LIBRARY}" -verify_arch x86_64
        DEPENDS ${_core_slices} ${_core_targets} VERBATIM)
    add_custom_target(cast_core_build DEPENDS "${APPLESCREEN_CORE_LIBRARY}")
else()
    list(GET _core_slices 0 APPLESCREEN_CORE_LIBRARY)
    add_custom_target(cast_core_build DEPENDS ${_core_targets})
endif()
add_library(ApplescreenCast SHARED IMPORTED GLOBAL)
set_target_properties(ApplescreenCast PROPERTIES
    IMPORTED_LOCATION "${APPLESCREEN_CORE_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${PROJECT_SOURCE_DIR}/native")
add_dependencies(ApplescreenCast cast_core_build)
