{
  "targets": [
    {
      "target_name": "mac_recorder_electron",
      "sources": [
        "src/electron_safe/mac_recorder_electron.mm",
        "src/electron_safe/screen_capture_electron.mm",
        "src/electron_safe/audio_capture_electron.mm",
        "src/electron_safe/cursor_tracker_electron.mm",
        "src/electron_safe/window_selector_electron.mm"
      ],
      "include_dirs": [
        "<!@(node -p \"require('node-addon-api').include\")"
      ],
      "dependencies": [
        "<!(node -p \"require('node-addon-api').gyp\")"
      ],
      "cflags!": [ "-fno-exceptions" ],
      "cflags_cc!": [ "-fno-exceptions" ],
      "xcode_settings": {
        "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
        "CLANG_CXX_LIBRARY": "libc++",
        "MACOSX_DEPLOYMENT_TARGET": "10.15",
        "OTHER_CFLAGS": [
          "-ObjC++",
          "-DELECTRON_SAFE_BUILD=1"
        ],
        "OTHER_LDFLAGS": [
          "-framework AppKit",
          "-Wl,-no_compact_unwind"
        ],
        "GCC_SYMBOLS_PRIVATE_EXTERN": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES"
      },
      "link_settings": {
        "libraries": [
          "-framework AVFoundation",
          "-framework CoreMedia", 
          "-framework CoreVideo",
          "-framework Foundation",
          "-framework AppKit",
          "-framework ScreenCaptureKit",
          "-framework ApplicationServices",
          "-framework Carbon",
          "-framework Accessibility",
          "-framework CoreAudio"
        ]
      },
      "defines": [ 
        "NAPI_DISABLE_CPP_EXCEPTIONS",
        "ELECTRON_SAFE_BUILD=1",
        "NODE_ADDON_API_DISABLE_DEPRECATED"
      ],
      "conditions": [
        ["OS=='mac'", {
          "xcode_settings": {
            "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
            "WARNING_CFLAGS": [
              "-Wno-deprecated-declarations",
              "-Wno-unused-variable"
            ]
          }
        }]
      ]
    }
  ]
}
