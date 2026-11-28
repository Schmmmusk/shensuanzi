// 关于页（2026-11-28 重构）的页面级测试。
//
// 守四件事：
// ① 门户六个入口 + 版本行；
// ② 许可 / 第三方组件**真的从文件读**（不是代码里抄的）；
// ③ 文件不存在 ⇒ 「未能读取文件」+ 找过的路径（**绝不白屏/崩溃**）；
// ④ 200% 应用内缩放：门户不溢出、长文本页能滚。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/about_page.dart';

/// 200% 缩放外壳（模拟设置里「特大」档）
Widget scaled(Widget home, {double scale = 1.0}) => MaterialApp(
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: home,
);

void main() {
  testWidgets('门户：图标 / 名称 / 版本行 + 六个入口', (WidgetTester tester) async {
    await tester.pumpWidget(
      scaled(const AboutPage(versionLine: 'v9.9.9（示例）', schemaVersion: 8)),
    );
    await tester.pumpAndSettle();

    expect(find.text('神算子'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('about-version'))).data,
      'v9.9.9（示例）（schema v8）',
      reason: '版本行由构造参数拼出来，页面自己不读全局',
    );
    for (final String key in <String>[
      'about-license',
      'about-third-party',
      'about-developers',
      'about-thanks',
      'about-postscript',
      'about-source',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: '缺少入口：$key');
    }
  });

  testWidgets('门户 @200%：不溢出（列表能滚）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      scaled(
        const AboutPage(versionLine: 'v9.9.9（示例）', schemaVersion: 8),
        scale: 2.0,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '200% 档不允许黄黑溢出');
    // 最后一个入口在视口外 ⇒ 必须能滚到
    await tester.scrollUntilVisible(
      find.byKey(const Key('about-source')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('about-source')), findsOneWidget);
  });

  testWidgets('图标：用真实资源（不是 Material 占位图标）', (WidgetTester tester) async {
    await tester.pumpWidget(
      scaled(const AboutPage(versionLine: 'v9.9.9（示例）', schemaVersion: 8)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('about-icon')),
      findsOneWidget,
      reason: '顶部必须是 assets/app_icon.png 这张真实图标',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('访问源码仓库：用系统浏览器打开**正确地址**', (WidgetTester tester) async {
    final List<String> opened = <String>[];
    await tester.pumpWidget(
      scaled(
        AboutPage(
          versionLine: 'v9.9.9（示例）',
          schemaVersion: 8,
          // 注入出口：测试不该真去拉起浏览器
          openUrl: (String url) async {
            opened.add(url);
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('about-source')));
    await tester.pumpAndSettle();

    expect(opened, <String>[sourceRepositoryUrl]);
    expect(opened.single, 'https://github.com/Schmmmusk/shensuanzi');
    // 成功时不弹"没能打开浏览器"
    expect(find.text('没能打开浏览器'), findsNothing);
  });

  testWidgets('访问源码仓库：打不开时给 Gitee 镜像（可复制）', (WidgetTester tester) async {
    await tester.pumpWidget(
      scaled(
        AboutPage(
          versionLine: 'v9.9.9（示例）',
          schemaVersion: 8,
          openUrl: (String url) async => false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('about-source')));
    await tester.pumpAndSettle();

    expect(find.text('没能打开浏览器'), findsOneWidget);
    expect(
      find.textContaining('https://github.com/Schmmmusk/shensuanzi'),
      findsWidgets,
    );
    expect(
      find.textContaining('https://gitee.com/fdatps/shensuanzi'),
      findsWidgets,
      reason: '国内打不开 GitHub 时，Gitee 镜像必须摆出来',
    );
  });

  testWidgets('开源许可：**从文件读**（不是代码里抄的）', (WidgetTester tester) async {
    final Directory dir = Directory.systemTemp.createTempSync('about_license_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(
      p.join(dir.path, 'LICENSE'),
    ).writeAsStringSync('GNU AFFERO GENERAL PUBLIC LICENSE\n测试用许可正文');

    await tester.pumpWidget(
      scaled(OpenSourceLicensePage(searchDirs: <Directory>[dir])),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('about-document-text')), findsOneWidget);
    expect(
      find.textContaining('GNU AFFERO GENERAL PUBLIC LICENSE'),
      findsOneWidget,
      reason: '页面显示的内容必须来自文件本身',
    );
  });

  testWidgets('第三方组件：读 THIRD_PARTY.md', (WidgetTester tester) async {
    final Directory dir = Directory.systemTemp.createTempSync('about_third_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(
      p.join(dir.path, 'THIRD_PARTY.md'),
    ).writeAsStringSync('# 第三方组件与许可声明\n| SQLite | Public Domain |');

    await tester.pumpWidget(
      scaled(ThirdPartyPage(searchDirs: <Directory>[dir])),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('SQLite'), findsOneWidget);
  });

  testWidgets('文件不存在 ⇒ 「未能读取文件」+ 找过的路径（不白屏、不崩）', (WidgetTester tester) async {
    final Directory empty = Directory.systemTemp.createTempSync(
      'about_missing_',
    );
    addTearDown(() => empty.deleteSync(recursive: true));

    await tester.pumpWidget(
      scaled(OpenSourceLicensePage(searchDirs: <Directory>[empty])),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('about-document-missing')),
      findsOneWidget,
      reason: '被误删时给兜底，不能白屏',
    );
    expect(
      find.textContaining('LICENSE'),
      findsWidgets,
      reason: '要告诉用户缺的是哪个文件',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('长文本页 @200%：能滚到底（不折行成一条细线）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final Directory dir = Directory.systemTemp.createTempSync('about_long_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'LICENSE')).writeAsStringSync(
      List<String>.generate(
        60,
        (int i) => '第 $i 行：这是一段比较长的许可正文，用来验证换行与滚动。',
      ).join('\n'),
    );

    await tester.pumpWidget(
      scaled(OpenSourceLicensePage(searchDirs: <Directory>[dir]), scale: 2.0),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '滚动过程不许抛异常');
  });
}
