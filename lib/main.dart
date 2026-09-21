import 'package:flutter/material.dart';

import 'app.dart';
import 'perf.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Perf.init();
  runApp(const MarkdownReaderApp());
}
