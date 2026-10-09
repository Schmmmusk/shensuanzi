// 商品建档表单（`product_form_dialog.dart`）的 widget 测试。
//
// 覆盖 §AJ·AI-6（单位可发现性）与 §AJ·AI-5（单位 = 最小销售单位的 UI 文案）：
//  - placeholder 用「例：」开头 —— 「这里可以自由填」的信号（AI-6）
//  - [其他 ▾] 点击聚焦单位输入框 —— 「可以打字」的显式入口（AI-6）
//  - 常用单位 chips ≤ 15 —— 多了就不是「常用」，选择负担会压过省事（AI-6）
//  - 单位说明小字 + 包装说明输入框在场（AI-5）
//  - 带包装说明建档端到端落库（AI-5）
//
// ⚠️ 必须 `useLocalSqlite()`（§N）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/product_form_dialog.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late ProductService service;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_product_form_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    service = ProductService(db);
  });

  tearDown(() {
    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  /// 打开建档对话框的宿主页
  Widget host() => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (BuildContext context) => Center(
          child: FilledButton(
            // D2b：表单只认 sink（桌面 = ServiceMasterSink，与直连逐字同行为）
            onPressed: () => showProductFormDialog(
              context,
              service: service,
              sink: ServiceMasterSink(service),
            ),
            child: const Text('打开表单'),
          ),
        ),
      ),
    ),
  );

  Future<void> openForm(WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('打开表单'));
    await tester.pumpAndSettle();
  }

  /// 按 labelText / hintText 定位输入框 —— hint 是单位框唯一可辨别的锚点。
  /// ⚠️ 参数是**过滤条件**：`null` = 不限制，**不是**「要求该字段等于 null」
  /// （几乎每个框都有 label 和 hint，按「等于 null」匹配永远落空——
  /// 2026-09-30 四条测试同挂这一处的教训）。
  Finder field({String? label, String? hint}) => find.byWidgetPredicate(
    (Widget w) {
      if (w is! TextField) return false;
      final InputDecoration? d = w.decoration;
      if (label != null && d?.labelText != label) return false;
      if (hint != null && d?.hintText != hint) return false;
      return true;
    },
  );

  // ⚠️ 必须是局部 final 变量，**不能写 `get`**：getter 只能放在类 / 库顶层，
  // 写在 main() 里是语法错误（startup_test.dart 查找器一节的老坑，2026-09-29 又踩一次）
  final Finder unitField = field(hint: '例：桶、箱、捆、扎');

  // ============================================================ AI-6
  testWidgets('AI-6：两个自由文本框的 placeholder 都用「例：」开头', (
    WidgetTester tester,
  ) async {
    await openForm(tester);

    final TextField unit = tester.widget<TextField>(unitField);
    expect(
      unit.decoration!.hintText,
      startsWith('例：'),
      reason: '「例：」= 这里可以自由填（chips 不是白名单）',
    );

    final TextField note = tester.widget<TextField>(
      field(label: '包装说明（可选）'),
    );
    expect(note.decoration!.hintText, startsWith('例：'));
    expect(
      note.decoration!.helperText,
      '只是备注，不影响记账',
      reason: '纯备注的定位要说清，否则用户不敢填',
    );
  });

  testWidgets('AI-6：[其他 ▾] 点击后聚焦单位输入框（打字的显式入口）', (
    WidgetTester tester,
  ) async {
    await openForm(tester);

    expect(find.text('其他 ▾'), findsOneWidget);
    await tester.tap(find.text('其他 ▾'));
    await tester.pump();

    final TextField unit = tester.widget<TextField>(unitField);
    expect(
      unit.focusNode?.hasFocus,
      isTrue,
      reason: '点了「其他」就该能直接打字 —— 聚焦是它唯一的承诺',
    );
  });

  testWidgets('AI-6：常用单位 chips ≤ 15，点一下就填进输入框', (
    WidgetTester tester,
  ) async {
    await openForm(tester);

    final int chipCount = tester.widgetList(find.byType(ActionChip)).length;
    expect(
      chipCount,
      lessThanOrEqualTo(15),
      reason: '14 个常用 + 1 个 [其他 ▾]。超过 15 个就不再是「常用」',
    );
    expect(find.text('其他 ▾'), findsOneWidget);

    await tester.tap(find.text('桶'));
    await tester.pump();
    expect(
      tester.widget<TextField>(unitField).controller!.text,
      '桶',
      reason: 'chips 的承诺：点一下就填好，不用敲字',
    );
  });

  // ============================================================ AI-5
  testWidgets('AI-5：单位说明小字 + 包装说明输入框在场', (
    WidgetTester tester,
  ) async {
    await openForm(tester);

    expect(
      find.textContaining('单位填最小的售卖单位'),
      findsOneWidget,
      reason: '不教一次，按箱建档后卖 1 个就出小数库存',
    );
    expect(
      find.textContaining('按箱进的货，装箱关系写在下面的「包装说明」里'),
      findsOneWidget,
    );
    expect(find.text('包装说明（可选）'), findsOneWidget);
  });

  testWidgets('AI-5 端到端：带包装说明建档 → 库里 package_note 有值', (
    WidgetTester tester,
  ) async {
    await openForm(tester);

    await tester.enterText(field(label: '商品名称'), '娃哈哈矿泉水');
    await tester.enterText(unitField, '瓶');
    await tester.enterText(field(label: '售价'), '2.00');
    await tester.enterText(field(label: '包装说明（可选）'), '1 箱 = 48 瓶');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final Product saved = service.list().single;
    expect(saved.name, '娃哈哈矿泉水');
    expect(saved.unit, '瓶');
    expect(saved.packageNote, '1 箱 = 48 瓶');
  });
}
