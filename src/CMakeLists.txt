cmake_minimum_required(VERSION 3.20)

enable_language(OBJC OBJCXX)

set(CMAKE_OSX_ARCHITECTURES "x86_64;arm64")

set(APP_SOURCES
    AppDelegate.m
    AudioRingBuffer.m
    main.m
    MetalVideoView.m
    ReceiverViewController.m
    SenderViewController.m
    VideoWindowController.m

    AppDelegate.h
    AudioRingBuffer.h
    MetalVideoView.h
    ReceiverViewController.h
    SenderViewController.h
    VideoWindowController.h
)

add_executable(Applescreen ${APP_SOURCES})

set_target_properties(Applescreen PROPERTIES
    OBJC_ARC ON
    OBJCXX_ARC ON
)

target_link_libraries(Applescreen PRIVATE
    "-framework Cocoa"
    "-framework Metal"
    "-framework CoreVideo"
    "-framework AudioToolbox"
    "-framework CoreAudio"
    "-framework QuartzCore"
    "-framework Accelerate"
    "-framework ScreenCaptureKit"
    "-framework UniformTypeIdentifiers"
    "-framework CoreMedia"
)

target_link_libraries(Applescreen PRIVATE
    cast_receiver_mylib
    cast_sender_mylib
)

target_link_options(Applescreen PRIVATE
    "SHELL:-Xarch_x86_64 -L${CMAKE_BINARY_DIR}/install/lib/x64"
    "SHELL:-Xarch_arm64 -L${CMAKE_BINARY_DIR}/install/lib/arm64"
)

target_compile_options(Applescreen PRIVATE
    "-fobjc-arc"
    "SHELL:-Xarch_x86_64 -I${CMAKE_BINARY_DIR}/install_x86/include"
    "SHELL:-Xarch_arm64 -I${CMAKE_BINARY_DIR}/install_arm/include"
)

target_include_directories(Applescreen PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_BINARY_DIR}/install/include
)

#add_dependencies(Applescreen openscreen_lipo)

install(TARGETS Applescreen DESTINATION bin)
