/// 生成 `packaging/用户手册.html`（§AG·八）。
///
/// 内容**只有一份**：`lib/src/manual_content.dart`。本脚本把它渲染成
/// 自包含的 HTML（无外部引用、无脚本、可打印）—— 用户在软件外
/// 双击就能看，随包分发（`make_release.py` 的 EXTRA 清单）。
///
/// ## 四道门禁都在这条链上
///
/// 1. [assertManualIsUserFacing] —— 手册混进开发词汇直接停（不产出文件）；
/// 2. 版本戳 —— 用 `AppVersion.display`，与 `make_release.py` 的版本比对呼应；
/// 3. 写出前自检 —— 版本行必须真的渲染出来、产物里不得出现闭包字符串
///    （`${_esc(x)}` 误写成 `$_esc(x)` 时拒绝写出，台账 §AI-2）；
/// 4. `test/manual_test.dart` / `selfcheck_manual.dart` —— 内容结构与黑名单的镜像断言。
///
/// 运行：`cd packages/shensuanzi_app && dart run tool/make_manual_html.dart`
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';

String _esc(String text) =>
    const HtmlEscape(HtmlEscapeMode.element).convert(text);

/// 把一段文本里的 `\n` 变成 `<br>`（先转义再替换，顺序不能反）。
String _lines(String text) => _esc(text).replaceAll('\n', '<br>\n      ');

void _renderBlock(ManualBlock block, StringBuffer out) {
  switch (block) {
    case ManualParagraph(:final text):
      out.writeln('    <p>${_lines(text)}</p>');
    case ManualSteps(:final items):
      out.writeln('    <ol>');
      for (final String item in items) {
        out.writeln('      <li>${_esc(item)}</li>');
      }
      out.writeln('    </ol>');
    case ManualNote(:final text, :final warning):
      out.writeln(
        '    <div class="${warning ? 'warn' : 'tip'}">${_lines(text)}</div>',
      );
    case ManualQa(:final question, :final answer):
      out
        ..writeln('    <p class="q">问：${_esc(question)}</p>')
        ..writeln('    <p class="a">答：${_lines(answer)}</p>');
  }
}

String _renderHtml(String versionLine) {
  final List<ManualSection> sections = buildManualSections(
    versionLine: versionLine,
  );
  final List<String> hits = assertManualIsUserFacing(sections);
  if (hits.isNotEmpty) {
    stderr.writeln('手册里出现了开发词汇，拒绝生成（先改内容）：');
    for (final String hit in hits) {
      stderr.writeln('  - $hit');
    }
    exitCode = 1;
    return '';
  }

  final StringBuffer toc = StringBuffer();
  final StringBuffer body = StringBuffer();
  for (int i = 0; i < sections.length; i++) {
    final ManualSection section = sections[i];
    final String anchor = 's-${section.id}';
    toc.writeln(
      '      <li><a href="#$anchor">${i + 1}. ${_esc(section.title)}</a></li>',
    );
    body
      ..writeln('  <section id="$anchor">')
      ..writeln('    <h2>${i + 1}. ${_esc(section.title)}</h2>');
    for (final ManualBlock block in section.blocks) {
      _renderBlock(block, body);
    }
    body.writeln('  </section>');
  }

  final String html =
      '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>神算子用户手册</title>
<style>
  :root { color-scheme: light; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 24px 16px 64px;
    font-family: "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", sans-serif;
    font-size: 16px; line-height: 1.85; color: #24292f; background: #ffffff;
  }
  main { max-width: 760px; margin: 0 auto; }
  header { border-bottom: 3px solid #3f51b5; padding-bottom: 12px; margin-bottom: 20px; }
  header h1 { margin: 0 0 4px; font-size: 26px; color: #2c3a92; }
  header .ver { color: #57606a; font-size: 14px; }
  nav { background: #f6f8fa; border: 1px solid #d0d7de; border-radius: 8px;
        padding: 12px 16px; margin-bottom: 28px; }
  nav ol { margin: 0; padding-left: 22px; columns: 2; column-gap: 32px; }
  nav li { break-inside: avoid; }
  nav a { color: #2c3a92; text-decoration: none; }
  nav a:hover { text-decoration: underline; }
  section { margin-bottom: 34px; }
  h2 { font-size: 20px; color: #2c3a92; border-left: 4px solid #3f51b5;
       padding-left: 10px; margin: 0 0 10px; }
  p { margin: 8px 0; white-space: pre-line; }
  ol { margin: 8px 0 8px 4px; padding-left: 24px; }
  li { margin: 6px 0; }
  .tip { background: #f0f7f0; border: 1px solid #b7dfb7; border-radius: 8px;
         padding: 10px 14px; margin: 10px 0; }
  .warn { background: #fdf6e3; border: 1px solid #e8c268; border-radius: 8px;
          padding: 10px 14px; margin: 10px 0; }
  .q { font-weight: 600; margin-top: 14px; }
  .a { margin-left: 14px; }
  footer { border-top: 1px solid #d0d7de; color: #57606a; font-size: 13px;
           margin-top: 40px; padding-top: 12px; }
  a { color: #2c3a92; }
  @media print {
    body { font-size: 12pt; padding: 0; }
    nav { display: none; }
    section { break-inside: avoid-page; }
  }
</style>
</head>
<body>
<main>
  <header>
    <h1>神算子 · 用户手册</h1>
    <div class="ver">${_esc(versionLine)}　·　这份手册在软件的「帮助」页也能打开</div>
  </header>
  <nav>
    <ol>
${toc.toString().trimRight()}
    </ol>
  </nav>
${body.toString().trimRight()}
  <footer>
    神算子 ${_esc(versionLine)} · 许可 AGPL-3.0（见随包 LICENSE 文件） ·
    第三方组件见 THIRD_PARTY.md · 本手册内容与软件内「完整手册」同源
  </footer>
</main>
</body>
</html>
''';

  // ⚠️ 写出前自检（台账 §AI-2，反向验证过）：模板里把 `${_esc(x)}` 误写成
  // `$_esc(x)` 时，Dart 会把**闭包自己的 toString()** 印进页面
  // （「Closure: (String) => String from Function …」）—— 内容源是好的，
  // 黑名单与镜像断言都拦不住，只有在这里查渲染产物才抓得到。
  // 两条都要过：版本行必须真的渲染出来；不得出现任何闭包字符串。
  final String escapedVersion = _esc(versionLine);
  if (!html.contains(escapedVersion) || html.contains('Closure:')) {
    stderr.writeln('生成的 HTML 版本行异常（模板插值写错了？），拒绝写出。');
    exitCode = 1;
    return '';
  }
  return html;
}

Future<void> main() async {
  // 脚本按自身路径定位仓库根：packages/shensuanzi_app/tool/ → 上三级
  final String repoRoot = Directory(
    p.normalize(p.join(p.dirname(p.fromUri(Platform.script)), '..', '..', '..')),
  ).path;
  final String outPath = p.join(repoRoot, 'packaging', '用户手册.html');

  final String html = _renderHtml(AppVersion.display);
  if (html.isEmpty) return; // 校验失败：exitCode 已置 1，原因已打在 stderr

  Directory(p.dirname(outPath)).createSync(recursive: true);
  File(outPath).writeAsStringSync(html, flush: true);

  final int bytes = File(outPath).lengthSync();
  final int sectionCount = buildManualSections(versionLine: AppVersion.display).length;
  stdout.writeln('已生成 $outPath');
  stdout.writeln('  章节 $sectionCount 个，$bytes 字节，版本戳 ${AppVersion.display}');
}
