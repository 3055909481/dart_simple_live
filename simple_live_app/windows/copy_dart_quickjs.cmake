# 在构建完成后动态查找 dart_quickjs.dll 并复制到可执行文件目录。
#
# dart_quickjs 使用 Dart native assets (code_assets/hooks)，其 .dll 由
# hook/build.dart 在 flutter_assemble 阶段编译产生。这个时机晚于 CMake
# configure，所以不能在 configure 时判断 dll 是否存在——全新构建时必然
# 找不到。这里改为 POST_BUILD 阶段执行，此时 dll 已经生成。
#
# 用法: cmake -DSOURCE_ROOT=<repo>/simple_live_app -DTARGET_DIR=<Release dir> -P copy_dart_quickjs.cmake

set(_candidates "")

# 路径 1: Flutter native assets 标准输出目录
list(APPEND _candidates "${SOURCE_ROOT}/build/native_assets/windows/dart_quickjs.dll")

# 路径 2: Dart hooks runner 缓存目录（可能带 hash 子目录）
file(GLOB_RECURSE _hook_candidates
  "${SOURCE_ROOT}/.dart_tool/hooks_runner/shared/dart_quickjs/build/*/dart_quickjs.dll")
list(APPEND _candidates ${_hook_candidates})

# 路径 3: 兜底 —— 在仓库根（上一级）全盘搜索
get_filename_component(_repo_root "${SOURCE_ROOT}/.." ABSOLUTE)
file(GLOB_RECURSE _wide_candidates
  "${_repo_root}/build/*/dart_quickjs.dll"
  "${_repo_root}/.dart_tool/*/dart_quickjs.dll")
list(APPEND _candidates ${_wide_candidates})

foreach(_cand IN LISTS _candidates)
  if(EXISTS "${_cand}")
    file(COPY "${_cand}" DESTINATION "${TARGET_DIR}")
    message(STATUS "dart_quickjs.dll copied from: ${_cand}")
    return()
  endif()
endforeach()

# 找不到不阻断构建，但给出明确告警（ flutter_distributor 打包时会看到）
message(WARNING
  "dart_quickjs.dll NOT FOUND after build. Douyu signing will fail at runtime. Searched paths:\n  ${_candidates}")
