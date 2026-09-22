// 数据模型：与 Rust 侧 blocks.rs / tree.rs / search.rs / session.rs 的 JSON 字段一一对应。
// Rust 用 #[serde(tag = "t")]，所以块的判别字段是 t，内联的也是 t。

// ------------------------------------------------------------------ 内联

sealed class MdInline {
  const MdInline();
}

class InlText extends MdInline {
  final String s;
  const InlText(this.s);
}

class InlStrong extends MdInline {
  final List<MdInline> inl;
  const InlStrong(this.inl);
}

class InlEm extends MdInline {
  final List<MdInline> inl;
  const InlEm(this.inl);
}

class InlStrike extends MdInline {
  final List<MdInline> inl;
  const InlStrike(this.inl);
}

class InlCode extends MdInline {
  final String s;
  const InlCode(this.s);
}

class InlLink extends MdInline {
  final String href;
  final bool internal;
  final List<MdInline> inl;
  const InlLink(this.href, this.internal, this.inl);
}

class InlImg extends MdInline {
  final String src;
  final String alt;
  const InlImg(this.src, this.alt);
}

class InlBr extends MdInline {
  const InlBr();
}

class InlTask extends MdInline {
  final bool checked;
  const InlTask(this.checked);
}

class InlSoftBr extends MdInline {
  const InlSoftBr();
}

MdInline parseInline(Object? raw) {
  final m = (raw as Map).cast<String, Object?>();
  final t = m['t'] as String? ?? 'Text';
  switch (t) {
    case 'Text':
      return InlText(m['s'] as String? ?? '');
    case 'Strong':
      return InlStrong(_list(m['inl']));
    case 'Em':
      return InlEm(_list(m['inl']));
    case 'Strike':
      return InlStrike(_list(m['inl']));
    case 'Code':
      return InlCode(m['s'] as String? ?? '');
    case 'Link':
      return InlLink(
        m['href'] as String? ?? '',
        m['internal'] as bool? ?? false,
        _list(m['inl']),
      );
    case 'Img':
      return InlImg(m['src'] as String? ?? '', m['alt'] as String? ?? '');
    case 'Br':
      return const InlBr();
    case 'Task':
      return InlTask(m['checked'] as bool? ?? false);
    case 'SoftBr':
      return const InlSoftBr();
    default:
      return InlText(m['s'] as String? ?? '');
  }
}

List<MdInline> _list(Object? raw) =>
    (raw as List? ?? const []).map(parseInline).toList();

// ------------------------------------------------------------------ 块

sealed class MdBlock {
  const MdBlock();
}

class BlkHeading extends MdBlock {
  final int level;
  final List<MdInline> inl;
  const BlkHeading(this.level, this.inl);
}

class BlkPara extends MdBlock {
  final List<MdInline> inl;
  const BlkPara(this.inl);
}

class MdToken {
  final String s;
  final String? c;
  final bool b;
  final bool i;
  final bool u;
  const MdToken(this.s, this.c, this.b, this.i, this.u);
}

class BlkCode extends MdBlock {
  final String lang;
  final String text;
  final List<List<MdToken>> lines;
  const BlkCode(this.lang, this.text, this.lines);
}

class BlkMermaid extends MdBlock {
  final String code;
  const BlkMermaid(this.code);
}

class BlkList extends MdBlock {
  final bool ordered;
  final int start;
  final List<List<MdBlock>> items;
  const BlkList(this.ordered, this.start, this.items);
}

class BlkQuote extends MdBlock {
  final List<MdBlock> blocks;
  const BlkQuote(this.blocks);
}

class BlkTable extends MdBlock {
  final List<String> aligns;
  final List<List<MdInline>> head;
  final List<List<List<MdInline>>> rows;
  const BlkTable(this.aligns, this.head, this.rows);
}

class BlkHr extends MdBlock {
  const BlkHr();
}

class BlkDetails extends MdBlock {
  final List<MdInline> summary;
  final List<MdBlock> blocks;
  const BlkDetails(this.summary, this.blocks);
}

class BlkRaw extends MdBlock {
  final String text;
  const BlkRaw(this.text);
}

