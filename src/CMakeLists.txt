add_executable(Applescreen MACOSX_BUNDLE
    AppDelegate.m FormRows.m main.m ReceiverViewController.m SenderViewController.m
    VideoWindowController.m media/FileSource.m media/ScreenSource.m)
target_compile_options(Applescreen PRIVATE -fobjc-arc)
target_include_directories(Applescreen PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(Applescreen PRIVATE ApplescreenCast
    "-framework Cocoa" "-framework AVFoundation" "-framework CoreMedia"
    "-framework CoreVideo" "-framework CoreGraphics" "-framework AudioToolbox" "-framework QuartzCore"
    "-framework ScreenCaptureKit" "-framework UniformTypeIdentifiers")
set_target_properties(Applescreen PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_BUNDLE_GUI_IDENTIFIER "org.applescreen.Applescreen"
    MACOSX_BUNDLE_BUNDLE_NAME Applescreen
    MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "@executable_path/../Frameworks")
set(APPLESCREEN_CODESIGN_IDENTITY "-" CACHE STRING "Apple-issued signing identity, or - for local ad-hoc signing")
add_custom_command(TARGET Applescreen POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_BUNDLE_DIR:Applescreen>/Contents/Frameworks"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${APPLESCREEN_CORE_LIBRARY}" "$<TARGET_BUNDLE_DIR:Applescreen>/Contents/Frameworks/libapplescreen_cast.dylib"
    COMMAND codesign --force --sign "${APPLESCREEN_CODESIGN_IDENTITY}" "$<TARGET_BUNDLE_DIR:Applescreen>/Contents/Frameworks/libapplescreen_cast.dylib"
    COMMAND codesign --force --sign "${APPLESCREEN_CODESIGN_IDENTITY}" "$<TARGET_BUNDLE_DIR:Applescreen>"
    VERBATIM)
install(TARGETS Applescreen BUNDLE DESTINATION .)
