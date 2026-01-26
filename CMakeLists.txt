cmake_minimum_required(VERSION 3.20)
project(UniversalMultimediaStack)

include(ExternalProject)

set(CMAKE_OSX_DEPLOYMENT_TARGET "12.7.6" CACHE STRING "Minimum OS X deployment version" FORCE)

include(ProcessorCount)
ProcessorCount(PROCESSOR_COUNT)
if(NOT PROCESSOR_COUNT EQUAL 0)
    set(PROCESSOR_COUNT ${PROCESSOR_COUNT})
else()
    set(PROCESSOR_COUNT 4)
endif()

include(cmake/Utils.cmake)

include(cmake/BuildOpus.cmake)
include(cmake/BuildSDL3.cmake)
include(cmake/BuildVPX.cmake)
include(cmake/BuildAOM.cmake)

include(cmake/BuildFFmpeg.cmake)

include(cmake/BuildOpenscreen.cmake)

add_custom_target(universal_stack ALL
    DEPENDS libopus libsdl3 libvpx_lipo libaom_lipo ffmpeg_lipo openscreen_lipo
    COMMENT "All universal binaries built successfully in ${CMAKE_BINARY_DIR}/install"
)
