// 右侧 AI 面板：原生通道协议 + 状态逻辑 + 降级 UI 的测试。
//
// 面板里的网页是原生子窗口（Linux 上是 WebKitGTK），Flutter 侧只负责
// 「矩形/显隐/操作」的传递与状态，所以这层测试集中在协议与降级行为上。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdreader_flutter/ai/ai_pane.dart';
import 'package:mdreader_flutter/app.dart' show filteredSelectionMenuItems;
import 'package:mdreader_flutter/ai/ai_types.dart';
import 'package:mdreader_flutter/core/ai_panel_native.dart';
import 'package:mdreader_flutter/state.dart';

const MethodChannel channel = MethodChannel('mdreader/ai_panel');

/// 记录原生收到的调用，并按需返回/抛错。
class FakeNative {
  final List<MethodCall> calls = [];
  Object? Function(MethodCall call)? responder;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final r = responder?.call(call);
      if (r is Exception) throw r;
      return r;
    });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  MethodCall? callTo(String name) {
    for (final c in calls.reversed) {
      if (c.method == name) return c;
    }
    return null;
  }
}

Widget hostPane(
  AppState s, {
  double width = 420,
  AiBackendKind? backend,
}) =>
    MaterialApp(
      // 真实应用里面板在 ListenableBuilder 里（state 一变就重建），测试保持一致
      home: Scaffold(
        body: ListenableBuilder(
          listenable: s,
          builder: (context, _) => Row(
            children: [
              const Expanded(child: SizedBox()),
              AiPane(state: s, width: width, backendOverride: backend),
            ],
          ),
        ),
      ),
    );

