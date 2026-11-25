/// 完整用户手册页（§AG·八）。
///
/// ## 内容不是这里写的
///
/// 全部来自 `manual_content.dart`（纯 Dart 单一来源）—— 随包分发的
/// `用户手册.html` 用**同一份数据**由 `make_manual_html.dart` 生成，
/// 两边永远一致。本页只负责把数据摆成 Flutter 的样子。
///
/// ## 渲染纪律
///
/// - 手册面向**所有用户**（含把字号调到 200% 的）：行高 1.7 起步，
///   提示框不用纯颜色区分（加「注意 / 小贴士」前缀，色弱也能分清）；
/// - 整页可滚动（UI 内容一律要能滚动 —— 200% 缩放是已发布功能）；
/// - 不造句：所有文字来自内容模型，本文件不出现任何用户可见的新文案。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

/// 完整手册页。从「帮助」页最上方进入。
class ManualPage extends StatefulWidget {
  const ManualPage({super.key, required this.versionLine});

  /// 印在「反馈与版本」一章的版本行（宿主传 `AppVersion.display`）。
  final String versionLine;

  @override
  State<ManualPage> createState() => _ManualPageState();
}

class _ManualPageState extends State<ManualPage> {
  /// 每章一个 `GlobalKey`，供目录跳转用（批 3 第 17 条）。
  final Map<int, GlobalKey> _sectionKeys = <int, GlobalKey>{};

  GlobalKey _keyFor(int index) =>
      _sectionKeys.putIfAbsent(index, () => GlobalKey());

  // ---- 宽屏两栏（2026-11-25 用户裁定）----
  //
  // 宽屏上把目录钉在**左侧**、正文自己滚：原来目录是正文顶部的一个折叠面板，
  // 滚到第 8 章想换章得一路滚回顶上。窄屏保持原样（折叠面板），不倒退。

  /// 正文滚动控制器（只用于「滚到哪一章了」的跟随高亮）
  final ScrollController _contentScroll = ScrollController();

  /// 正文视口的 GlobalKey（用来把章标题的全局 y 换成"相对视口"的 y）
  final GlobalKey _contentKey = GlobalKey();

  /// 当前章下标（左侧目录高亮它）
  int _current = 0;

  @override
  void initState() {
    super.initState();
    _contentScroll.addListener(_syncCurrentSection);
  }

  @override
  void dispose() {
    _contentScroll
      ..removeListener(_syncCurrentSection)
      ..dispose();
    super.dispose();
  }

