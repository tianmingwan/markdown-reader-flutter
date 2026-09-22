package com.example.mdreader_flutter

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 安卓端「所有文件访问」权限桥。
 *
 * 为什么需要它：Flutter 版把选中的目录当**普通文件系统路径**交给 Rust 扫描
 * （`std::fs::read_dir`），而 Android 11+ 默认禁止应用读取 /storage/emulated/0/ 下
 * 下的非媒体文件，于是目录能选中、扫出来却是 0 篇。
 * MANAGE_EXTERNAL_STORAGE（"所有文件访问"）授权后，普通路径读取即可正常工作。
 *
 * 注意它不是普通运行时权限：只能跳到系统设置页让用户手动打开，
 * 应用侧用 Environment.isExternalStorageManager() 查询结果。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "mdreader/android"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                    "requestAllFilesAccess" -> {
                        requestAllFilesAccess()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasAllFilesAccess(): Boolean {
        // Android 11（API 30）以下没有这个限制，直接当作"有权限"
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return true
        return Environment.isExternalStorageManager()
    }

    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
        } catch (e: Exception) {
            // 个别 ROM 没有"按应用"的页面，退到"所有应用"的权限列表
            startActivity(
                Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }
}
