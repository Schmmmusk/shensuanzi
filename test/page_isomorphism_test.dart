// 开单三页「同构」的**机械保证**（#45 丙 —— 2026-10-14 裁定「倾向 丙 + 丁」）。
//
// ## 为什么需要它
//
// 三页（`sale_page` / `purchase_page` / `delivery_page`）的 `_RowCtl` / `_LineCard`
// 是**三份独立实现**，而「与 `xxx_page.dart` 同构」**只是注释里的自我声明** ——
// 没有测试断言、没有共享基类、没有 grep 守卫。
// 2026-10-14 的 `#28①` 改销售页、漏送货页就是例证：同一功能上
// 「销售页过度报（空数量假红）/ 送货页漏报（按箱）」两个方向的问题并存（§CV·三十三）。
//
// ## 怎么做的
//
// `_RowCtl` 是**页面私有**的 ⇒ 测试拿不到类型，只能**读源码**、比「特征串」：
// 抠出点名的那几块，**去掉每行缩进**后逐字比较 ⇒ 一处改了另一处没改就红。
// 所以它守的是**语义口径**，不是排版。
//
// ⚠️ **它不能替代纪律**：只覆盖这里点名的几块；「改一页必须 grep 另两页」仍是
// `Agents.md` 纪律 18（#45 丁）。抽共享基类是另一个批次的活（#45 甲 / 乙）。
//
// ⚠️ **前提必须显式**：特征串找不到 ⇒ **红**（改名 / 挪走说明钳子失效了，
// 静默通过与没有钳子一样坏 —— `docs/testing.md`「断言绿 ≠ 断言有效」）。
//
// ⚠️ 本文件按 `lib/src/ui/...` 相对路径读盘 ⇒ **`flutter test` 的工作目录必须是包根**
// （既有先例：`version_test.dart` 就是 `File('pubspec.yaml')` 相对读；读不到会带当前目录报错）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读 `lib/src/ui/<name>.dart`；读不到 ⇒ 报错并打出当前目录（**前提断言**）。
String pageSource(String name) {
  final File file = File('lib/src/ui/$name.dart');
  expect(
    file.existsSync(),
    isTrue,
    reason:
        '读不到 $file —— `flutter test` 必须在**包根**运行'
        '（当前目录：${Directory.current.path}）',
  );
  return file.existsSync() ? file.readAsStringSync() : '';
}