  /// 跟随高亮：找**最后一个**顶边已经越过视口顶部的章。
  ///
  /// 用 `localToGlobal` 而不是「累计偏移」——章高随字号/窗口变化，
  /// 累计偏移在 200% 档必然漂（与 `_jumpTo` 用 `ensureVisible` 同一个理由）。
  void _syncCurrentSection() {
    if (!mounted) return;
    final RenderBox? viewport =
        _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null) return;
    final double top = viewport.localToGlobal(Offset.zero).dy;
    int best = 0;
    for (int i = 0; i < _sectionKeys.length; i++) {
      final RenderBox? box =
          _sectionKeys[i]?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      if (box.localToGlobal(Offset.zero).dy <= top + 12) best = i;
    }
    if (best != _current) setState(() => _current = best);
  }

  /// 跳到第 [index] 章。**用 `ensureVisible` 而不是算偏移** ——
  /// 章高随字号变化，算偏移必然在 200% 档跳错位置。
  Future<void> _jumpTo(int index) async {
    if (index != _current) setState(() => _current = index);
    final BuildContext? target = _sectionKeys[index]?.currentContext;
    if (target == null) return;
    await Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      alignment: 0.0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = theme.textTheme.bodySmall?.color ?? Colors.black54;
    final List<ManualSection> sections = buildManualSections(
      versionLine: widget.versionLine,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('用户手册')),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 2026-11-25（用户）：宽屏改 **左侧目录固定 + 正文独立滚动**。
          // 阈值 1000：正文列本身 640 + 目录 280 + 边距仍有余量；
          // 窄屏（手机 / 小窗）保持原来的「目录在正文顶部」，不倒退。
          if (constraints.maxWidth < 1000) {
            return _singlePane(theme, secondary, sections);
          }
          return _twoPane(theme, secondary, sections);
        },
      ),
    );
  }

  /// 窄屏：与原来完全一致（目录是正文顶部的一个折叠面板）。
  Widget _singlePane(
    ThemeData theme,
    Color secondary,
    List<ManualSection> sections,
  ) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 批 3 第 17 条：**目录可跳转**。20 章的手册没有目录，
            // 用户只能一路滚 —— 对中老年用户等于「找不到」。
            _ManualToc(sections: sections, onTap: _jumpTo),
            const SizedBox(height: 8),
            ..._sectionWidgets(theme, secondary, sections),
          ],
        ),
      ),
    ),
  );

  /// 宽屏：左目录（固定，当前章高亮）+ 右正文（独立滚动）。
  Widget _twoPane(
    ThemeData theme,
    Color secondary,
    List<ManualSection> sections,
  ) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      SizedBox(width: 280, child: _sideToc(theme, sections)),
      const VerticalDivider(width: 1),
      Expanded(
        child: SingleChildScrollView(
          key: _contentKey,
          controller: _contentScroll,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _sectionWidgets(theme, secondary, sections),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  /// 左侧固定目录。点一行 ⇒ 正文滚过去；滚正文 ⇒ `_current` 跟着变。
  Widget _sideToc(ThemeData theme, List<ManualSection> sections) =>
      ListView.builder(
        key: const Key('manual-side-toc'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: sections.length,
        itemBuilder: (BuildContext context, int i) => ListTile(
          key: Key('manual-side-toc-$i'),
          dense: true,
          selected: i == _current,
          selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.10),
          leading: Text('${i + 1}', style: const TextStyle(height: 1.6)),
          title: Text(
            sections[i].title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(height: 1.5),
          ),
          onTap: () => _jumpTo(i),
        ),
      );

  /// 正文（章 + 内容块 + 页脚）—— 两种布局共用，避免两份漂移。
  List<Widget> _sectionWidgets(
    ThemeData theme,
    Color secondary,
    List<ManualSection> sections,
  ) => <Widget>[
    for (int i = 0; i < sections.length; i++) ...<Widget>[
      KeyedSubtree(
        key: _keyFor(i),
        child: _SectionHeader(index: i + 1, title: sections[i].title),
      ),
      for (final ManualBlock block in sections[i].blocks)
        _Block(block: block, secondary: secondary),
      const SizedBox(height: 28),
    ],
    Text(
      '这份手册在软件文件夹里也有一份网页版（用户手册.html），'
      '双击就能用浏览器打开、可打印。',
      style: TextStyle(height: 1.7, color: secondary),
    ),
  ];
}

/// 手册目录（批 3 第 17 条）。
///
/// **默认收起**：20 章全展开会占掉半屏，反而把正文挤下去。
/// 展开后每行一章，点一行跳过去 —— 比「一路滚 20 章」快得多。
class _ManualToc extends StatelessWidget {
  const _ManualToc({required this.sections, required this.onTap});

  final List<ManualSection> sections;
  final void Function(int index) onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // 去掉 ExpansionTile 展开时的那条分隔线（视觉噪音）
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('manual-toc'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: Text(
            '目录（共 ${sections.length} 章）',
            style: const TextStyle(height: 1.6, fontWeight: FontWeight.w600),
          ),
          children: <Widget>[
            for (int i = 0; i < sections.length; i++)
              ListTile(
                key: Key('manual-toc-$i'),
                dense: true,
                leading: Text('${i + 1}', style: const TextStyle(height: 1.6)),
                title: Text(
                  sections[i].title,
                  style: const TextStyle(height: 1.6),
                ),
                onTap: () => onTap(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.index, required this.title});

  final int index;
  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          // ⚠️ **不写死 30×30**（2026-10-20 用户实测）：`特大` 及以上字号时
          // 数字比方框还高 ⇒ 被方框裁掉，而且**没有任何黄黑提示**
          //（`Text` 被紧约束裁切不算 RenderFlex 溢出，不会报警）。
          // 改成「最小 30×30 + 随文字撑开」：小字号看起来与原来一致。
          Container(
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$index',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// 手册正文 → 富文本（§审查：手册里的 `**加粗**` 以前是**原样印成星号**的）。
///
/// 只认 `**…**` 一种标记 —— 手册不需要完整 Markdown，多一种语法就多一处
/// 两边渲染不一致的机会（HTML 侧与这里必须同款）。
Widget _manualText(String text, TextStyle style) {
  // 按 `**` 切开后**奇数段**是加粗的（0 普通 / 1 粗 / 2 普通 …）
  final List<String> parts = text.split('**');
  return Text.rich(
    TextSpan(
      children: <TextSpan>[
        for (int i = 0; i < parts.length; i++)
          TextSpan(
            text: parts[i],
            style: i.isOdd
                ? const TextStyle(fontWeight: FontWeight.w700)
                : null,
          ),
      ],
    ),
    style: style,
  );
}

class _Block extends StatelessWidget {
  const _Block({required this.block, required this.secondary});

  final ManualBlock block;
  final Color secondary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle body = TextStyle(
      height: 1.7,
      color: theme.textTheme.bodyLarge?.color,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: switch (block) {
        ManualParagraph(:final text) => _manualText(text, body),
        ManualSteps(:final items) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // C3·真机反馈：编号圆圈是固定尺寸，最大缩放下内部数字
                    // （textScaler 放大）会戳出圆圈边界 —— 圆圈随缩放一起变大
                    Container(
                      width: MediaQuery.textScalerOf(context).scale(22),
                      height: MediaQuery.textScalerOf(context).scale(22),
                      margin: const EdgeInsets.only(top: 3),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.12,
                        ),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${i + 1}',
                        // #30（2026-10-14）：**圆圈与字号必须同步放大** —— 两者都手动乘了
                        // textScaler（`scale(22)` / `scale(12)`），若再让 `fontSize` 被
                        // **自动**放大一次，实际字号就是 `12·s²`，而圆圈只有 `22·s`
                        // ⇒ `s > 1.83` 时字符必戳出圆外（PC / 手机同一份代码 ⇒ 两端同现）。
                        // `noScaling` 只关掉「自动那一次」，比例恒定。
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(
                          fontSize: MediaQuery.textScalerOf(context).scale(12),
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: _manualText(items[i], body)),
                  ],
                ),
              ),
          ],
        ),
        ManualNote(:final text, :final warning) => Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: warning ? const Color(0xFFFDF6E3) : const Color(0xFFF0F7F0),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: warning
                  ? const Color(0xFFE8C268)
                  : const Color(0xFFB7DFB7),
            ),
          ),
          child: _manualText('${warning ? '注意' : '小贴士'}：$text', body),
        ),
        ManualQa(:final question, :final answer) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _manualText('问：$question', body),
            // 问句本身就是主句，用「问：」前缀 + 原有字重（不再整句加粗，
            // 免得与正文里的 `**` 强调抢视觉）
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: _manualText('答：$answer', body),
            ),
          ],
        ),
      },
    );
  }
}
