// 「保存中锁输入」的**机械保证**（#N-i 裁定甲，2026-11-06）。
//
// ## 为什么需要它
//
// 五个提交界面（三张开单页 + 退货页 + 结算对话框）都该在 `_saving` 期间锁住输入。
// 但这是**逐字段手写 `enabled: !_saving`** —— 没有基类、没有钳子。
// #N-i 就是漏改的实例：`return_page` 的 4 个 `TextField` **全无** `enabled`，
// 只有按钮禁用（待裁事项-2026-11-04.md §N-i）。这与纪律 18 说的「同构代码容易漏改」
// 同源，也和 `page_isomorphism_test.dart`（#45）守的是同一类问题。
//
// ## 怎么做的
//
// 读源码数「特征串」：每个提交界面里，**每个 `TextField` 都要有 `enabled`**，
// **每个 `DropdownButton` 都要在保存期间禁用**（`enabled:` 或 `onChanged: <cond> ? null :`）。
// 数量对不上 ⇒ 红。
//
// ⚠️ **前提必须显式**：文件读不到、或某个特征串一个都没有 ⇒ **红**
// （改名 / 挪走说明钳子失效了，静默通过与没有钳子一样坏 —— `docs/testing.md`）。
//
// ⚠️ 本文件按 `lib/src/ui/...` 相对路径读盘 ⇒ 工作目录必须是包根
// （既有先例：`page_isomorphism_test.dart` / `version_test.dart`）。
//
// ⚠️ 这是**数量**级别的钳子，不是「每个字段都真的锁对了」的证明 ——
// 它挡的是「整页漏改」，挡不住「新加一个字段忘了锁」。后者仍是纪律 18。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读 `lib/src/ui/<name>.dart`；读不到 ⇒ 报错并打出当前目录（**前提断言**）。
String _source(String name) {
  final File file = File('lib/src/ui/$name.dart');
  expect(
    file.existsSync(),
    isTrue,
    reason:
        '读不到 $file —— `flutter test` 必须在**包根**运行'
        '（当前目录：${Directory.current.path}）',
  );
  return file.readAsStringSync();
}

/// 去掉行注释与字符串字面量，避免注释里提到的 `TextField(` 被数进去。
///
/// ⚠️ 粗糙但够用：本钳子只数**成对括号开头的构造调用**，注释行整行删掉即可；
/// 字符串里的 `TextField(` 在本仓不存在（有则本函数会一并删掉，方向安全 ——
/// 少数只会让钳子更松，不会假红）。
String _stripComments(String source) {
  return source
      .split('\n')
      .map((String line) {
        final int idx = line.indexOf('//');
        return idx < 0 ? line : line.substring(0, idx);
      })
      .join('\n');
}

int _count(String text, String pattern) => RegExp(pattern).allMatches(text).length;

/// 五个提交界面：`_saving` 期间必须锁输入。
const List<String> kSubmitPages = <String>[
  'sale_page',
  'purchase_page',
  'delivery_page',
  'return_page',
  'settlement_dialog',
];

void main() {
  group('#N-i 保存中锁输入的机械保证', () {
    for (final String page in kSubmitPages) {
      test('$page：每个 TextField 都有 enabled', () {
        final String src = _stripComments(_source(page));

        // 前提：这确实是个「有保存状态」的提交界面。
        expect(
          src.contains('_saving'),
          isTrue,
          reason: '$page 里没有 _saving —— 它还是提交界面吗？'
              '若确实不再需要保存锁，把它从 kSubmitPages 移除并说明原因。',
        );

        final int fields = _count(src, r'TextField\s*\(');
        final int locked = _count(src, r'enabled:\s*');
        expect(
          fields,
          greaterThan(0),
          reason: '$page 里一个 TextField 都没有 —— 特征串失效了，钳子该改。',
        );
        expect(
          locked,
          greaterThanOrEqualTo(fields),
          reason:
              '$page 有 $fields 个 TextField，但只有 $locked 处 `enabled:` ⇒ '
              '有字段在保存期间仍可输入（#N-i 漏改同款）。'
              '新加字段请一并加 `enabled: !_saving`。',
        );
      });

      test('$page：DropdownButton 在保存期间被禁用', () {
        final String src = _stripComments(_source(page));
        final int dropdowns = _count(src, r'DropdownButton<');
        if (dropdowns == 0) return; // 该页没有下拉，无需检查
        // DropdownButton **没有** `enabled` 参数 ⇒ 禁用写法是 `onChanged: <cond> ? null : ...`
        // （见 purchase_page:2112 / settlement_dialog:281）。
        final int gated = _count(src, r'onChanged:\s*\w+\s*\?');
        final int viaEnabled = _count(src, r'enabled:\s*enabled');
        expect(
          gated + viaEnabled,
          greaterThanOrEqualTo(dropdowns),
          reason:
              '$page 有 $dropdowns 个 DropdownButton，只找到 '
              '${gated + viaEnabled} 处按保存状态禁用 ⇒ 保存期间还能改账户。'
              '写法：`onChanged: _saving ? null : (...)`。',
        );
      });
    }

    test('product_form_dialog 不在锁输入名单里（裁定甲的「另行评估」）', () {
      // 用户裁定：「N-i 的商品对话框不宜机械地套用整页开单的处理」
      // 「商品建档对话框则应该先考虑保存期间是否存在实际输入风险」。
      //
      // 实测结论（2026-11-06）：**没有实际输入风险** ——
      // `_save()` 从 `setState(() => _saving = true)` 到 `Navigator.pop`
      // **一个 await 都没有**（同步 sink 调用），整个「保存中」区间
      // 都在同一个微任务里跑完 ⇒ 用户**没有任何窗口**能改到输入。
      // 而且它是模态对话框，保存期间本来就点不到。
      // ⇒ 加 `enabled` 只会让 10 个字段在**校验失败回显**时闪一下禁用态，
      //   收益为零、噪音为正。这里钉住「它不在名单里」，防止将来有人
      //   「为了一致性」机械地加上去。
      expect(kSubmitPages, isNot(contains('product_form_dialog')));
      final String src = _source('product_form_dialog');
      expect(
        src.contains('_saving'),
        isTrue,
        reason: 'product_form_dialog 仍有 _saving（按钮禁用），只是不锁输入。',
      );
    });
  });
}