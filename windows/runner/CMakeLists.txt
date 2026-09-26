cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# === 源文件按 UTF-8 解读 ======================================================
#
# 本项目所有源文件都是 UTF-8（无 BOM），注释里也写中文。
# MSVC 默认按**系统代码页**解码源文件（简体中文机器上是 936/GBK），
# 一遇到 UTF-8 的中文就报：
#
#     warning C4819: 该文件包含不能在当前代码页(936)中表示的字符
#     error C2220: 以下警告被视为错误
#
# 而 `apply_standard_settings` 里带 `/WX`（警告即错误）⇒ **直接编译失败**。
#
# `/utf-8` = `/source-charset:utf-8` + `/execution-charset:utf-8`，
# 明确告诉编译器「源文件是 UTF-8」。用 `$<COMPILE_LANGUAGE:C,CXX>` 限定，
# 保证这个选项只进 cl.exe、不会被传给资源编译器 rc.exe。
#
# ⚠️ 另一条路是在字符串字面量里用 `\uXXXX` 转义 —— 那只解决**字面量**，
# 注释里的中文照样触发 C4819。见 `docs/windows_build.md` §七。
# ============================================================================
target_compile_options(${BINARY_NAME} PRIVATE "$<$<COMPILE_LANGUAGE:C,CXX>:/utf-8>")
