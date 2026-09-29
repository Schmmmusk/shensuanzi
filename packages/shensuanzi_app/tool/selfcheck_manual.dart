/// `test/manual_test.dart` 的镜像自检（§AG·八）—— 同样的断言，`dart run` 直跑。
///
/// ⚠️ 改一边必须改另一边（镜像纪律，本仓已漂移 8 次）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';

int passed = 0;
int failed = 0;

void check(String label, bool ok, [String? detail]) {
  if (ok) {
    passed++;
    stdout.writeln('  ✓ $label');
  } else {
    failed++;
    stdout.writeln('  ✗ $label${detail == null ? '' : ' → $detail'}');
  }
}

void main() {
  stdout.writeln('--- 手册内容 ---');
  final List<ManualSection> sections = buildManualSections(
    versionLine: AppVersion.display,
  );

  check('章节 ≥ 14', sections.length >= 14, '实际 ${sections.length}');
  final Set<String> ids = <String>{};
  bool allNonEmpty = true;
  for (final ManualSection section in sections) {
    if (section.title.isEmpty || section.blocks.isEmpty) allNonEmpty = false;
    if (!ids.add(section.id)) allNonEmpty = false;
  }
  check('每章有标题有内容且 id 唯一', allNonEmpty);
  check('关键章节齐全', ids.containsAll(<String>['backup', 'export', 'faq', 'first-run']));

  String allText = '';
  for (final ManualSection section in sections) {
    for (final ManualBlock block in section.blocks) {
      allText += switch (block) {
        ManualParagraph(:final text) => text,
        ManualNote(:final text) => text,
        ManualSteps(:final items) => items.join('\n'),
        ManualQa(:final question, :final answer) => '$question$answer',
      };
      allText += '\n';
    }
  }
  check('版本戳出现在正文', allText.contains(AppVersion.display));

  final List<String> hits = assertManualIsUserFacing(sections);
  check('开发词汇黑名单为空', hits.isEmpty, hits.join('、'));

  stdout.writeln('--- 随包网页版 ---');
  // 脚本在 packages/shensuanzi_app/tool/ → 仓库根在上三级
  final String repoRoot = p.normalize(
    p.join(p.dirname(p.fromUri(Platform.script)), '..', '..', '..'),
  );
  final File htmlFile = File(p.join(repoRoot, 'packaging', '用户手册.html'));
  check('用户手册.html 存在', htmlFile.existsSync(),
      '运行 dart run tool/make_manual_html.dart 生成');
  if (htmlFile.existsSync()) {
    final String html = htmlFile.readAsStringSync();
    check('HTML 版本戳与当前版本一致', html.contains(AppVersion.display),
        '重新生成手册');
    check('HTML 声明 utf-8', html.contains('charset="utf-8"'));
  }

  stdout.writeln('\n自检完成：$passed 过 $failed 挂');
  if (failed > 0) exitCode = 1;
}
