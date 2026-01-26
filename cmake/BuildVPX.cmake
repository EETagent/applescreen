add_split_arch_project(
    NAME libvpx
    GIT_REPOSITORY https://chromium.googlesource.com/webm/libvpx
    GIT_TAG v1.15.2
    GIT_SHALLOW ON

    CONFIGURE_COMMAND_X86
        <SOURCE_DIR>/configure
        --prefix=${CMAKE_BINARY_DIR}/install_x86
        --target=x86_64-darwin20-gcc
        "--extra-cflags=-mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}"
        --disable-examples
        --disable-unit-tests
        --enable-pic
        --enable-vp9-highbitdepth
        --as=yasm

    CONFIGURE_COMMAND_ARM
        <SOURCE_DIR>/configure
        --prefix=${CMAKE_BINARY_DIR}/install_arm
        --target=arm64-darwin20-gcc
        "--extra-cflags=-mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}"
        --disable-examples
        --disable-unit-tests
        --enable-pic
        --enable-vp9-highbitdepth
        --as=yasm

    BUILD_COMMAND make -j${PROCESSOR_COUNT}
    INSTALL_COMMAND make install
)

create_lipo_target(libvpx "libvpx.a")