MdBlock parseBlock(Object? raw) {
  final m = (raw as Map).cast<String, Object?>();
  switch (m['t'] as String? ?? 'Para') {
    case 'Heading':
      return BlkHeading((m['level'] as num?)?.toInt() ?? 1, _list(m['inl']));
    case 'Para':
      return BlkPara(_list(m['inl']));
    case 'Code':
      final lines = (m['lines'] as List? ?? const [])
          .map((l) => (l as List)
              .map((tk) {
                final tm = (tk as Map).cast<String, Object?>();
                return MdToken(
                  tm['s'] as String? ?? '',
                  tm['c'] as String?,
                  tm['b'] as bool? ?? false,
                  tm['i'] as bool? ?? false,
                  tm['u'] as bool? ?? false,
                );
              })
              .toList())
          .toList();
      return BlkCode(
        m['lang'] as String? ?? '',
        m['text'] as String? ?? '',
        lines,
      );
    case 'Mermaid':
      return BlkMermaid(m['code'] as String? ?? '');
    case 'List':
      return BlkList(
        m['ordered'] as bool? ?? false,
        (m['start'] as num?)?.toInt() ?? 1,
        (m['items'] as List? ?? const [])
            .map((it) => (it as List).map(parseBlock).toList())
            .toList(),
      );
    case 'Quote':
      return BlkQuote(_blocks(m['blocks']));
    case 'Table':
      return BlkTable(
        (m['aligns'] as List? ?? const []).map((x) => x as String).toList(),
        (m['head'] as List? ?? const [])
            .map((c) => (c as List).map(parseInline).toList())
            .toList(),
        (m['rows'] as List? ?? const [])
            .map((r) => (r as List)
                .map((c) => (c as List).map(parseInline).toList())
                .toList())
            .toList(),
      );
    case 'Hr':
      return const BlkHr();
    case 'Details':
      return BlkDetails(_list(m['summary']), _blocks(m['blocks']));
    case 'Raw':
      return BlkRaw(m['text'] as String? ?? '');
    default:
      return BlkRaw('');
  }
}

List<MdBlock> _blocks(Object? raw) =>
    (raw as List? ?? const []).map(parseBlock).toList();

class RenderedDoc {
  /// 原始块 JSON（惰性解析：大文档有上万个块，全量建模型会拖慢首屏）
  final List<Object?> rawBlocks;
  final bool hasMath;
  final bool hasMermaid;
  final int words;
  final Map<int, MdBlock> _cache = {};

  RenderedDoc(this.rawBlocks, this.hasMath, this.hasMermaid, this.words);

  int get blockCount => rawBlocks.length;

  /// 按需解析第 i 块（带缓存）
  MdBlock blockAt(int i) =>
      _cache.putIfAbsent(i, () => parseBlock(rawBlocks[i]));

  /// 全量解析（自测/统计用）
  List<MdBlock> get blocks =>
      List<MdBlock>.generate(rawBlocks.length, blockAt);

  factory RenderedDoc.fromJson(Map<String, Object?> m) => RenderedDoc(
        (m['blocks'] as List? ?? const []).cast<Object?>(),
        m['has_math'] as bool? ?? false,
        m['has_mermaid'] as bool? ?? false,
        (m['words'] as num?)?.toInt() ?? 0,
      );
}

// ------------------------------------------------------------------ 目录树

class TreeNode {
  final String name;
  final String path;
  final String kind; // dir | file
  final int size;
  final int mtime;
  final List<TreeNode> children;
  TreeNode(this.name, this.path, this.kind, this.size, this.mtime,
      this.children);

  bool get isDir => kind == 'dir';

  factory TreeNode.fromJson(Map<String, Object?> m) => TreeNode(
        m['name'] as String? ?? '',
        m['path'] as String? ?? '',
        m['kind'] as String? ?? 'file',
        (m['size'] as num?)?.toInt() ?? 0,
        (m['mtime'] as num?)?.toInt() ?? 0,
        (m['children'] as List? ?? const [])
            .map((c) => TreeNode.fromJson((c as Map).cast<String, Object?>()))
            .toList(),
      );
}

class TreeData {
  final String name;
  final String path;
  final int mdCount;
  final List<TreeNode> children;
  TreeData(this.name, this.path, this.mdCount, this.children);

  factory TreeData.fromJson(Map<String, Object?> m) => TreeData(
        m['name'] as String? ?? '',
        m['path'] as String? ?? '',
        (m['mdCount'] as num?)?.toInt() ?? 0,
        (m['children'] as List? ?? const [])
            .map((c) => TreeNode.fromJson((c as Map).cast<String, Object?>()))
            .toList(),
      );
}

// ------------------------------------------------------------------ 搜索

class SearchHit {
  final String path;
  final String name;
  final String matchedBy; // name | content
  final List<String> snippets;
  SearchHit(this.path, this.name, this.matchedBy, this.snippets);

  factory SearchHit.fromJson(Map<String, Object?> m) => SearchHit(
        m['path'] as String? ?? '',
        m['name'] as String? ?? '',
        m['matchedBy'] as String? ?? 'name',
        (m['snippets'] as List? ?? const []).map((s) => s as String).toList(),
      );
}

// ------------------------------------------------------------------ 会话

class RootRef {
  final String kind; // fs | saf
  final String loc;
  RootRef(this.kind, this.loc);
  factory RootRef.fromJson(Map<String, Object?> m) =>
      RootRef(m['kind'] as String? ?? 'fs', m['loc'] as String? ?? '');
  Map<String, Object?> toJson() => {'kind': kind, 'loc': loc};
}

class SessionData {
  List<RootRef> recentRoots;
  RootRef? lastRoot;
  String? lastFile;
  Map<String, double> filePositions;
  String? theme; // light | dark | null
  int? fontSize;
  String? sortMode;

  /// 右侧 AI 面板（内嵌 DeepSeek）是否打开 / 宽度
  bool? aiPanelOpen;
  int? aiPanelWidth;

