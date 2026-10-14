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
    reason: '读不到 $file —— `flutter test` 必须在**包根**运行'
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
    reason: '前提：`sale_page.dart` 里找不到特征串「$header」'
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
    reason: '「$header」在销售页与送货页**必须逐字同构**（#45 丙）—— '
        '一处改了另一处没改，就是 #28① 那次漏改的重演',
  );
}

void main() {
  group('开单三页同构（#45 丙 · 机械保证）', () {
    test('`quantityValue`：销售 / 送货 逐字同构', () {
      expectSameBlock('int? get quantityValue');
    });

    test('`baseQuantityValue`：销售 / 送货 逐字同构（#44 的「没填 ⇒ null」口径）', () {
      expectSameBlock('int? get baseQuantityValue');
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
          reason: '$page 的 `_LineCard` 必须比**最小单位**数量'
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
          reason: '采购页出现 `$symbol` —— 要么真的要做负库存提示（那是**新裁定**，'
              '不是「顺手对称」），要么是从另两页复制粘贴带进来的死代码'
              '（D2b 那个 `isPending` 悬空字段的教训）',
        );
      }
    });
  });
}
