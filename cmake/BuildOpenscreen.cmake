set(DOWNLOAD_SCRIPT "${CMAKE_BINARY_DIR}/download_openscreen.sh")
file(WRITE "${DOWNLOAD_SCRIPT}"
"#!/bin/sh
set -e
SOURCE_DIR=\"$1\"
PATCH_DIR=\"${CMAKE_SOURCE_DIR}/patches\"

mkdir -p \"$SOURCE_DIR\"
cd \"$SOURCE_DIR\"

echo 'solutions = [{\"name\": \"openscreen\", \"url\": \"https://chromium.googlesource.com/openscreen@1f070e8b01b063fd1dcc6827a9ea1b62301c3d1a\", \"deps_file\": \"DEPS\", \"managed\": False, \"custom_deps\": {}, \"custom_vars\": {}}]' > .gclient

echo \"Syncing Openscreen (this may take a while)...\"
gclient sync --no-history --shallow

cd openscreen
if [ -d "$PATCH_DIR" ]; then
    echo "Applying patches from $PATCH_DIR..."
    for patchfile in "$PATCH_DIR"/*_*.patch; do
        if [ -f "$patchfile" ]; then
            echo "Applying $patchfile..."
            if ! patch -p1 < "$patchfile"; then
                echo "Failed to apply $patchfile"
                exit 1
            fi
        fi
    done
fi
"
)

set(CONFIGURE_SCRIPT "${CMAKE_BINARY_DIR}/configure_openscreen.sh")
file(WRITE "${CONFIGURE_SCRIPT}"
"#!/bin/sh
set -e
SOURCE_DIR=\"$1\"
ARCH=\"$2\"
INSTALL_ROOT=\"$3\"
DEPLOYMENT_TARGET=\"$4\"

cd \"$SOURCE_DIR/openscreen\"

ARGS=\"target_os=\\\"mac\\\" \
target_cpu=\\\"$ARCH\\\" \
mac_deployment_target=\\\"$DEPLOYMENT_TARGET\\\" \
mac_min_system_version=\\\"$DEPLOYMENT_TARGET\\\" \
openscreen_static_library=true \
is_debug=false \
is_clang=true \
use_custom_libcxx=true \
treat_warnings_as_errors=false \
fatal_linker_warnings=false \
have_ffmpeg=true \
ffmpeg_include_dirs=[\\\"$INSTALL_ROOT/include\\\"] \
ffmpeg_lib_dirs=[\\\"$INSTALL_ROOT/lib\\\"] \
ffmpeg_libs=[\\\"avcodec\\\", \\\"avformat\\\", \\\"avutil\\\", \\\"swresample\\\"] \
have_libsdl3=true \
libsdl3_include_dirs=[\\\"$INSTALL_ROOT/include\\\"] \
have_libopus=true \
libopus_include_dirs=[\\\"$INSTALL_ROOT/include/opus\\\"] \
have_libvpx=true \
libvpx_include_dirs=[\\\"$INSTALL_ROOT/include\\\"] \
have_libaom=true \
libaom_include_dirs=[\\\"$INSTALL_ROOT/include\\\"]\"

echo \"Configuring Openscreen for $ARCH...\"
# echo \"Args: $ARGS\"
gn gen \"out/$ARCH\" --args=\"$ARGS\"
"
)

set(INSTALL_SCRIPT "${CMAKE_BINARY_DIR}/install_openscreen.sh")
file(WRITE "${INSTALL_SCRIPT}"
"#!/bin/sh
set -e
SRC_DIR=\"$1\"
INSTALL_DIR=\"$2\"
ARCH=\"$3\"

mkdir -p \"$INSTALL_DIR/lib\"
mkdir -p \"$INSTALL_DIR/include/openscreen\"
mkdir -p \"$INSTALL_DIR/bin\"

# Copy binaries (flatten structure)
if [ -f \"$SRC_DIR/openscreen/out/$ARCH/cast_receiver\" ]; then
    cp \"$SRC_DIR/openscreen/out/$ARCH/cast_receiver\" \"$INSTALL_DIR/bin/\"
fi
if [ -f \"$SRC_DIR/openscreen/out/$ARCH/cast_sender\" ]; then
    cp \"$SRC_DIR/openscreen/out/$ARCH/cast_sender\" \"$INSTALL_DIR/bin/\"
fi
if [ -f \"$SRC_DIR/openscreen/out/$ARCH/libcast_receiver_mylib.dylib\" ]; then
    cp \"$SRC_DIR/openscreen/out/$ARCH/libcast_receiver_mylib.dylib\" \"$INSTALL_DIR/lib/\"
fi
if [ -f \"$SRC_DIR/openscreen/out/$ARCH/libcast_sender_mylib.dylib\" ]; then
    cp \"$SRC_DIR/openscreen/out/$ARCH/libcast_sender_mylib.dylib\" \"$INSTALL_DIR/lib/\"
fi
"
)

set(MERGE_SCRIPT "${CMAKE_BINARY_DIR}/merge_openscreen.sh")
file(WRITE "${MERGE_SCRIPT}"
"#!/bin/sh
set -e
X86_LIB=\"${CMAKE_BINARY_DIR}/install_x86/lib\"
ARM_LIB=\"${CMAKE_BINARY_DIR}/install_arm/lib\"
X86_BIN=\"${CMAKE_BINARY_DIR}/install_x86/bin\"
ARM_BIN=\"${CMAKE_BINARY_DIR}/install_arm/bin\"
DEST_LIB=\"${CMAKE_BINARY_DIR}/install/lib\"
DEST_BIN=\"${CMAKE_BINARY_DIR}/install/bin\"

mkdir -p \"$DEST_LIB/x64\"
mkdir -p \"$DEST_LIB/arm64\"
mkdir -p \"$DEST_BIN/x64\"
mkdir -p \"$DEST_BIN/arm64\"

# TODO: Ten custom libcxx kazí merge přes lipo.., ale nevadí to mít oddělené

echo \"Copying x64 files...\"
cp -r \"$X86_LIB/\"* \"$DEST_LIB/x64/\"
cp -r \"$X86_BIN/\"* \"$DEST_BIN/x64/\"

echo \"Copying arm64 files...\"
cp -r \"$ARM_LIB/\"* \"$DEST_LIB/arm64/\"
cp -r \"$ARM_BIN/\"* \"$DEST_BIN/arm64/\"
"
)

ExternalProject_Add(openscreen_src
    PREFIX openscreen_src
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND ""
    DOWNLOAD_COMMAND sh "${DOWNLOAD_SCRIPT}" "<SOURCE_DIR>"
)

ExternalProject_Add(openscreen_x86
    DEPENDS openscreen_src ffmpeg_lipo
    SOURCE_DIR ${CMAKE_BINARY_DIR}/openscreen_src/src/openscreen_src
    PREFIX openscreen_x86
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND
        sh "${CONFIGURE_SCRIPT}" "<SOURCE_DIR>" "x64" "${CMAKE_BINARY_DIR}/install" "${CMAKE_OSX_DEPLOYMENT_TARGET}"
    BUILD_COMMAND
        ninja -C <SOURCE_DIR>/openscreen/out/x64 cast_receiver cast_sender cast_sender_mylib cast_receiver_mylib
    INSTALL_COMMAND
        sh "${INSTALL_SCRIPT}" "<SOURCE_DIR>" "${CMAKE_BINARY_DIR}/install_x86" "x64"
)

ExternalProject_Add(openscreen_arm
    DEPENDS openscreen_src ffmpeg_lipo
    SOURCE_DIR ${CMAKE_BINARY_DIR}/openscreen_src/src/openscreen_src
    PREFIX openscreen_arm
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND
        sh "${CONFIGURE_SCRIPT}" "<SOURCE_DIR>" "arm64" "${CMAKE_BINARY_DIR}/install" "${CMAKE_OSX_DEPLOYMENT_TARGET}"
    BUILD_COMMAND
        ninja -C <SOURCE_DIR>/openscreen/out/arm64 cast_receiver cast_sender cast_sender_mylib cast_receiver_mylib
    INSTALL_COMMAND
        sh "${INSTALL_SCRIPT}" "<SOURCE_DIR>" "${CMAKE_BINARY_DIR}/install_arm" "arm64"
)

add_custom_target(openscreen_lipo
    DEPENDS openscreen_x86 openscreen_arm
    COMMAND sh "${MERGE_SCRIPT}"
    COMMENT "Merging universal binaries for Openscreen"
)