  SessionData({
    this.recentRoots = const [],
    this.lastRoot,
    this.lastFile,
    this.filePositions = const {},
    this.theme,
    this.fontSize,
    this.sortMode,
    this.aiPanelOpen,
    this.aiPanelWidth,
  });

  factory SessionData.fromJson(Map<String, Object?> m) => SessionData(
        recentRoots: (m['recentRoots'] as List? ?? const [])
            .map((r) => RootRef.fromJson((r as Map).cast<String, Object?>()))
            .toList(),
        lastRoot: m['lastRoot'] == null
            ? null
            : RootRef.fromJson((m['lastRoot'] as Map).cast<String, Object?>()),
        lastFile: m['lastFile'] as String?,
        filePositions: ((m['filePositions'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, (v as num).toDouble())),
        theme: m['theme'] as String?,
        fontSize: (m['fontSize'] as num?)?.toInt(),
        sortMode: m['sortMode'] as String?,
        aiPanelOpen: m['aiPanelOpen'] as bool?,
        aiPanelWidth: (m['aiPanelWidth'] as num?)?.toInt(),
      );

  Map<String, Object?> toJson() => {
        'recentRoots': recentRoots.map((r) => r.toJson()).toList(),
        'lastRoot': lastRoot?.toJson(),
        'lastFile': lastFile,
        'filePositions': filePositions,
        'theme': theme,
        'fontSize': fontSize,
        'sortMode': sortMode,
        'aiPanelOpen': aiPanelOpen,
        'aiPanelWidth': aiPanelWidth,
      };
}

/// 直接从原始块 JSON 里抽取可读文本（不构建模型，用于快速寻找首个命中块）。
/// 只取已知的文本字段，避免把 "t":"Para" 这类元信息当成正文。
String rawBlockText(Object? raw, [int depth = 0]) {
  if (depth > 8) return '';
  if (raw is String) return raw;
  if (raw is List) {
    final b = StringBuffer();
    for (final x in raw) {
      b.write(rawBlockText(x, depth + 1));
    }
    return b.toString();
  }
  if (raw is Map) {
    final b = StringBuffer();
    for (final k in const [
      's', 'text', 'code', 'alt', 'summary', 'inl', 'blocks', 'items',
      'head', 'rows',
    ]) {
      final v = raw[k];
      if (v != null) b.write(rawBlockText(v, depth + 1));
    }
    return b.toString();
  }
  return '';
}

// ------------------------------------------------------------------ 排序

/// 6 种排序，与原前端 tree.ts 对齐（含自然排序：1,2,10 而非 1,10,2）。
enum SortMode {
  nameAsc('name-asc', '名称 A→Z'),
  nameDesc('name-desc', '名称 Z→A'),
  mtimeDesc('mtime-desc', '修改时间（最新）'),
  mtimeAsc('mtime-asc', '修改时间（最早）'),
  sizeDesc('size-desc', '大小（大→小）'),
  sizeAsc('size-asc', '大小（小→大）');

  final String id;
  final String label;
  const SortMode(this.id, this.label);

  static SortMode fromId(String? id) =>
      SortMode.values.firstWhere((m) => m.id == id, orElse: () => nameAsc);
}

/// 自然排序比较：把连续数字当整数比较，其余按字符比较。
int naturalCompare(String a, String b) {
  final la = a.toLowerCase();
  final lb = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < la.length && j < lb.length) {
    final ca = la.codeUnitAt(i);
    final cb = lb.codeUnitAt(j);
    final da = ca >= 48 && ca <= 57;
    final db = cb >= 48 && cb <= 57;
    if (da && db) {
      var ni = i;
      while (ni < la.length &&
          la.codeUnitAt(ni) >= 48 &&
          la.codeUnitAt(ni) <= 57) {
        ni++;
      }
      var nj = j;
      while (nj < lb.length &&
          lb.codeUnitAt(nj) >= 48 &&
          lb.codeUnitAt(nj) <= 57) {
        nj++;
      }
      final na = int.tryParse(la.substring(i, ni)) ?? 0;
      final nb = int.tryParse(lb.substring(j, nj)) ?? 0;
      if (na != nb) return na.compareTo(nb);
      i = ni;
      j = nj;
      continue;
    }
    if (ca != cb) return ca.compareTo(cb);
    i++;
    j++;
  }
  return (la.length - i).compareTo(lb.length - j);
}

/// 排序节点列表：目录恒在文件之前（与原版一致），组内按 mode 排。
List<TreeNode> sortNodes(List<TreeNode> nodes, SortMode mode) {
  final out = List<TreeNode>.from(nodes);
  int cmp(TreeNode a, TreeNode b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    switch (mode) {
      case SortMode.nameAsc:
        return naturalCompare(a.name, b.name);
      case SortMode.nameDesc:
        return naturalCompare(b.name, a.name);
      case SortMode.mtimeDesc:
        return b.mtime.compareTo(a.mtime);
      case SortMode.mtimeAsc:
        return a.mtime.compareTo(b.mtime);
      case SortMode.sizeDesc:
        return b.size.compareTo(a.size);
      case SortMode.sizeAsc:
        return a.size.compareTo(b.size);
    }
  }

  out.sort(cmp);
  return out;
}
