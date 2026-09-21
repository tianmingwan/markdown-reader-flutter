// 性能自测：MDREADER_PERF=1 时收集每一帧的耗时，供真实输入（xdotool）压测后统计。
import 'dart:io';

import 'package:flutter/scheduler.dart';

class Perf {
  static bool enabled = false;
  static final List<List<double>> _frames = <List<double>>[];
  static final Stopwatch _sw = Stopwatch();
  static double? _readyAt;

  static void init() {
    enabled = Platform.environment['MDREADER_PERF'] == '1';
    if (!enabled) return;
    _sw.start();
    SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> ts) {
      for (final t in ts) {
        _frames.add(<double>[
          _sw.elapsedMicroseconds / 1000,
          t.totalSpan.inMicroseconds / 1000,
        ]);
      }
    });
  }

  static void markReady() {
    if (!enabled) return;
    _readyAt = _sw.elapsedMicroseconds / 1000;
  }

  static double percentile(List<double> v, double p) {
    if (v.isEmpty) return 0;
    final s = List<double>.from(v)..sort();
    final k = (s.length - 1) * p / 100.0;
    final f = k.floor();
    final c = f + 1 < s.length ? f + 1 : f;
    return s[f] + (s[c] - s[f]) * (k - f);
  }

  /// 统计 markReady 之后 [windowSec] 秒窗口内的帧
  static String report(double windowSec) {
    final start = _readyAt;
    if (start == null) return 'PERF no-ready';
    final end = start + windowSec * 1000;
    final win = _frames
        .where((f) => f[0] >= start && f[0] <= end)
        .map((f) => f[1])
        .toList();
    if (win.isEmpty) return 'PERF n=0（窗口内没有帧）';
    final mean = win.reduce((a, b) => a + b) / win.length;
    final jank33 = win.where((x) => x > 33).length;
    final jank100 = win.where((x) => x > 100).length;
    final maxv = win.reduce((a, b) => a > b ? a : b);
    return 'PERF n=${win.length} mean=${mean.toStringAsFixed(1)}ms '
        'p50=${percentile(win, 50).toStringAsFixed(1)} '
        'p95=${percentile(win, 95).toStringAsFixed(1)} '
        'max=${maxv.toStringAsFixed(1)} >33ms=$jank33 >100ms=$jank100';
  }

  static void reset() {
    _frames.clear();
    _readyAt = _sw.elapsedMicroseconds / 1000;
  }
}
