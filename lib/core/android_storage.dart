// 安卓「所有文件访问」权限桥（Dart 侧）。
//
// 背景：Flutter 版把 SAF 选中的目录当普通文件系统路径交给 Rust 扫描，
// Android 11+ 未授权时目录能选中但扫出来是 0 篇。授权入口只存在于系统设置里
// （MANAGE_EXTERNAL_STORAGE 不是普通运行时权限），所以这里只做两件事：
// 查询当前状态 + 跳到系统设置页，授权结果由应用回到前台时再查一次。
import 'dart:io';

import 'package:flutter/services.dart';

class AndroidStorage {
  AndroidStorage._();

  static const MethodChannel _channel = MethodChannel('mdreader/android');

  static bool get applicable => Platform.isAndroid;

  /// 是否已获得「所有文件访问」（非安卓恒为 true，表示"不受此限制"）
  static Future<bool> hasAllFilesAccess() async {
    if (!applicable) return true;
    try {
      return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } catch (_) {
      // 通道不可用（旧构建等）：按"有权限"处理，避免把用户挡在门外
      return true;
    }
  }

  /// 跳到系统设置页让用户打开开关（返回后要重新查询）
  static Future<void> requestAllFilesAccess() async {
    if (!applicable) return;
    try {
      await _channel.invokeMethod<void>('requestAllFilesAccess');
    } catch (_) {}
  }
}
