set(FFMPEG_LIBS "libavcodec.a" "libavformat.a" "libavutil.a" "libswresample.a")

set(COMMON_FFMPEG_FLAGS
    --disable-autodetect
    --disable-doc
    --disable-programs
    --disable-network
    --disable-securetransport
    --disable-sdl2
    --disable-xlib
    --enable-videotoolbox
    --enable-avcodec
    --enable-avformat
    --enable-avutil
    --enable-swresample
    --enable-libopus
    --enable-libvpx
    --enable-libaom
    --enable-gpl
    --enable-cross-compile
    --pkg-config-flags=--static
    "--extra-cflags=-I${CMAKE_BINARY_DIR}/install/include -mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}"
    "--extra-ldflags=-L${CMAKE_BINARY_DIR}/install/lib"
)

add_split_arch_project(
    NAME ffmpeg
    GIT_REPOSITORY https://git.ffmpeg.org/ffmpeg.git
    GIT_TAG n8.0.1
    GIT_SHALLOW ON

    DEPENDS libopus libvpx_lipo libaom_lipo

    CONFIGURE_COMMAND_X86
        env PKG_CONFIG_PATH=${CMAKE_BINARY_DIR}/install_x86/lib/pkgconfig:${CMAKE_BINARY_DIR}/install/lib/pkgconfig
        <SOURCE_DIR>/configure
        --prefix=${CMAKE_BINARY_DIR}/install_x86
        --arch=x86_64
        "--cc=clang -arch x86_64"
        ${COMMON_FFMPEG_FLAGS}

    CONFIGURE_COMMAND_ARM
        env PKG_CONFIG_PATH=${CMAKE_BINARY_DIR}/install_arm/lib/pkgconfig:${CMAKE_BINARY_DIR}/install/lib/pkgconfig
        <SOURCE_DIR>/configure
        --prefix=${CMAKE_BINARY_DIR}/install_arm
        --arch=aarch64
        "--cc=clang -arch arm64"
        ${COMMON_FFMPEG_FLAGS}

    BUILD_COMMAND make -j${PROCESSOR_COUNT}
    INSTALL_COMMAND make install
)

create_lipo_target(ffmpeg "${FFMPEG_LIBS}")
