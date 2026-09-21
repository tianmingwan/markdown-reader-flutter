// Rust core 的 FFI 绑定。
// 所有重活（markdown 解析 / 语法高亮 / 目录扫描 / 全文搜索 / 会话落盘）都在 Rust 侧，
// Dart 只负责调起与展示。调用一律放进 Isolate，避免阻塞 UI 线程。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'models.dart';

// ---- C 侧签名
typedef _RenderBlocksC = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _RenderBlocksD = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, int);
typedef _RenderFileC = Pointer<Utf8> Function(Pointer<Utf8>, Int32);
typedef _RenderFileD = Pointer<Utf8> Function(Pointer<Utf8>, int);
typedef _ScanTreeC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _ScanTreeD = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _SearchC = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _SearchD = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _SessionLoadC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _SessionLoadD = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _SessionSaveC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _SessionSaveD = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeD = void Function(Pointer<Utf8>);

class NativeCore {
  /// 各平台产物名：Linux/Android 为 .so，Windows 为 .dll，macOS 为 .dylib
  static String get _libName {
    if (Platform.isWindows) return 'mdreader_core.dll';
    if (Platform.isMacOS) return 'libmdreader_core.dylib';
    return 'libmdreader_core.so';
  }

  static String? _cachedPath;

  /// 动态库定位顺序：环境变量 → 平台特例 → 可执行文件同级 → 工程 native/（开发期）。
  static String libPath() {
    if (_cachedPath != null) return _cachedPath!;
    final env = Platform.environment['MDREADER_CORE_SO'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) {
      return _cachedPath = env;
    }
    // Android：动态库随 APK 打在 lib/<abi>/ 下，交给系统按名字解析
    if (Platform.isAndroid) return _cachedPath = _libName;

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final nativeDir = '${Directory.current.path}/native';
    final candidates = <String>[
      '$exeDir/lib/$_libName', // Linux bundle
      '$exeDir/$_libName', // Windows bundle（exe 同级）
      '$exeDir/data/flutter_assets/$_libName',
      '$nativeDir/$_libName', // 开发期
      '${Directory.current.path}/../native/$_libName',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return _cachedPath = c;
    }
    throw StateError('找不到 $_libName，尝试过：\n${candidates.join('\n')}');
  }

  static DynamicLibrary open() => DynamicLibrary.open(libPath());

