// 商品建档（`docs/reply.md` 裁定的 6 个字段），对应 `docs/testing.md`。
//
// 覆盖：金额输入解析 / 表单校验 / 建档 / 编辑 / 停用恢复 / 列表与条码查询 /
// 编码递增的位数边界。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；Windows 需要可用的 SQLite 原生库。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);
  setUp(resetClock);

  late Db db;
  late ProductService service;

  setUp(() {
    db = newMemoryDb();
    service = ProductService(db);
  });

  tearDown(() => db.close());

  /// 一个能通过校验的草稿
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

  /// 直接把一条商品塞进库里（用于构造编码边界等前置状态）
  void seedProduct(String code) {
    final int t = now();
    ProductDao(db).insert(
      Product(
        id: newId(),
        code: code,
        name: '占位-$code',
        createdAt: t,
        updatedAt: t,
      ),
    );
  }

  // ============================================================ 金额解析
  group('金额输入解析（Money.tryParseYuan）', () {
    test('整数 / 一位小数 / 两位小数', () {
      expect(Money.tryParseYuan('12'), 1200);
      expect(Money.tryParseYuan('12.3'), 1230);
      expect(Money.tryParseYuan('12.34'), 1234);
    });

    test('省略整数位与前后空格', () {
      expect(Money.tryParseYuan('.5'), 50);
      expect(Money.tryParseYuan(' 12.50 '), 1250);
      expect(Money.tryParseYuan('0'), 0);
    });

    test('符号保留 —— 「不能为负」是业务校验，不是解析的事', () {
      expect(Money.tryParseYuan('-1'), -100);
      expect(Money.tryParseYuan('+1.5'), 150);
      expect(Money.tryParseYuan('-0.01'), -1);
    });

    test('不走 double：1.005 直接拒绝（而不是舍成 100 或 101）', () {
      // 若实现用 `double.parse(x) * 100`，这里会得到 100（二进制误差）
      expect(Money.tryParseYuan('1.005'), isNull);
    });

    test('非法输入一律 null', () {
      expect(Money.tryParseYuan(''), isNull);
      expect(Money.tryParseYuan('   '), isNull);
      expect(Money.tryParseYuan('abc'), isNull);
      expect(Money.tryParseYuan('1.2.3'), isNull);
      expect(Money.tryParseYuan('.'), isNull);
      expect(Money.tryParseYuan('1,2'), isNull);
      expect(Money.tryParseYuan('１２'), isNull, reason: '全角数字不认');
      expect(Money.tryParseYuan('-'), isNull);
    });

    test('位数过长 → null（防 int.parse 溢出）', () {
      expect(Money.tryParseYuan('9' * 16), isNull);
      expect(Money.tryParseYuan('9' * 15), isNotNull);
    });
  });

  // ============================================================ 表单校验
  group('ProductDraft 校验', () {
    test('合法草稿 → 无错误', () {
      expect(goodDraft().validate(), isEmpty);
      expect(goodDraft().isValid, isTrue);
    });

    test('名称必填：空 / 全空格都拦', () {
      expect(
        goodDraft(name: '').validate()[ProductField.name],
        contains('请填商品名称'),
      );
      expect(
        goodDraft(name: '   ').validate()[ProductField.name],
        contains('请填商品名称'),
      );
    });

    test('名称超长 → 提示删到 60 字以内', () {
      final ProductDraft draft = goodDraft(name: '果' * 61);
      expect(
        draft.validate()[ProductField.name],
        contains('$ProductDraft.maxNameLength'),
      );
      expect(goodDraft(name: '果' * 60).validate(), isEmpty);
    });

    test('单位必填', () {
      expect(
        goodDraft(unit: ' ').validate()[ProductField.unit],
        contains('请填单位'),
      );
    });

    test('售价必填且不能为负', () {
      expect(
        goodDraft(sellPrice: '').validate()[ProductField.sellPrice],
        '请填售价',
      );
      expect(
        goodDraft(sellPrice: '-1').validate()[ProductField.sellPrice],
        contains('不能是负数'),
      );
      expect(
        goodDraft(sellPrice: 'abc').validate()[ProductField.sellPrice],
        contains('只能填数字'),
      );
    });

    test('进价可空（空 = 0），但不合法要报', () {
      expect(goodDraft(costPrice: '').validate(), isEmpty);
      expect(
        goodDraft(costPrice: 'xyz').validate()[ProductField.costPrice],
        contains('只能填数字'),
      );
      expect(
        goodDraft(costPrice: '-0.01').validate()[ProductField.costPrice],
        contains('不能是负数'),
      );
    });

    test('安全库存可空（空 = 0），只收整数且不能为负', () {
      expect(goodDraft(safetyStock: '').validate(), isEmpty);
      expect(
        goodDraft(safetyStock: '1.5').validate()[ProductField.safetyStock],
        contains('只能填整数'),
      );
      expect(
        goodDraft(safetyStock: '-1').validate()[ProductField.safetyStock],
        contains('不能是负数'),
      );
      expect(goodDraft(safetyStock: '0').validate(), isEmpty);
    });

    test('条码可空；过长要报（防止误贴一整段内容）', () {
      expect(goodDraft(barcode: '').validate(), isEmpty);
      expect(
        goodDraft(barcode: '1' * 65).validate()[ProductField.barcode],
        contains('条码太长'),
      );
      expect(goodDraft(barcode: '1' * 64).validate(), isEmpty);
    });

    test('一次能报多个字段（界面据此标红多栏）', () {
      final Map<ProductField, String> errors =
          const ProductDraft().validate(); // 除了单位默认「件」，其余全空
      expect(errors.keys, contains(ProductField.name));
      expect(errors.keys, contains(ProductField.sellPrice));
      expect(errors, isNot(contains(ProductField.unit)));
    });

    test('空条码归一成 null，不是空串', () {
      expect(goodDraft(barcode: '  ').normalizedBarcode, isNull);
      expect(goodDraft(barcode: ' 6901 ').normalizedBarcode, '6901');
    });

    test('取值：元原文 → 分 / 整数', () {
      final ProductDraft draft = goodDraft(
        sellPrice: '12.5',
        costPrice: '3',
        safetyStock: '7',
      );
      expect(draft.sellPriceCents, 1250);
      expect(draft.costPriceCents, 300);
      expect(draft.safetyStockValue, 7);
      expect(draft.normalizedName, '红富士苹果');
      expect(draft.normalizedUnit, '斤');
    });
  });

  // ============================================================ 回填
  group('ProductDraft.of 回填（编辑）', () {
    test('回填后校验通过，且取值与原商品一致', () {
      final Product created = service.create(goodDraft(), now: 1000);

      final ProductDraft draft = ProductDraft.of(created);
      expect(draft.validate(), isEmpty);
      expect(draft.normalizedName, created.name);
      expect(draft.normalizedUnit, created.unit);
      expect(draft.sellPriceCents, created.sellPrice);
      expect(draft.costPriceCents, created.costPrice);
      expect(draft.safetyStockValue, created.safetyStock);
      expect(draft.normalizedBarcode, created.barcode);
    });
  });

  // ============================================================ 建档
  group('ProductService.create', () {
    test('编码从 P0001 起、逐条递增', () {
      expect(service.create(goodDraft(name: '甲'), now: 1000).code, 'P0001');
      expect(service.create(goodDraft(name: '乙'), now: 1001).code, 'P0002');
      expect(service.create(goodDraft(name: '丙'), now: 1002).code, 'P0003');
    });

    test('补上表单没有的列：id / 时间戳 / sync_version / is_active', () {
      final Product product = service.create(goodDraft(), now: 1700000000000);

      expect(product.id.length, greaterThan(20));
      expect(product.id[14], '7', reason: 'UUIDv7 的版本位');
      expect(product.createdAt, 1700000000000);
      expect(product.updatedAt, 1700000000000);
      expect(product.syncVersion, 0);
      expect(product.isActive, isTrue);
      expect(product.category, isNull);
      expect(product.remark, isNull);
    });

    test('6 个字段都落库（含金额转分）', () {
      final Product product = service.create(
        goodDraft(
          name: '可口可乐',
          unit: '瓶',
          sellPrice: '3.5',
          costPrice: '2.25',
          barcode: '6901234567890',
          safetyStock: '24',
        ),
        now: 1000,
      );

      final Product? loaded = service.byId(product.id);
      expect(loaded, isNotNull);
      expect(loaded!.name, '可口可乐');
      expect(loaded.unit, '瓶');
      expect(loaded.sellPrice, 350);
      expect(loaded.costPrice, 225);
      expect(loaded.barcode, '6901234567890');
      expect(loaded.safetyStock, 24);
    });

    test('没有条码 → 库里是 NULL 而不是空串', () {
      final Product product = service.create(
        goodDraft(barcode: '   '),
        now: 1000,
      );
      final Object? raw = db.raw
          .select(
            'SELECT barcode FROM products WHERE id = ?',
            <Object?>[product.id],
          )
          .first['barcode'];
      expect(raw, isNull);
    });

    test('校验不过 → 抛 ProductDraftInvalid，且**库里一条都没有**', () {
      Object? thrown;
      try {
        service.create(goodDraft(name: ''), now: 1000);
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<ProductDraftInvalid>());
      expect(
        (thrown! as ProductDraftInvalid).errors.keys,
        contains(ProductField.name),
        reason: '异常必须带字段级原因，界面才能标红对应栏',
      );
      expect(service.list(active: null), isEmpty, reason: '事务回滚，不留半条记录');
    });

    test('建档后事务不残留', () {
      service.create(goodDraft(), now: 1000);
      expect(db.inTransaction, isFalse);
    });
  });

  // ============================================================ 编码边界
  group('商品编码递增的位数边界', () {
    test('P9999 → P10000', () {
      // 生成器只看「当前最大」，所以只要把 P9999 放进库就够 ——
      // 不必真的插 9999 行
      seedProduct('P9999');
      expect(service.create(goodDraft(), now: 1000).code, 'P10000');
    });

    test('已有 P10000 → P10001（**这条会失败在「只按 code DESC 排序」的实现上**）', () {
      seedProduct('P9999');
      seedProduct('P10000');

      // 只按 `code DESC` 时 'P9999' > 'P10000'，会取回 P9999 ⇒ 算出 P10000 ⇒ 撞 UNIQUE
      expect(service.create(goodDraft(), now: 1000).code, 'P10001');
    });

    test('混入用户自定义编码（非 P 前缀）不干扰生成', () {
      seedProduct('ABC-001');
      seedProduct('P0007');
      expect(service.create(goodDraft(), now: 1000).code, 'P0008');
    });

    test('事务外调用编码生成器 → StateError', () {
      expect(() => ProductCodeGenerator(db).next(), throwsStateError);
    });
  });

  // ============================================================ 编辑
  group('ProductService.update', () {
    test('保留 id / code / created_at，sync_version +1，updated_at 更新', () {
      final Product before = service.create(goodDraft(), now: 1000);

      final Product after = service.update(
        before.id,
        goodDraft(name: '红富士苹果（大）'),
        now: 2000,
      );

      expect(after.id, before.id);
      expect(after.code, before.code, reason: '编码由系统生成，编辑不该改它');
      expect(after.createdAt, 1000, reason: '建档时间是事实');
      expect(after.updatedAt, 2000);
      expect(after.syncVersion, before.syncVersion + 1);
      expect(after.name, '红富士苹果（大）');
    });

    test('表单没有的列保持原值（否则编辑名称会抹掉分类与备注）', () {
      final Product created = service.create(goodDraft(), now: 1000);
      db.raw.execute(
        'UPDATE products SET category = ?, remark = ? WHERE id = ?',
        <Object?>['水果', '常卖品', created.id],
      );

      final Product after = service.update(
        created.id,
        goodDraft(name: '新名字'),
        now: 2000,
      );

      expect(after.category, '水果');
      expect(after.remark, '常卖品');
      expect(after.isActive, isTrue);
    });

    test('校验不过 → 抛，且库里原值不变', () {
      final Product before = service.create(goodDraft(), now: 1000);

      expect(
        () => service.update(before.id, goodDraft(sellPrice: ''), now: 2000),
        throwsA(isA<ProductDraftInvalid>()),
      );

      final Product reloaded = service.byId(before.id)!;
      expect(reloaded.sellPrice, before.sellPrice);
      expect(reloaded.name, before.name);
      expect(reloaded.syncVersion, before.syncVersion, reason: '失败不该动版本号');
      expect(reloaded.updatedAt, before.updatedAt);
    });

    test('id 不存在 → StateError', () {
      expect(
        () => service.update('不存在的 id', goodDraft(), now: 2000),
        throwsStateError,
      );
    });
  });

  // ============================================================ 停用 / 恢复
  group('ProductService.setActive', () {
    test('停用是软删：行还在，is_active = 0，版本 +1', () {
      final Product product = service.create(goodDraft(), now: 1000);

      service.setActive(product.id, false, now: 2000);

      final Product? loaded = service.byId(product.id);
      expect(loaded, isNotNull, reason: '软删 —— 历史单据还引用着它');
      expect(loaded!.isActive, isFalse);
      expect(loaded.syncVersion, product.syncVersion + 1);
      expect(loaded.updatedAt, 2000);
    });

    test('恢复启用', () {
      final Product product = service.create(goodDraft(), now: 1000);
      service.setActive(product.id, false, now: 2000);
      service.setActive(product.id, true, now: 3000);

      final Product loaded = service.byId(product.id)!;
      expect(loaded.isActive, isTrue);
      expect(loaded.syncVersion, product.syncVersion + 2);
    });

    test('id 不存在 → StateError', () {
      expect(
        () => service.setActive('不存在的 id', false, now: 2000),
        throwsStateError,
      );
    });
  });

  // ============================================================ 列表与查询
  group('ProductService.list', () {
    test('默认只看启用中的', () {
      final Product a = service.create(goodDraft(name: '甲'), now: 1000);
      service.create(goodDraft(name: '乙'), now: 1001);
      service.setActive(a.id, false, now: 2000);

      expect(service.list().map((Product p) => p.name), <String>['乙']);
      expect(
        service.list(active: false).map((Product p) => p.name),
        <String>['甲'],
      );
      expect(service.list(active: null).length, 2);
    });

    test('按建档顺序返回（不是按编码字典序）', () {
      service.create(goodDraft(name: '先'), now: 1000);
      service.create(goodDraft(name: '后'), now: 1001);

      expect(
        service.list().map((Product p) => p.name),
        <String>['先', '后'],
      );
    });

    test('query 命中名称 / 编码 / 条码', () {
      service.create(
        goodDraft(name: '红富士苹果', barcode: '690111'),
        now: 1000,
      );
      service.create(goodDraft(name: '娃哈哈水', barcode: '690222'), now: 1001);

      expect(service.list(query: '富士').single.name, '红富士苹果');
      expect(service.list(query: '690222').single.name, '娃哈哈水');
      expect(service.list(query: 'P0001').single.name, '红富士苹果');
      expect(service.list(query: '查不到'), isEmpty);
    });
  });

  group('ProductService.byBarcode', () {
    test('命中 / 未命中 / 空串', () {
      service.create(goodDraft(barcode: '6901234567890'), now: 1000);

      expect(service.byBarcode('6901234567890')!.name, '红富士苹果');
      expect(service.byBarcode(' 6901234567890 '), isNotNull, reason: '去掉空格');
      expect(service.byBarcode('不存在'), isNull);
      expect(service.byBarcode(''), isNull);
    });
  });
}
