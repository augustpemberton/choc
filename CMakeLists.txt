
add_library(choc STATIC)

if (APPLE)
    target_sources(choc PRIVATE src/im_MacOS_Webview.mm)
elseif(WIN32)
    target_sources(choc PRIVATE src/im_Win_Webview.cpp)
endif()

target_include_directories(choc PUBLIC
        "include"
)