/// 抠出 [header] 起、**成对括号**包住的完整块（含两端的括号）。
///
/// [open] / [close] 缺省 `{}`（代码块）；`[` `]` 用于 `...<Widget>[ … ]` 这类集合字面量。
///
/// 找不到 [header] 或括号不配对 ⇒ `null`（调用方必须断言非空）。
/// ⚠️ 按字符配对，**不解析字符串 / 注释里的括号** —— 只用于本文件点名的那几块
/// （块内没有括号字面量）。
String? blockOf(
  String source,
  String header, {
  String open = '{',
  String close = '}',
}) {
  final int start = source.indexOf(header);
  if (start < 0) return null;
  final int from = source.indexOf(open, start);
  if (from < 0) return null;
  int depth = 0;
  for (int i = from; i < source.length; i++) {
    if (source[i] == open) {
      depth++;
    } else if (source[i] == close) {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  return null;
}

/// 抠出以 [header] 开头、到**第一个 `;` 为止**的语句（用于没有大括号的判定式）。
String? statementOf(String source, String header) {
  final int start = source.indexOf(header);
  if (start < 0) return null;
  final int end = source.indexOf(';', start);
  if (end < 0) return null;
  return source.substring(start, end + 1);
}

/// 归一化：去掉每行缩进与空行 ⇒ **只比语义，不比排版**。
String normalize(String block) => block
    .split('\n')
    .map((String line) => line.trim())
    .where((String line) => line.isNotEmpty)
    .join('\n');

/// 断言 `sale_page` 与 `delivery_page` 的 [header] 块**逐字同构**。
void expectSameBlock(String header) {
  final String? sale = blockOf(pageSource('sale_page'), header);
  final String? delivery = blockOf(pageSource('delivery_page'), header);
  expect(
    sale,
    isNotNull,
    reason:
        '前提：`sale_page.dart` 里找不到特征串「$header」'
        '—— 改名 / 挪走就得跟着改本测试（这正是它要防的事）',
  );
  expect(
    delivery,
    isNotNull,
    reason: '前提：`delivery_page.dart` 里找不到特征串「$header」',
  );
  if (sale == null || delivery == null) return; // 前提已红，无需再比
  expect(
    normalize(sale),
    equals(normalize(delivery)),
    reason:
        '「$header」在销售页与送货页**必须逐字同构**（#45 丙）—— '
        '一处改了另一处没改，就是 #28① 那次漏改的重演',
  );
}

void main() {
  group('开单三页同构（#45 丙 · 机械保证）', () {
    // 2026-11-26：`_RowCtl` 已抽成 `line_row.dart` 的 `LineRowModel`
    //（三页共用一份）。原来的「逐字比对两份源码」**降级为更强的判据**：
    // ① 定义只许有一处；② 三个页面不许再各自带一份 `class _RowCtl`。
    //
    // ⚠️ 为什么这比逐字比对更强：从前三份复制体只要**同时**改错，逐字比对照样绿；
    // 现在物理上只有一份实现，改错也是三个页面一起错（可被行为测试抓住）。
    // 2026-11-26（提案 §1.3）：开单三页原来**页面内没有标题**，
    // 用户开单前无法确认"我在开哪一种单"。标题必须三页都在，且共用同一个组件。
    test('三页都有标题（`EntryPageTitle`），文案各自正确', () {
      const Map<String, String> expected = <String, String>{
        'sale_page': "EntryPageTitle('店内销售')",
        'purchase_page': "EntryPageTitle('采购入库')",
        'delivery_page': "EntryPageTitle('送货')",
      };
      for (final MapEntry<String, String> e in expected.entries) {
        final String src = pageSource(e.key);
        expect(
          src,
          contains("import 'entry_page_title.dart';"),
          reason: '${e.key} 没接共享标题组件 —— 三页各写一份必然分叉（字号/边距）',
        );
        expect(
          src,
          contains(e.value),
          reason: '${e.key} 的标题文案写错或丢了：期望 ${e.value}',
        );
      }
    });

    test('`quantityValue` / `baseQuantityValue` 只在 `line_row.dart` 定义一次', () {
      final String shared = pageSource('line_row');
      expect(
        shared,
        contains('int? get quantityValue'),
        reason: '共享模型必须提供 quantityValue（录入单位原始数）',
      );
      expect(
        shared,
        contains('int? get baseQuantityValue'),
        reason: '共享模型必须提供 baseQuantityValue（最小单位数量，#44 的「没填 ⇒ null」口径）',
      );
      expect(
        shared,
        contains('toBaseQuantity('),
        reason: '换算必须走 core 的纯函数，不许在 UI 里自己乘',
      );

      // 三个页面都不许再自带一份（否则"抽离"只是多了一份副本）
      for (final String page in <String>[
        'sale_page',
        'purchase_page',
        'delivery_page',
      ]) {
        final String src = pageSource(page);
        expect(
          src,
          isNot(contains('class _RowCtl')),
          reason: '$page 仍自带 `class _RowCtl` —— 抽离没落地',
        );
        expect(
          src,
          contains("import 'line_row.dart';"),
          reason: '$page 必须 import 共享模型',
        );
        expect(
          src,
          contains('typedef _RowCtl = LineRowModel;'),
          reason: '$page 要保留 `_RowCtl` 这个名字（否则全页改名，diff 变噪音）',
        );
      }
    });

    test('负库存判定式：销售 / 送货 逐字同构', () {
      final String sale = pageSource('sale_page');
      final String delivery = pageSource('delivery_page');
      const String header = 'final bool negativeStock =';
      final String? a = statementOf(sale, header);
      final String? b = statementOf(delivery, header);
      expect(a, isNotNull, reason: '前提：`sale_page.dart` 里找不到「$header」');
      expect(b, isNotNull, reason: '前提：`delivery_page.dart` 里找不到「$header」');
      if (a == null || b == null) return;
      expect(
        normalize(a),
        equals(normalize(b)),
        reason: '判定式同构 —— 「数量口径」一页改了另一页没改，两页就会得出不同结论',
      );
    });

    test('两页都按**换算后**的数量判定（`row.baseQuantityValue`，不是 `quantityValue`）', () {
      const String marker = 'final int? qty = row.baseQuantityValue;';
      for (final String page in <String>['sale_page', 'delivery_page']) {
        expect(
          pageSource(page),
          contains(marker),
          reason:
              '$page 的 `_LineCard` 必须比**最小单位**数量'
              '（用 `quantityValue` = 录入单位原始数，按箱录入必然漏报 —— #44）',
        );
      }
    });

    test('库存提示块：销售 / 送货 逐字同构（**比一致性，不比字面值**）', () {
      // 裁定（2026-10-14 审查 §一·小建议）：**不要**把文案字面值钉死 ——
      // 产品哪天把「本地未同步」改成「本地待传」，只要两页同步改，
      // 本测试**不该**红（它守的是「同构」，不是「文案内容」）。
      // 文案的**语义契约**由行为测试守：`sale_page_test` 的 M08 与
      // `delivery_page_test` 的 #44 组都在断言「本地未同步」真的出现在界面上。
      const String anchor = 'if (row.product != null) ...<Widget>[';
      final String? sale = blockOf(
        pageSource('sale_page'),
        anchor,
        open: '[',
        close: ']',
      );
      final String? delivery = blockOf(
        pageSource('delivery_page'),
        anchor,
        open: '[',
        close: ']',
      );
      expect(sale, isNotNull, reason: '前提：`sale_page.dart` 里找不到库存提示块「$anchor」');
      expect(delivery, isNotNull, reason: '前提：`delivery_page.dart` 里找不到库存提示块');
      if (sale == null || delivery == null) return;
      expect(
        normalize(sale),
        contains('negativeStock'),
        reason: '前提：抠出来的确实是库存提示块（否则下面那条会在比空气）',
      );
      expect(
        normalize(sale),
        equals(normalize(delivery)),
        reason: '库存提示块必须逐字同构 —— 两页同一件事说法不同，用户会以为是两个功能',
      );
    });

    test('采购页**豁免**：不加「无消费点」的对称 getter / 不做负库存判定（#44 裁定 §二）', () {
      final String purchase = pageSource('purchase_page');
      for (final String symbol in <String>[
        'baseQuantityValue',
        'negativeStock',
        'stockOfProduct',
      ]) {
        expect(
          purchase.contains(symbol),
          isFalse,
          reason:
              '采购页出现 `$symbol` —— 要么真的要做负库存提示（那是**新裁定**，'
              '不是「顺手对称」），要么是从另两页复制粘贴带进来的死代码'
              '（D2b 那个 `isPending` 悬空字段的教训）',
        );
      }
    });

    // ⚠️ 这条 pin 断的是**当前实现**（`Expanded`），不是语义 —— 2026-10-16 裁定：
    // 「Flexible / ConstrainedBox 等合法布局同样能修 #52」，改用时三页一起改
    // 并同步本 pin。真正咬住业务的断言是 `delivery_page_test` 的 #52 用例
    // （窄屏 + 2.0 字号 + 大金额 ⇒ 不溢出 + 金额完整）。
    test('合计行（#52）：三页 `_totalBar` 必须是可换行的 **Wrap**（不得退回 Spacer）', () {
      for (final String page in <String>[
        'sale_page',
        'purchase_page',
        'delivery_page',
      ]) {
        final String source = pageSource(page);
        final int head = source.indexOf('Widget _totalBar');
        expect(
          head,
          isNonNegative,
          reason: '$page 找不到 `_totalBar` —— 钳子失效（改名 / 挪走须同步改本测试）',
        );
        // 不用 blockOf：`_totalBar` 是**表达式体**（`=> Padding(...)`），且块内
        // 注释带中文括号字样，按字符配对会截错。改按**成员边界**切：
        // 到下一个两格缩进的成员 / 文档注释为止。
        final int nextMember = source.indexOf(
          RegExp(r'\n  (Widget|///)'),
          head + 10,
        );
        expect(
          nextMember,
          isNonNegative,
          reason: '$page 的 `_totalBar` 后面找不到下一个成员 —— 钳子失效',
        );
        final String bar = source.substring(head, nextMember);
        // ⚠️ 这条 pin 断的是**当前实现**（2026-11-18：三页统一 `Wrap`），不是语义。
        // 为什么从 `Expanded` 改过来：金额是一个**不可断行的词**，`Expanded` 只能把它
        // 压到溢出（108 宽 + 2 倍字号实测 8.3 px）；`Wrap` 放不下时会让金额落第二行。
        // 换用别的合法布局（Flexible / ConstrainedBox…）时三页一起改，并同步本 pin。
        // 真正咬住业务的断言仍是三页各自的「极窄窗口（内容区 108）+ 超大字号」用例。
        expect(
          bar.contains('Wrap(') || bar.contains('Expanded('),
          isTrue,
          reason:
              '$page 的合计行既不是 Wrap 也不是 Expanded —— 窄屏 + 大字号会被裁切'
              '（#52 外测 M13 的原始形态就是 `Spacer`）；有意改掉请三页一起改',
        );
        expect(
          bar,
          isNot(contains('Spacer(')),
          reason:
              '$page 的合计金额格退回了 `Spacer()` —— 那格没有弹性，'
              '#52 会复发；金额格必须 Wrap（或 Expanded）',
        );
      }
    });

    test('返回拦截（#51）：三页同款 —— 手机确认放弃退出、桌面吞掉系统返回', () {
      // 三页是逐字复制的（M09 的教训：只改 sale 漏了 delivery/delivery 漏了
      // purchase）⇒ 返回拦截的三个特征串必须**三页都在**。改法若有意变化，
      // 三页同步改（本测试继续过）；只改一页 ⇒ 这里红。
      const List<String> pins = <String>[
        'canPop: widget.mobileShell && !_hasContent',
        'if (!widget.mobileShell) return;',
        'if (confirmed && context.mounted) Navigator.of(context).pop();',
      ];
      for (final String page in <String>[
        'sale_page',
        'purchase_page',
        'delivery_page',
      ]) {
        final String source = normalize(pageSource(page));
        for (final String pin in pins) {
          expect(
            source,
            contains(pin),
            reason:
                '$page 缺返回拦截特征串「$pin」—— 要么 #51 只改了别的页'
                '（纪律 18），要么这页被有意改掉（那就三页一起改）',
          );
        }
      }
    });

    // ------------------------------------------------------------ 提交错误摘要（2026-11-19）
    //
    // 来源：2026-11-17 提案 60 给**四页**加了「校验失败 → 点一下跳到出错字段」。
    // 四页各自接线（`SubmitErrorSummary` + `_submitErrorItems()` + `_jumpTo`），
    // 漏一页的表现是**点了没反应**（不报错、不红字）—— 比崩了更难发现。
    group('提交错误摘要（四页）', () {
      const List<String> pages = <String>[
        'sale_page',
        'purchase_page',
        'delivery_page',
        'return_page',
      ];

      test('四页都接了：摘要控件 / 生成器 / 跳转回调 / 跳转实现', () {
        for (final String page in pages) {
          final String source = normalize(pageSource(page));
          for (final String pin in <String>[
            'SubmitErrorSummary(',
            '_submitErrorItems()',
            'onJump: _jumpTo',
            'Future<void> _jumpTo(SubmitSection section)',
          ]) {
            expect(
              source,
              contains(pin),
              reason:
                  '$page 缺「$pin」—— 那一页的错误摘要点上去不会跳'
                  '（静默失效：不报错、不红字，只有用户点不动）',
            );
          }
        }
      });

      test('报出来的每一段，都必须在**同一页**的 `_jumpTo` 里被处理', () {
        // 判据比「有没有 onJump」更近一步：**报的段 ⊆ 能跳的段**。
        // 少一个 case 的表现同样是「点了没反应」，而它不会让任何 UI 测试红。
        final RegExp sectionRef = RegExp(r'SubmitSection\.(\w+)');
        for (final String page in pages) {
          final String source = pageSource(page);
          final String? produced = blockOf(
            source,
            'List<SubmitErrorItem> _submitErrorItems()',
          );
          final String? handled = blockOf(
            source,
            'Future<void> _jumpTo(SubmitSection section)',
          );
          expect(
            produced,
            isNotNull,
            reason: '前提：$page 找不到 `_submitErrorItems()`',
          );
          expect(handled, isNotNull, reason: '前提：$page 找不到 `_jumpTo(...)`');
          if (produced == null || handled == null) continue;

          final Set<String> made = sectionRef
              .allMatches(produced)
              .map((RegExpMatch m) => m.group(1)!)
              .toSet();
          final Set<String> canJump = sectionRef
              .allMatches(handled)
              .map((RegExpMatch m) => m.group(1)!)
              .toSet();
          expect(
            made,
            isNotEmpty,
            reason:
                '$page 的 `_submitErrorItems()` 里找不到任何 `SubmitSection.` —— 钳子失效',
          );
          expect(
            made.difference(canJump),
            isEmpty,
            reason:
                '$page 报出了 ${made.difference(canJump).join(' / ')} 段，'
                '但 `_jumpTo` 里没有对应分支 —— 用户点上去不会跳',
          );
        }
      });
    });
  });
}
