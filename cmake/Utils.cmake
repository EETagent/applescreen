function(add_split_arch_project)
    cmake_parse_arguments(ARG "" "NAME;GIT_REPOSITORY;GIT_TAG" "CONFIGURE_COMMAND_X86;CONFIGURE_COMMAND_ARM;BUILD_COMMAND;INSTALL_COMMAND;DEPENDS;BUILD_IN_SOURCE" ${ARGN})

    set(INSTALL_DIR_X86 "${CMAKE_BINARY_DIR}/install_x86")
    set(INSTALL_DIR_ARM "${CMAKE_BINARY_DIR}/install_arm")
    set(FINAL_INSTALL_DIR "${CMAKE_BINARY_DIR}/install")

    ExternalProject_Add(${ARG_NAME}_x86
        GIT_REPOSITORY ${ARG_GIT_REPOSITORY}
        GIT_TAG ${ARG_GIT_TAG}
        PREFIX ${ARG_NAME}_x86
        DEPENDS ${ARG_DEPENDS}
        CONFIGURE_COMMAND ${ARG_CONFIGURE_COMMAND_X86}
        BUILD_COMMAND ${ARG_BUILD_COMMAND}
        INSTALL_COMMAND ${ARG_INSTALL_COMMAND}
    )

    ExternalProject_Add(${ARG_NAME}_arm
        GIT_REPOSITORY ${ARG_GIT_REPOSITORY}
        GIT_TAG ${ARG_GIT_TAG}
        PREFIX ${ARG_NAME}_arm
        DEPENDS ${ARG_DEPENDS}
        CONFIGURE_COMMAND ${ARG_CONFIGURE_COMMAND_ARM}
        BUILD_COMMAND ${ARG_BUILD_COMMAND}
        INSTALL_COMMAND ${ARG_INSTALL_COMMAND}
    )

endfunction()

macro(create_lipo_target TARGET_NAME LIBS_TO_MERGE)
    # LIBS_TO_MERGE should be a list of filenames like "libvpx.a"
    
    set(LIPO_COMMANDS "")
    foreach(LIB ${LIBS_TO_MERGE})
        list(APPEND LIPO_COMMANDS 
            COMMAND lipo -create 
            "${CMAKE_BINARY_DIR}/install_x86/lib/${LIB}" 
            "${CMAKE_BINARY_DIR}/install_arm/lib/${LIB}" 
            -output "${CMAKE_BINARY_DIR}/install/lib/${LIB}"
        )
    endforeach()

    # Create a small script to handle pkg-config fixup to avoid shell escaping hell in add_custom_target
    set(PKG_CONFIG_SCRIPT "${CMAKE_BINARY_DIR}/fix_pkgconfig_${TARGET_NAME}.sh")
    file(WRITE "${PKG_CONFIG_SCRIPT}" 
"#!/bin/sh
mkdir -p \"${CMAKE_BINARY_DIR}/install/lib/pkgconfig\"
cp -r \"${CMAKE_BINARY_DIR}/install_x86/lib/pkgconfig/\"* \"${CMAKE_BINARY_DIR}/install/lib/pkgconfig/\" 2>/dev/null || true
for f in \"${CMAKE_BINARY_DIR}/install/lib/pkgconfig/\"*.pc; do
    [ -f \"$f\" ] || continue
    sed -i '' 's|${CMAKE_BINARY_DIR}/install_x86|${CMAKE_BINARY_DIR}/install|g' \"$f\"
done
"
    )

    add_custom_target(${TARGET_NAME}_lipo
        DEPENDS ${TARGET_NAME}_x86 ${TARGET_NAME}_arm
        COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_BINARY_DIR}/install/lib"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_BINARY_DIR}/install/include"
        # Merge libs
        ${LIPO_COMMANDS}
        # Copy headers from x86 (assuming identical)
        COMMAND ${CMAKE_COMMAND} -E copy_directory 
            "${CMAKE_BINARY_DIR}/install_x86/include" 
            "${CMAKE_BINARY_DIR}/install/include"
        # Run pkg-config fixup script
        COMMAND sh "${PKG_CONFIG_SCRIPT}"
        COMMENT "Merging universal binaries for ${TARGET_NAME}"
    )
endmacro()
