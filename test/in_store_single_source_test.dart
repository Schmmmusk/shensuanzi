// 「在店可售」公式**只有一份**的机械保证（提案 61 决策 61-⑦）。
//
// ## 为什么需要它
//
// 2026-11-13 之前，`effectiveInStoreOf` 定义在 `lib/src/ui/stock_page.dart`。
// 提案 61 把它定性为**业务领域规则**并下沉到 core（`util/in_store.dart`），
// 因为缺货榜也要用它 —— 而「下沉」最常见的失败方式是**留了一份副本在 UI**：
// 编译器不会报（两份都在、都合法），只有两处口径将来分叉时才会以
// 「库存页说缺货、概览页说不缺」的形式暴露（提案 §三 洞 2 就是这个现象）。
//
// ⇒ 断言：**全仓只有 core 一处定义**，且 UI 层不存在第二份**公式本体**。
// 这是 `docs/testing.md`「断言绿 ≠ 断言有效」的要求：写得进断言，才叫机械保证。
//
// ⚠️ 前提必须显式：读不到目录 ⇒ 报错并打出当前目录（`flutter test` 必须在包根）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 递归收集 [dir] 下所有 `.dart` 文件。
List<File> dartFiles(String dir) {
  final Directory root = Directory(dir);
  expect(
    root.existsSync(),
    isTrue,
    reason:
        '读不到 $dir —— `flutter test` 必须在**包根**运行（当前目录：${Directory.current.path}）',
  );
  return root
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList(growable: false);
}

void main() {
  test('effectiveInStoreOf 全仓只有一处定义（core/util/in_store.dart）', () {
    final RegExp definition = RegExp(r'int\s+effectiveInStoreOf\s*\(');
    final List<String> hits = <String>[
      for (final File f in <File>[
        ...dartFiles('lib'),
        ...dartFiles('packages'),
      ])
        if (definition.hasMatch(f.readAsStringSync()))
          f.path.replaceAll('\\', '/'),
    ];

    expect(hits, <String>[
      'packages/shensuanzi_core/lib/src/util/in_store.dart',
    ], reason: 'UI 里又出现了一份定义 —— 公式必须只有一处（提案 61 §五）');
  });

  test('公式本体（book + unsynced − inTransit）不散落在 UI 层', () {
    final RegExp body = RegExp(r'book\s*\+\s*unsynced\s*-\s*inTransit');
    final List<String> hits = <String>[
      for (final File f in dartFiles('lib'))
        if (body.hasMatch(f.readAsStringSync())) f.path.replaceAll('\\', '/'),
    ];
    expect(hits, isEmpty, reason: 'UI 层自己算了一遍在店可售：${hits.join(', ')}');
  });

  test('库存页确实不再定义它（回归点：搬迁时最容易留下的那份）', () {
    final File file = File('lib/src/ui/stock_page.dart');
    expect(file.existsSync(), isTrue);
    final String source = file.readAsStringSync();
    expect(RegExp(r'int\s+effectiveInStoreOf\s*\(').hasMatch(source), isFalse);
    // 但仍然**必须**在用它（否则说明搬迁时把调用也删了，页面会静默不用同口径）
    expect(source.contains('effectiveInStoreOf('), isTrue);
  });
}