  /// 库是否存在（启动时用于友好提示）
  static bool available() {
    try {
      libPath();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------ 渲染

  /// 结构化渲染（在后台 isolate 内执行；返回 Map 以便跨 isolate 传递）。
  static Future<RenderedDoc> renderBlocks(
    String source,
    String baseDir,
    bool dark,
  ) async {
    final map = await Isolate.run<Map<String, Object?>>(() {
      final json = _renderBlocksJson(source, baseDir, dark);
      return (jsonDecode(json) as Map).cast<String, Object?>();
    });
    return RenderedDoc.fromJson(map);
  }

  static String _renderBlocksJson(String source, String baseDir, bool dark) {
    final lib = open();
    final fn = lib.lookupFunction<_RenderBlocksC, _RenderBlocksD>(
        'mdreader_render_blocks');
    final free = lib.lookupFunction<_FreeC, _FreeD>('mdreader_free_string');
    final pSrc = source.toNativeUtf8();
    final pBase = baseDir.toNativeUtf8();
    try {
      final res = fn(pSrc, pBase, dark ? 1 : 0);
      if (res == nullptr) throw StateError('Rust 渲染返回空指针');
      try {
        return res.toDartString();
      } finally {
        free(res);
      }
    } finally {
      calloc.free(pSrc);
      calloc.free(pBase);
    }
  }

  /// 直接读文件并渲染（文件 IO 也在 Rust 侧，减少一次跨边界大字符串拷贝）。
  static Future<RenderedDoc> renderFile(String path, bool dark) async {
    final map = await Isolate.run<Map<String, Object?>>(() {
      final lib = open();
      final fn = lib.lookupFunction<_RenderFileC, _RenderFileD>(
          'mdreader_render_file');
      final free = lib.lookupFunction<_FreeC, _FreeD>('mdreader_free_string');
      final p = path.toNativeUtf8();
      try {
        final res = fn(p, dark ? 1 : 0);
        if (res == nullptr) throw StateError('读取或渲染失败：$path');
        try {
          return (jsonDecode(res.toDartString()) as Map).cast<String, Object?>();
        } finally {
          free(res);
        }
      } finally {
        calloc.free(p);
      }
    });
    return RenderedDoc.fromJson(map);
  }

  // ------------------------------------------------------------ 目录树

  static Future<TreeData> scanTree(String root) async {
    final map = await Isolate.run<Map<String, Object?>>(() {
      final lib = open();
      final fn =
          lib.lookupFunction<_ScanTreeC, _ScanTreeD>('mdreader_scan_tree');
      final free = lib.lookupFunction<_FreeC, _FreeD>('mdreader_free_string');
      final p = root.toNativeUtf8();
      try {
        final res = fn(p);
        if (res == nullptr) throw StateError('扫描返回空指针');
        try {
          return (jsonDecode(res.toDartString()) as Map).cast<String, Object?>();
        } finally {
          free(res);
        }
      } finally {
        calloc.free(p);
      }
    });
    return TreeData.fromJson(map);
  }

  // ------------------------------------------------------------ 搜索

  static Future<List<SearchHit>> search(String root, String query) async {
    final list = await Isolate.run<List<Object?>>(() {
      final lib = open();
      final fn = lib.lookupFunction<_SearchC, _SearchD>('mdreader_search');
      final free = lib.lookupFunction<_FreeC, _FreeD>('mdreader_free_string');
      final pr = root.toNativeUtf8();
      final pq = query.toNativeUtf8();
      try {
        final res = fn(pr, pq);
        if (res == nullptr) return <Object?>[];
        try {
          return (jsonDecode(res.toDartString()) as List).cast<Object?>();
        } finally {
          free(res);
        }
      } finally {
        calloc.free(pr);
        calloc.free(pq);
      }
    });
    return list
        .map((e) => SearchHit.fromJson((e as Map).cast<String, Object?>()))
        .toList();
  }

  // ------------------------------------------------------------ 会话

  static SessionData loadSession(String cfgDir) {
    final lib = open();
    final fn =
        lib.lookupFunction<_SessionLoadC, _SessionLoadD>('mdreader_session_load');
    final free = lib.lookupFunction<_FreeC, _FreeD>('mdreader_free_string');
    final p = cfgDir.toNativeUtf8();
    try {
      final res = fn(p);
      if (res == nullptr) return SessionData();
      try {
        return SessionData.fromJson(
            (jsonDecode(res.toDartString()) as Map).cast<String, Object?>());
      } finally {
        free(res);
      }
    } finally {
      calloc.free(p);
    }
  }

  static bool saveSession(String cfgDir, SessionData s) {
    final lib = open();
    final fn =
        lib.lookupFunction<_SessionSaveC, _SessionSaveD>('mdreader_session_save');
    final pc = cfgDir.toNativeUtf8();
    final pj = jsonEncode(s.toJson()).toNativeUtf8();
    try {
      return fn(pc, pj) == 1;
    } finally {
      calloc.free(pc);
      calloc.free(pj);
    }
  }

  /// 配置目录（与原 Tauri 版一致，便于用户数据延续）。
  /// MDREADER_CFG_DIR 可覆盖（自测 / 多配置档）。
  static String configDir() {
    final override = Platform.environment['MDREADER_CFG_DIR'];
    if (override != null && override.isNotEmpty) return override;
    final home = Platform.environment['HOME'] ?? '.';
    final xdg = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
    return '$xdg/com.chensdong.mdreader';
  }
}