void main() {
  late FakeNative fake;

  setUp(() {
    fake = FakeNative()..install();
    AiPanelNative.availability = AiPaneAvailability.unknown;
    AiPanelNative.onLoadChanged = null;
    AiPanelNative.onPromptResult = null;
  });

  tearDown(() {
    fake.uninstall();
    AiPanelNative.onLoadChanged = null;
    AiPanelNative.onPromptResult = null;
  });

  group('原生通道协议', () {
    test('open 传下去的是设备像素矩形与数据目录，成功时可用性为 ready', () async {
      fake.responder = (c) => c.method == 'open' ? true : null;
      final ok = await AiPanelNative.open(
        rect: const Rect.fromLTWH(10, 20, 300, 400),
        dataDir: '/tmp/cfg/webview',
        cacheDir: '/tmp/cfg/webview-cache',
      );
      expect(ok, isTrue);
      expect(AiPanelNative.availability, AiPaneAvailability.ready);
      final args = (fake.callTo('open')!.arguments as Map).cast<String, Object?>();
      expect(args['x'], 10);
      expect(args['y'], 20);
      expect(args['w'], 300);
      expect(args['h'], 400);
      expect(args['dataDir'], '/tmp/cfg/webview');
      expect(args['cacheDir'], '/tmp/cfg/webview-cache');
      expect(args.containsKey('prompt'), isFalse, reason: '没有上下文时不该带 prompt');
    });

    test('原生回 unsupported（或没编译 WebKit）时退化为不可用，不抛异常', () async {
      fake.responder = (c) => PlatformException(code: 'unsupported');
      final ok = await AiPanelNative.open(
        rect: Rect.zero,
        dataDir: '/tmp/a',
        cacheDir: '/tmp/b',
      );
      expect(ok, isFalse);
      expect(AiPanelNative.availability, AiPaneAvailability.unsupported);
    });

    test('平台没有这个通道时同样只返回 false', () async {
      fake.responder = (c) => MissingPluginException('no channel');
      final ok = await AiPanelNative.open(
        rect: Rect.zero,
        dataDir: '/tmp/a',
        cacheDir: '/tmp/b',
      );
      expect(ok, isFalse);
      expect(AiPanelNative.availability, AiPaneAvailability.unsupported);
    });

    test('空文本不发起注入', () async {
      expect(await AiPanelNative.prompt('   '), isFalse);
      expect(fake.callTo('prompt'), isNull);
    });

    test('显隐 / 刷新 / 缩放 / 清登录态都按名字下发', () async {
      await AiPanelNative.setVisible(false);
      await AiPanelNative.reload();
      await AiPanelNative.setZoom(0.8);
      await AiPanelNative.clearData();
      await AiPanelNative.setBounds(const Rect.fromLTWH(0, 0, 100, 200));
      expect(fake.callTo('setVisible')!.arguments['visible'], isFalse);
      expect(fake.callTo('reload'), isNotNull);
      expect(fake.callTo('setZoom')!.arguments['level'], 0.8);
      expect(fake.callTo('clearData'), isNotNull);
      expect(fake.callTo('setBounds')!.arguments['w'], 100);
    });

    test('原生事件回调：页面状态与注入结果', () async {
      await AiPanelNative.setVisible(true); // 建立 handler
      AiLoadEvent? event;
      bool? promptOk;
      AiPanelNative.onLoadChanged = (e) => event = e;
      AiPanelNative.onPromptResult = (ok, _) => promptOk = ok;

      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'mdreader/ai_panel',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('loadChanged', <String, Object?>{
            'state': 'failed',
            'uri': 'https://chat.deepseek.com/',
            'error': '网络不可达',
          }),
        ),
        (_) {},
      );
      expect(event!.isFailed, isTrue);
      expect(event!.error, '网络不可达');

      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'mdreader/ai_panel',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('promptResult', <String, Object?>{'ok': false}),
        ),
        (_) {},
      );
      expect(promptOk, isFalse);
    });
  });

  group('选中菜单过滤（去掉 ROM/第三方的"文本处理"项）', () {
    test('只留内置动作，爱奇艺搜索/朗读这类 custom 项被丢掉', () {
      final items = <ContextMenuButtonItem>[
        ContextMenuButtonItem(
            onPressed: () {}, type: ContextMenuButtonType.copy),
        ContextMenuButtonItem(
            onPressed: () {}, type: ContextMenuButtonType.share),
        ContextMenuButtonItem(
            onPressed: () {}, type: ContextMenuButtonType.selectAll),
        // 平台 ACTION_PROCESS_TEXT 处理器：Flutter 给它们的是 custom 类型
        ContextMenuButtonItem(label: '爱奇艺搜索', onPressed: () {}),
        ContextMenuButtonItem(label: 'AI搜索', onPressed: () {}),
        ContextMenuButtonItem(label: '朗读', onPressed: () {}),
        ContextMenuButtonItem(label: '在 Via 中搜索', onPressed: () {}),
        ContextMenuButtonItem(label: '搜视频(推荐)', onPressed: () {}),
      ];
      final kept = filteredSelectionMenuItems(items);
      expect(kept.length, 3);
      expect(
        kept.every((b) => b.type != ContextMenuButtonType.custom),
        isTrue,
      );
      for (final bad in ['爱奇艺搜索', 'AI搜索', '朗读', '在 Via 中搜索', '搜视频(推荐)']) {
        expect(kept.any((b) => b.label == bad), isFalse, reason: '$bad 不该出现');
      }
    });
  });

  group('「问 AI」请求（选中内容 → 内置 DeepSeek）', () {
    test('askAi 会打开面板并挂起请求；两种语义分别记录 submit', () {
      final s = AppState();
      expect(s.aiOpen, isFalse);

      s.askAi('  贪污贿赂渎职类犯罪  ', submit: true);
      expect(s.aiOpen, isTrue, reason: '面板没开就自动打开');
      expect(s.session.aiPanelOpen, isTrue, reason: '开关要写回会话');
      expect(s.aiPendingAsk!.text, '贪污贿赂渎职类犯罪', reason: '两端空白应裁掉');
      expect(s.aiPendingAsk!.submit, isTrue, reason: 'true = 新对话并直接提问');
      expect(s.takePendingAsk()!.submit, isTrue);
      expect(s.aiPendingAsk, isNull, reason: '取走后不能重复发送');

      s.askAi('只放进输入框', submit: false);
      expect(s.takePendingAsk()!.submit, isFalse);

      s.askAi('   ', submit: true);
      expect(s.aiPendingAsk, isNull, reason: '空白内容不该发起请求');
      s.dispose();
    });

    testWidgets('面板取走请求：新对话 + 直接提问会换成「只放进输入框」以外的提示', (t) async {
      fake.responder = (c) => c.method == 'open' ? true : null;
      final s = AppState();
      await t.pumpWidget(hostPane(s, backend: AiBackendKind.external));
      await t.pump(const Duration(milliseconds: 20));
      s.askAi('干', submit: true);
      await t.pump(const Duration(milliseconds: 20));
      // external 后端：内容进剪贴板并如实提示
      expect(s.takePendingAsk(), isNull, reason: '请求应被面板消费掉');
      await t.pump(const Duration(seconds: 3));
    });
  });

  group('面板状态', () {
    test('窗口变窄时面板宽度往下压，保证阅读区不被挤没', () {
      final s = AppState()..aiWidth = AppState.aiPaneDefaultWidth;
      expect(s.aiPaneWidthFor(1600), AppState.aiPaneDefaultWidth);
      // 1000 - 360 = 640 是上限，420 仍放得下
      expect(s.aiPaneWidthFor(1000), AppState.aiPaneDefaultWidth);
      // 700 - 360 = 340 → 面板压到 340
      expect(s.aiPaneWidthFor(700), 340);
      // 再窄就退到最小宽度（阅读区让位）
      expect(s.aiPaneWidthFor(500), AppState.aiPaneMinWidth);
    });

    test('拖动分栏会夹紧并写回会话', () {
      final s = AppState();
      s.setAiWidth(9999);
      expect(s.aiWidth, AppState.aiPaneMaxWidth);
      expect(s.session.aiPanelWidth, AppState.aiPaneMaxWidth.round());
      s.setAiWidth(10);
      expect(s.aiWidth, AppState.aiPaneMinWidth);
    });

    test('开关面板写回会话', () {
      final s = AppState();
      expect(s.session.aiPanelOpen, isNull);
      s.toggleAi();
      expect(s.aiOpen, isTrue);
      expect(s.session.aiPanelOpen, isTrue);
      s.toggleAi();
      expect(s.aiOpen, isFalse);
      expect(s.session.aiPanelOpen, isFalse);
    });

    test('拖动分栏或弹出浮层时，原生网页必须让位', () {
      final s = AppState()..aiOpen = true;
      expect(s.aiNativeVisible, isTrue);
      s.setAiDragging(true);
      expect(s.aiNativeVisible, isFalse, reason: '拖动时原生窗口会吃掉指针事件');
      s.setAiDragging(false);
      s.setOverlayDepth(2);
      expect(s.aiNativeVisible, isFalse, reason: 'Flutter 弹菜单时网页会盖住菜单');
      s.setOverlayDepth(1);
      expect(s.aiNativeVisible, isTrue);
      // 层数不会低于 1（home 路由自己占一层）
      s.setOverlayDepth(0);
      expect(s.overlayDepth, 1);
      s.aiOpen = false;
      expect(s.aiNativeVisible, isFalse);
    });

    test('选区用独立 notifier：拖选不该触发全界面重建', () {
      final s = AppState();
      var globalNotifies = 0;
      s.addListener(() => globalNotifies++);

      s.setSelection('  第一题  ');
      expect(s.selectionText, '第一题', reason: '两端空白应裁掉');
      expect(globalNotifies, 0, reason: '选区变化不能触发全局重建');

      var selectionNotifies = 0;
      s.selection.addListener(() => selectionNotifies++);
      s.setSelection('第二题');
      expect(selectionNotifies, 1);
      s.setSelection('第二题');
      expect(selectionNotifies, 1, reason: '选区没变就不必通知');

      // 安卓上点空白处会先折叠选区（收起系统选词菜单）—— 这时不能清空，
      // 否则「带入提问框」按钮会在同一拍里变成禁用，用户点不上。
      s.setSelection(null);
      s.setSelection('   ');
      expect(s.selectionText, '第二题', reason: '折叠/空白不改动已记下的选区');
      expect(selectionNotifies, 1);

      s.clearSelection();
      expect(s.selectionText, isNull);
      expect(selectionNotifies, 2);
      s.dispose();
    });
  });

  group('降级与加载状态 UI', () {
    // 面板里有加载动画（无限帧），不能用 pumpAndSettle；
    // 同时 showToast 会挂一个 2 秒计时器，测试结束前要把它跑完。
    Future<void> pumpPane(WidgetTester t, AppState s, {String? loadState}) async {
      await t.pumpWidget(hostPane(s));
      await t.pump();
      await t.pump(const Duration(milliseconds: 20));
      if (loadState != null) {
        AiPanelNative.onLoadChanged!(AiLoadEvent(state: loadState));
        await t.pump(const Duration(milliseconds: 20));
      }
      await t.pump(const Duration(seconds: 3));
    }

    testWidgets('原生不可用时给出「用系统浏览器打开」入口', (t) async {
      fake.responder = (c) => PlatformException(code: 'unsupported');
      final s = AppState()..aiOpen = true;
      await pumpPane(t, s);

      expect(find.text('这里本应内嵌 DeepSeek 对话'), findsOneWidget);
      expect(find.text('用系统浏览器打开 DeepSeek'), findsOneWidget);
      expect(s.aiOpen, isTrue, reason: '面板本身还是开着的，只是退化了');
    });

    testWidgets('网页加载失败时给出重试与浏览器兜底', (t) async {
      fake.responder = (c) => c.method == 'open' ? true : null;
      final s = AppState()..aiOpen = true;
      await pumpPane(t, s, loadState: 'failed');

      expect(find.text('网页加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('浏览器打开'), findsOneWidget);
    });

    testWidgets('没有选区时「带入提问框」不可点，有选区后可点并下发', (t) async {
      fake.responder = (c) => switch (c.method) {
            'open' => true,
            'prompt' => true,
            _ => null,
          };
      final s = AppState()..aiOpen = true;
      await pumpPane(t, s, loadState: 'finished');

      final button = find.widgetWithIcon(IconButton, Icons.input);
      expect(button, findsOneWidget);
      expect(t.widget<IconButton>(button).onPressed, isNull);

      s.setSelection('贪污贿赂渎职类犯罪 第 1 题');
      await t.pump();
      expect(t.widget<IconButton>(button).onPressed, isNotNull);

      await t.tap(button);
      await t.pump(const Duration(milliseconds: 20));
      final call = fake.callTo('prompt');
      expect(call, isNotNull);
      expect(call!.arguments['text'], '贪污贿赂渎职类犯罪 第 1 题');
      await t.pump(const Duration(seconds: 3));
    });
  });

  group('平台后端判定（安卓走应用内 WebView，Windows 退化）', () {
    test('各平台映射到正确的承载方式', () {
      expect(detectAiBackend(isLinux: true), AiBackendKind.nativeOverlay,
          reason: 'Linux 桌面端没有 platform view，只能用原生覆盖层');
      expect(detectAiBackend(isAndroid: true), AiBackendKind.inAppWebView);
      expect(detectAiBackend(isIOS: true), AiBackendKind.inAppWebView);
      expect(detectAiBackend(isMacOS: true), AiBackendKind.inAppWebView);
      expect(
        detectAiBackend(
            isLinux: false, isAndroid: false, isIOS: false, isMacOS: false),
        AiBackendKind.external,
        reason: 'Windows 等没有内嵌能力 → 用系统浏览器',
      );
    });

    test('发送脚本：优先点真实发送按钮（合成 Enter 不被 React 采纳）', () {
      final js = aiSubmitScript();
      expect(js, contains('button[type="submit"]'));
      expect(js, contains('send'));
      expect(js, contains('aria-label'));
      // 几何筛选：只挑输入框右半边的按钮，避免误点「深度思考 / 智能搜索」
      expect(js, contains('br.left+br.width*0.6'));
      // 兜底才用合成 Enter
      expect(js, contains("key:'Enter'"));
      expect(js, contains('btn.click()'));
    });

    test('注入脚本：转义正确、用的是 React 受控组件的写法', () {
      final js = aiFillScript('引号"与\\反斜杠\n换行');
      expect(js, contains(r'\"'), reason: '双引号必须转义');
      expect(js, contains(r'\\'), reason: '反斜杠必须转义');
      expect(js, contains(r'\n'), reason: '换行必须转义，否则脚本会断行');
      expect(js, isNot(contains('换行\n";')), reason: '不能出现未转义的换行');
      expect(js, contains('HTMLTextAreaElement.prototype'));
      expect(js, contains("new Event('input'"));
      expect(js, contains('contenteditable'));
      // 控制字符走 \u 转义
      expect(aiFillScript('a\u0001b'), contains(r'\u0001'));
    });

    testWidgets('Windows 一类没有内嵌能力的平台：直接给浏览器兜底', (t) async {
      final s = AppState()..aiOpen = true;
      await t.pumpWidget(hostPane(s, backend: AiBackendKind.external));
      await t.pump(const Duration(milliseconds: 20));
      expect(find.text('这里本应内嵌 DeepSeek 对话'), findsOneWidget);
      expect(find.text('用系统浏览器打开 DeepSeek'), findsOneWidget);
    });
  });
}
