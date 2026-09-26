/// 商品建档的降级门禁（对应 `test/product_service_test.dart`）。
///
/// ⚠️ **改一边必须改另一边** —— `test/**` 是正式门禁，本脚本是
/// 「跑不了 `dart test` 时的降级门禁」（`docs/testing.md` §零）。
///
/// 运行：`dart run tool/selfcheck_products.dart`
library;

import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $name');
  } else {
    _fail++;
    _failures.add(name);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  →  $detail'}');
  }
}

void section(String title) => stdout.writeln('\n── $title ──');

void main() {
  useLocalSqlite();

  int clock = 1700000000000;
  int now() => clock++;

  ProductDraft goodDraft({
    String name = '红富士苹果',
    String unit = '斤',
    String sellPrice = '5.00',
    String costPrice = '3.20',
    String barcode = '6901234567890',
    String safetyStock = '10',
  }) => ProductDraft(
    name: name,
    unit: unit,
    sellPrice: sellPrice,
    costPrice: costPrice,
    barcode: barcode,
    safetyStock: safetyStock,
  );

  // ============================================================ 金额解析
  section('金额输入解析（Money.tryParseYuan）');
  check('整数 / 一位 / 两位小数',
      Money.tryParseYuan('12') == 1200 &&
          Money.tryParseYuan('12.3') == 1230 &&
          Money.tryParseYuan('12.34') == 1234);
  check('省略整数位 / 前后空格 / 零',
      Money.tryParseYuan('.5') == 50 &&
          Money.tryParseYuan(' 12.50 ') == 1250 &&
          Money.tryParseYuan('0') == 0);
  check('符号保留（负数由业务校验拦）',
      Money.tryParseYuan('-1') == -100 &&
          Money.tryParseYuan('+1.5') == 150 &&
          Money.tryParseYuan('-0.01') == -1);
  check('1.005 直接拒绝（不走 double 的二进制误差）',
      Money.tryParseYuan('1.005') == null);
  check('非法输入一律 null',
      Money.tryParseYuan('') == null &&
          Money.tryParseYuan('   ') == null &&
          Money.tryParseYuan('abc') == null &&
          Money.tryParseYuan('1.2.3') == null &&
          Money.tryParseYuan('.') == null &&
          Money.tryParseYuan('1,2') == null &&
          Money.tryParseYuan('１２') == null &&
          Money.tryParseYuan('-') == null);
  check('位数过长 → null（防溢出）',
      Money.tryParseYuan('9' * 16) == null && Money.tryParseYuan('9' * 15) != null);

  // ============================================================ 表单校验
  section('ProductDraft 校验');
  check('合法草稿 → 无错误', goodDraft().validate().isEmpty && goodDraft().isValid);
  check('名称必填（空 / 全空格都拦）',
      (goodDraft(name: '').validate()[ProductField.name] ?? '').contains('请填商品名称') &&
          (goodDraft(name: '   ').validate()[ProductField.name] ?? '')
              .contains('请填商品名称'));
  check('名称超长 → 提示删到 60 字以内',
      (goodDraft(name: '果' * 61).validate()[ProductField.name] ?? '')
              .contains('${ProductDraft.maxNameLength}') &&
          goodDraft(name: '果' * 60).validate().isEmpty);
  check('单位必填',
      (goodDraft(unit: ' ').validate()[ProductField.unit] ?? '').contains('请填单位'));
  check('售价必填 / 不能负 / 只能是数字',
      goodDraft(sellPrice: '').validate()[ProductField.sellPrice] == '请填售价' &&
          (goodDraft(sellPrice: '-1').validate()[ProductField.sellPrice] ?? '')
              .contains('不能是负数') &&
          (goodDraft(sellPrice: 'abc').validate()[ProductField.sellPrice] ?? '')
              .contains('只能填数字'));
  check('进价可空，不合法要报',
      goodDraft(costPrice: '').validate().isEmpty &&
          (goodDraft(costPrice: 'xyz').validate()[ProductField.costPrice] ?? '')
              .contains('只能填数字') &&
          (goodDraft(costPrice: '-0.01').validate()[ProductField.costPrice] ?? '')
              .contains('不能是负数'));
  check('安全库存可空 / 只收整数 / 不能负',
      goodDraft(safetyStock: '').validate().isEmpty &&
          (goodDraft(safetyStock: '1.5').validate()[ProductField.safetyStock] ?? '')
              .contains('只能填整数') &&
          (goodDraft(safetyStock: '-1').validate()[ProductField.safetyStock] ?? '')
              .contains('不能是负数') &&
          goodDraft(safetyStock: '0').validate().isEmpty);
  check('条码可空 / 过长要报',
      goodDraft(barcode: '').validate().isEmpty &&
          (goodDraft(barcode: '1' * 65).validate()[ProductField.barcode] ?? '')
              .contains('条码太长') &&
          goodDraft(barcode: '1' * 64).validate().isEmpty);
  check('一次能报多个字段（界面标红多栏）', () {
    final Map<ProductField, String> errors = const ProductDraft().validate();
    return errors.containsKey(ProductField.name) &&
        errors.containsKey(ProductField.sellPrice) &&
        !errors.containsKey(ProductField.unit);
  }());
  check('空条码归一成 null（不是空串）',
      goodDraft(barcode: '  ').normalizedBarcode == null &&
          goodDraft(barcode: ' 6901 ').normalizedBarcode == '6901');
  check('取值：元原文 → 分 / 整数', () {
    final ProductDraft d =
        goodDraft(sellPrice: '12.5', costPrice: '3', safetyStock: '7');
    return d.sellPriceCents == 1250 &&
        d.costPriceCents == 300 &&
        d.safetyStockValue == 7 &&
        d.normalizedName == '红富士苹果' &&
        d.normalizedUnit == '斤';
  }());

  // ============================================================ 建档
  section('ProductService.create');
  {
    final Db db = Db.openInMemory();
    final ProductService service = ProductService(db);

    check('编码从 P0001 起、逐条递增',
        service.create(goodDraft(name: '甲'), now: now()).code == 'P0001' &&
            service.create(goodDraft(name: '乙'), now: now()).code == 'P0002' &&
            service.create(goodDraft(name: '丙'), now: now()).code == 'P0003');

    final Product one = service.create(goodDraft(), now: 1700000000000);
    check('补上表单没有的列',
        one.id.length > 20 &&
            one.id[14] == '7' &&
            one.createdAt == 1700000000000 &&
            one.updatedAt == 1700000000000 &&
            one.syncVersion == 0 &&
            one.isActive &&
            one.category == null &&
            one.remark == null);

    final Product six = service.create(
      goodDraft(
        name: '可口可乐',
        unit: '瓶',
        sellPrice: '3.5',
        costPrice: '2.25',
        barcode: '6901234567890',
        safetyStock: '24',
      ),
      now: now(),
    );
    final Product? sixLoaded = service.byId(six.id);
    check('6 个字段都落库（含金额转分）',
        sixLoaded != null &&
            sixLoaded.name == '可口可乐' &&
            sixLoaded.unit == '瓶' &&
            sixLoaded.sellPrice == 350 &&
            sixLoaded.costPrice == 225 &&
            sixLoaded.barcode == '6901234567890' &&
            sixLoaded.safetyStock == 24);

    final Product noBarcode =
        service.create(goodDraft(barcode: '   '), now: now());
    check('没有条码 → 库里是 NULL 而不是空串',
        db.raw
                .select('SELECT barcode FROM products WHERE id = ?',
                    <Object?>[noBarcode.id])
                .first['barcode'] ==
            null);

    Object? thrown;
    try {
      service.create(goodDraft(name: ''), now: now());
    } catch (error) {
      thrown = error;
    }
    check('校验不过 → 抛 ProductDraftInvalid（带字段级原因）',
        thrown is ProductDraftInvalid &&
            thrown.errors.containsKey(ProductField.name));

    final int countBefore = (db.raw
            .select('SELECT COUNT(*) AS n FROM products')
            .first['n']! as int);
    try {
      service.create(const ProductDraft(), now: now());
    } catch (_) {
      // 预期抛出
    }
    final int countAfter = (db.raw
            .select('SELECT COUNT(*) AS n FROM products')
            .first['n']! as int);
    check('校验不过时库里不留半条记录（事务回滚）', countBefore == countAfter);
    check('建档后事务不残留', !db.inTransaction);
    db.close();

    // ---- 编码位数边界（**关键回归守卫**）----
    final Db db2 = Db.openInMemory();
    final ProductService s2 = ProductService(db2);
    Product seed2(String code) {
      final int t = now();
      final Product product = Product(
        id: newId(),
        code: code,
        name: '占位-$code',
        createdAt: t,
        updatedAt: t,
      );
      ProductDao(db2).insert(product);
      return product;
    }

    seed2('P9999');
    check('P9999 → P10000', s2.create(goodDraft(), now: now()).code == 'P10000');
    seed2('P0001');
    seed2('ABC-001');
    check('混入自定义编码不干扰生成（只认 P 前缀）',
        s2.create(goodDraft(), now: now()).code == 'P10001');
    db2.close();

    final Db db3 = Db.openInMemory();
    Object? outside;
    try {
      ProductCodeGenerator(db3).next();
    } catch (error) {
      outside = error;
    }
    check('事务外调用编码生成器 → StateError', outside is StateError);
    db3.close();

    // ---- 编辑 / 停用 / 列表 ----
    final Db db4 = Db.openInMemory();
    final ProductService s4 = ProductService(db4);
    final Product before = s4.create(goodDraft(), now: 1000);
    db4.raw.execute(
      'UPDATE products SET category = ?, remark = ? WHERE id = ?',
      <Object?>['水果', '常卖品', before.id],
    );

    final Product after =
        s4.update(before.id, goodDraft(name: '红富士苹果（大）'), now: 2000);
    check('编辑：保留 id / code / created_at',
        after.id == before.id &&
            after.code == before.code &&
            after.createdAt == 1000 &&
            after.updatedAt == 2000 &&
            after.syncVersion == before.syncVersion + 1 &&
            after.name == '红富士苹果（大）');
    check('编辑：表单没有的列保持原值（不抹掉分类与备注）',
        after.category == '水果' && after.remark == '常卖品' && after.isActive);

    Object? invalidUpdate;
    try {
      s4.update(before.id, goodDraft(sellPrice: ''), now: 3000);
    } catch (error) {
      invalidUpdate = error;
    }
    final Product reloaded = s4.byId(before.id)!;
    // ⚠️ 对齐的是**最近一次成功更新后**的状态（`after`），不是最初建档时的
    // `before` —— 自检里跨段复用同一个对象时，拿「入参快照」比会假失败。
    check('编辑校验不过 → 抛，且库里原值不变',
        invalidUpdate is ProductDraftInvalid &&
            reloaded.sellPrice == after.sellPrice &&
            reloaded.syncVersion == after.syncVersion &&
            reloaded.updatedAt == after.updatedAt);
    check('编辑不存在的 id → StateError', () {
      try {
        s4.update('不存在的 id', goodDraft(), now: 4000);
        return false;
      } on StateError {
        return true;
      }
    }());

    s4.setActive(before.id, false, now: 5000);
    final Product deactivated = s4.byId(before.id)!;
    check('停用是软删：行还在，is_active = 0，版本 +1',
        deactivated.isActive == false &&
            deactivated.syncVersion == after.syncVersion + 1 &&
            deactivated.updatedAt == 5000);
    s4.setActive(before.id, true, now: 6000);
    check('恢复启用', s4.byId(before.id)!.isActive);
    check('停用/恢复不存在的 id → StateError', () {
      try {
        s4.setActive('不存在的 id', false, now: 7000);
        return false;
      } on StateError {
        return true;
      }
    }());

    final Product b = s4.create(goodDraft(name: '娃哈哈水', barcode: '690222'), now: 7000);
    s4.setActive(before.id, false, now: 8000);
    check('列表默认只看启用中的',
        s4.list().map((Product p) => p.name).join(',') == '娃哈哈水' &&
            s4.list(active: false).map((Product p) => p.name).join(',') ==
                '红富士苹果（大）' &&
            s4.list(active: null).length == 2);
    check('列表按建档顺序（不是编码字典序）',
        s4.list(active: null).map((Product p) => p.createdAt).toList().join(',') ==
            '${before.createdAt},${b.createdAt}');
    check('query 命中名称 / 编码 / 条码',
        s4.list(query: '娃哈哈').single.id == b.id &&
            s4.list(query: '690222').single.id == b.id &&
            s4.list(query: b.code).single.id == b.id &&
            s4.list(query: '查不到').isEmpty);
    check('barcodeOwners 命中 / 去空格 / 未命中 / 空串',
        s4.barcodeOwners('690222').single.id == b.id &&
            s4.barcodeOwners(' 690222 ').single.id == b.id &&
            s4.barcodeOwners('不存在').isEmpty &&
            s4.barcodeOwners('').isEmpty);
    // before 此刻已被停用（now: 8000），条码归属仍应算它 ——
    // 过滤掉 is_active 会让用户以为条码凭空消失
    check('停用的商品也算条码归属',
        s4.barcodeOwners('6901234567890').single.id == before.id);
    db4.close();

    // ---- 条码重复（R-15 裁定）----
    // 单独开一个库：自检是一个长脚本，对象跨段复用会让断言莫名其妙地互相影响
    final Db db5 = Db.openInMemory();
    final ProductService s5 = ProductService(db5);
    final Product first = s5.create(
      goodDraft(name: '娃哈哈矿泉水 550ml'),
      now: 1000,
    );
    final Product second = s5.create(
      goodDraft(name: '娃哈哈矿泉水 550ml（新批次）', sellPrice: '2.50'),
      now: 2000,
    );

    check('条码重复：两条都返回，按建档顺序（不静默取最早一条）',
        s5.barcodeOwners('6901234567890').map((Product p) => p.id).join(',') ==
            '${first.id},${second.id}');
    check('barcodeOwners 去空格 / 未命中 / 空串',
        s5.barcodeOwners(' 6901234567890 ').length == 2 &&
            s5.barcodeOwners('查不到').isEmpty &&
            s5.barcodeOwners('').isEmpty);
    check('excludeId 排除自己（编辑时不提示「自己和自己重复」）',
        s5.barcodeOwners('6901234567890', excludeId: first.id).single.id ==
                second.id &&
            s5
                    .barcodeOwners('6901234567890', excludeId: '匹配不上任何 id')
                    .length ==
                2);
    check('建档 / 编辑都不因条码重复而失败（允许重复）', () {
      try {
        s5.update(second.id, goodDraft(name: '娃哈哈矿泉水（改名）'), now: 3000);
        return s5.byId(second.id)!.name == '娃哈哈矿泉水（改名）';
      } catch (_) {
        return false;
      }
    }());

    check('barcodeNotice：没人用过 → null',
        ProductDraft.barcodeNotice(const <Product>[]) == null);
    check('barcodeNotice：一条占用 → 用商品名 + 说清保存后会发生什么',
        ProductDraft.barcodeNotice(<Product>[first]) ==
            '⚠️ 这个条码已经给「娃哈哈矿泉水 550ml」用过了。\n'
            '保存后扫码会显示两条商品供选择。');
    check('barcodeNotice：两条占用 → 名字都列出来',
        ProductDraft.barcodeNotice(<Product>[first, second]) ==
            '⚠️ 这个条码已经给「娃哈哈矿泉水 550ml」「娃哈哈矿泉水 550ml（新批次）」用过了。\n'
            '保存后扫码会显示三条商品供选择。');
    check('barcodeNotice 不含商品编码（用户认名字不认编号）',
        !(ProductDraft.barcodeNotice(<Product>[first]) ?? '')
            .contains(first.code));

    s5.setActive(second.id, false, now: 4000);
    check('停用的商品也算条码归属', s5.barcodeOwners('6901234567890').length == 2);

    s5.create(goodDraft(name: '娃哈哈矿泉水 550ml（第三批）'), now: 5000);
    check('barcodeNotice：3 条以上 → 「等 N 种商品」',
        ProductDraft.barcodeNotice(s5.barcodeOwners('6901234567890')) ==
            '⚠️ 这个条码已经给「娃哈哈矿泉水 550ml」等 3 种商品用过了。\n'
            '保存后扫码会显示四条商品供选择。');

    for (int i = 0; i < 7; i++) {
      s5.create(goodDraft(name: '占位$i'), now: 6000 + i);
    }
    check('barcodeNotice：超过 9 条退回阿拉伯数字',
        (ProductDraft.barcodeNotice(s5.barcodeOwners('6901234567890')) ?? '')
            .contains('11条商品'));
    db5.close();
  }

  // ============================================================ 收尾
  stdout.writeln('\n${'=' * 46}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  if (_failures.isNotEmpty) {
    stdout.writeln('失败清单：');
    for (final String name in _failures) {
      stdout.writeln('  - $name');
    }
  }
  stdout.writeln('=' * 46);
  exit(_fail == 0 ? 0 : 1);
}
