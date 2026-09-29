// 用户手册内容的测试（§AG·八）。
//
// 手册的「正确性」不在代码逻辑，而在**内容纪律**：
// 覆盖：章节完整性（≥14 章、每章非空、id 唯一）/ 版本戳必须出现在正文 /
// **开发词汇黑名单**（谁往手册里写「Dart / schema / 编译」就红）/
// HTML 生成物与内容同源（packaging/用户手册.html 含当前版本号 —— 改了版本
// 忘了重新生成手册会在这里红）。
//
// ⚠️ HTML 文件检查用的是**相对仓库根的路径**：本测试从
// `packages/shensuanzi_app` 运行，所以向上三级找 `packaging/`。
import 'dart:io';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';

void main() {
  final List<ManualSection> sections = buildManualSections(
    versionLine: AppVersion.display,
  );

  group('手册内容（单一来源 manual_content.dart）', () {
    test('章节完整：≥14 章、每章有标题有内容、id 唯一', () {
      expect(sections.length, greaterThanOrEqualTo(14));
      final Set<String> ids = <String>{};
      for (final ManualSection section in sections) {
        expect(section.title, isNotEmpty);
        expect(section.blocks, isNotEmpty, reason: '${section.id} 是空章');
        expect(ids.add(section.id), isTrue, reason: 'id 重复：${section.id}');
      }
      expect(ids, containsAll(<String>['backup', 'export', 'faq', 'first-run']));
    });

    test('版本戳必须出现在正文（「反馈与版本」一章）', () {
      final String all = sections
          .expand(
            (ManualSection s) => s.blocks.map(
              (ManualBlock b) => switch (b) {
                ManualParagraph(:final text) => text,
                ManualNote(:final text) => text,
                ManualSteps(:final items) => items.join('\n'),
                ManualQa(:final question, :final answer) => '$question$answer',
              },
            ),
          )
          .join('\n');
      expect(all, contains(AppVersion.display));
    });

    test('开发词汇黑名单：手册里不允许出现给开发者看的内容', () {
      final List<String> hits = assertManualIsUserFacing(sections);
      expect(hits, isEmpty, reason: '手册混进了开发词汇：$hits');
    });
  });

  group('随包网页版（packaging/用户手册.html）', () {
    final File htmlFile = File(
      p.normalize(
        p.join(Directory.current.path, '..', '..', 'packaging', '用户手册.html'),
      ),
    );

    test('存在且与当前版本同源（改版本忘重新生成 → 红）', () {
      expect(htmlFile.existsSync(), isTrue,
          reason: 'packaging/用户手册.html 缺失 —— '
              '在 packages/shensuanzi_app 下运行 '
              '`dart run tool/make_manual_html.dart` 生成');
      final String html = htmlFile.readAsStringSync();
      expect(html, contains(AppVersion.display),
          reason: 'HTML 里的版本戳过期 —— 重新运行生成脚本');
      expect(html, contains('charset="utf-8"'));
    });
  });
}
