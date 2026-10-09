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
    String packageNote = '',
    String packageUnit = '',
    String packageSize = '',
  }) => ProductDraft(
    name: name,
    unit: unit,
    sellPrice: sellPrice,
    costPrice: costPrice,
    barcode: barcode,
    safetyStock: safetyStock,
    packageNote: packageNote,
    packageUnit: packageUnit,
    packageSize: packageSize,
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
      // ⚠️ 必须写 `${...}`：`'$ProductDraft.maxNameLength'` 会被解析成
      // 「类型 `ProductDraft` 的 toString + 字面量 `.maxNameLength`」，
      // 等于断言了一个不存在的字符串（`docs/testing.md` §零）。
      expect(
        draft.validate()[ProductField.name],
        contains('${ProductDraft.maxNameLength}'),
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

    test('包装说明可空；超长要报（60 上限，防误粘一整段话）（§AJ·AI-5）', () {
      expect(goodDraft(packageNote: '').validate(), isEmpty);
      expect(goodDraft(packageNote: '  ').validate(), isEmpty);
      expect(
        goodDraft(packageNote: '长' * 61).validate()[ProductField.packageNote],
        contains('包装说明太长'),
      );
      expect(goodDraft(packageNote: '长' * 60).validate(), isEmpty);
    });

    test('包装说明空白归一成 null，不是空串（与条码同理）', () {
      expect(goodDraft(packageNote: '  ').normalizedPackageNote, isNull);
      expect(
        goodDraft(packageNote: ' 1 箱 = 48 瓶 ').normalizedPackageNote,
        '1 箱 = 48 瓶',
      );
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

    test('包装说明回填：null → 空串（TextField 的 text 不能是 null）', () {
      final Product withNote = service.create(
        goodDraft(packageNote: '1 箱 = 48 瓶'),
        now: 1000,
      );
      final Product withoutNote = service.create(
        goodDraft(name: '无备注货'),
        now: 1001,
      );

      expect(ProductDraft.of(withNote).packageNote, '1 箱 = 48 瓶');
      expect(ProductDraft.of(withoutNote).packageNote, '');
      expect(ProductDraft.of(withoutNote).normalizedPackageNote, isNull);
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
      expect(product.packageNote, isNull, reason: '没填包装说明 → 不存空串');
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

    test('包装说明落库：原样存，能读回（§AJ·AI-5）', () {
      final Product product = service.create(
        goodDraft(packageNote: '1 箱 = 48 瓶'),
        now: 1000,
      );

      final Product? loaded = service.byId(product.id);
      expect(loaded, isNotNull);
      expect(loaded!.packageNote, '1 箱 = 48 瓶');
    });

    test('包装说明空白 → 库里是 NULL 而不是空串（与条码同理）', () {
      final Product product = service.create(
        goodDraft(packageNote: '   '),
        now: 1000,
      );
      final Object? raw = db.raw
          .select(
            'SELECT package_note FROM products WHERE id = ?',
            <Object?>[product.id],
          )
          .first['package_note'];
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

  // ============================================================ 编码改派（D1）
  //
  // 手机离线建档按**自己镜像**的 max(code)+1 生成编码（reply_review.md §CH
  // 提案 A §3）—— 主机这边可能已经被别的商品占用了。判定只有一处：
  // `ProductService.resolvePreferredCode`（reply.md 裁定 §二②）。
  group('resolvePreferredCode（D1：客户端建议的编码，主机说了算）', () {
    test('没建议（null / 空白）⇒ 主机自增（桌面建档走这条，行为不变）', () {
      expect(
        db.transaction<String>(() => service.resolvePreferredCode(null)),
        'P0001',
      );
      db.transaction<void>(() {
        final String blank = service.resolvePreferredCode('   ');
        expect(blank, 'P0001', reason: '空白 = 没建议');
      });
    });

    test('建议的编码**可用** ⇒ 原样采用（手机显示什么就是什么）', () {
      expect(
        db.transaction<String>(() => service.resolvePreferredCode('P0042')),
        'P0042',
      );
    });

    test('建议的编码**被占用** ⇒ 主机改派（顺延自增）', () {
      seedProduct('P0042');
      final String assigned = db.transaction<String>(
        () => service.resolvePreferredCode('P0042'),
      );
      expect(assigned, isNot('P0042'), reason: '占用了就要改派');
      expect(assigned, 'P0043', reason: '改派顺延自增');
    });

    test('改派只「算」不「写」：同一输入同结果（落库由 create 负责）', () {
      seedProduct('P0007');
      final String a = db.transaction<String>(
        () => service.resolvePreferredCode('P0007'),
      );
      final String b = db.transaction<String>(
        () => service.resolvePreferredCode('P0007'),
      );
      expect(a, 'P0008', reason: '库里只有 P0007 ⇒ 顺延 P0008（生成器取 max+1，**不补空档**）');
      expect(b, a, reason: 'resolve 不插行 ⇒ 第二次仍是同一个结果');
      expect(a, isNot('P0007'));
    });

    test('非法编码（非 ^P\\d+\$）⇒ **视同未提供**，走自增（§CV·七 温和收紧）', () {
      // 收紧前 `ABC-001` 会被**原样采用** —— 那会让 `products.code` 掺进解析不了的
      // 文本，此后任何自增路径都抛 StateError（不可自愈）。现在一律视同没建议。
      expect(
        db.transaction<String>(() => service.resolvePreferredCode('ABC-001')),
        'P0001',
        reason: '非 P 前缀 ⇒ 视同未提供',
      );
      expect(
        db.transaction<String>(() => service.resolvePreferredCode('PU1')),
        'P0001',
        reason: 'P 前缀但非数字 —— 正是会把生成器搞坏的那类（latestCode 的 LIKE P% 放它进来）',
      );
      expect(
        db.transaction<String>(() => service.resolvePreferredCode('P12x')),
        'P0001',
        reason: '数字里混字母 ⇒ 同样视同未提供',
      );
    });
  });

  group('create(preferredCode:)（D1：同步建档的入口）', () {
    test('不传 preferredCode ⇒ 与以前完全一致（自增 P0001）', () {
      expect(service.create(goodDraft(), now: 1000).code, 'P0001');
    });

    test('preferredCode 可用 ⇒ 落库就是这个编码', () {
      final Product created = service.create(
        goodDraft(),
        now: 1000,
        preferredCode: 'P0500',
      );
      expect(created.code, 'P0500');
      expect(ProductDao(db).findById(created.id)!.code, 'P0500');
    });

    test('preferredCode 被占用 ⇒ 落库的是**改派后**的编码（不是请求的那个）', () {
      seedProduct('P0500');
      final Product created = service.create(
        goodDraft(),
        now: 1000,
        preferredCode: 'P0500',
      );
      expect(created.code, isNot('P0500'));
      expect(ProductDao(db).findById(created.id)!.code, created.code);
      // 原占用者不受影响
      expect(
        db.raw
            .select("SELECT code FROM products WHERE name = '占位-P0500'")
            .first['code'],
        'P0500',
      );
    });

    test('改派与落库同事务：不会被中间插入撞号（P0001 被占 ⇒ P0002）', () {
      seedProduct('P0001');
      final Product created = service.create(
        goodDraft(),
        now: 1000,
        preferredCode: 'P0001',
      );
      expect(created.code, 'P0002');
      expect(db.inTransaction, isFalse, reason: '事务不残留');
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

    test('包装说明归表单管：update 会覆盖，不归「保持原值」那一类（§AJ·AI-5）', () {
      final Product created = service.create(
        goodDraft(packageNote: '1 箱 = 48 瓶'),
        now: 1000,
      );

      // 改名 + 换备注 —— 一次保存同时生效
      final Product after = service.update(
        created.id,
        goodDraft(name: '矿泉水（新批次）', packageNote: '1 箱 = 24 瓶'),
        now: 2000,
      );
      expect(after.name, '矿泉水（新批次）');
      expect(after.packageNote, '1 箱 = 24 瓶');

      // 清空备注 —— update 写 NULL（若误归「保持原值」类，这里会残留旧值）
      final Product cleared = service.update(
        created.id,
        goodDraft(name: '矿泉水（新批次）'),
        now: 3000,
      );
      expect(cleared.packageNote, isNull);
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

  // ============================================================ 条码（R-15）
  group('ProductService.barcodeOwners（条码允许重复）', () {
    test('命中 / 去空格 / 未命中 / 空串', () {
      service.create(goodDraft(barcode: '6901234567890'), now: 1000);

      expect(service.barcodeOwners('6901234567890').single.name, '红富士苹果');
      expect(
        service.barcodeOwners(' 6901234567890 '),
        hasLength(1),
        reason: '去掉空格',
      );
      expect(service.barcodeOwners('不存在'), isEmpty);
      expect(service.barcodeOwners(''), isEmpty);
    });

    test('重复条码 → 两条都返回，按建档顺序（**不是**静默取最早一条）', () {
      final Product first = service.create(
        goodDraft(name: '娃哈哈水 550ml'),
        now: 1000,
      );
      final Product second = service.create(
        goodDraft(name: '娃哈哈水 550ml（新批次）', sellPrice: '2.50'),
        now: 2000,
      );

      // 静默挑一条的实现在这里只能返回一条 —— 那正是 R-15 要禁掉的
      expect(
        service.barcodeOwners('6901234567890').map((Product p) => p.id),
        <String>[first.id, second.id],
      );
    });

    test('excludeId 排除自己（编辑时不该提示「已经给自己用过了」）', () {
      final Product mine = service.create(goodDraft(name: '甲'), now: 1000);
      final Product other = service.create(goodDraft(name: '乙'), now: 2000);

      expect(service.barcodeOwners('6901234567890'), hasLength(2));
      expect(
        service
            .barcodeOwners('6901234567890', excludeId: mine.id)
            .map((Product p) => p.id),
        <String>[other.id],
      );
      expect(
        service.barcodeOwners('6901234567890', excludeId: '匹配不上任何 id'),
        hasLength(2),
        reason: '传了个不存在的 id 不该把结果清空',
      );
    });

    test('停用的商品也算条码归属（条码不会「凭空消失」）', () {
      final Product product = service.create(goodDraft(), now: 1000);
      service.setActive(product.id, false, now: 2000);

      expect(service.barcodeOwners('6901234567890').single.id, product.id);
    });

    test('建档与编辑都**不**因为条码重复而失败（允许重复）', () {
      service.create(goodDraft(name: '甲'), now: 1000);
      final Product second = service.create(goodDraft(name: '乙'), now: 2000);

      expect(second.barcode, '6901234567890');
      expect(
        () => service.update(second.id, goodDraft(name: '乙（改名）'), now: 3000),
        returnsNormally,
      );
    });
  });

  group('ProductDraft.barcodeNotice（内联提示文案）', () {
    test('没人用过 → null（界面什么都不显示）', () {
      expect(ProductDraft.barcodeNotice(const <Product>[]), isNull);
    });

    test('一条占用 → 用商品名，并说清保存后会发生什么', () {
      final Product owner = service.create(
        goodDraft(name: '娃哈哈矿泉水 550ml'),
        now: 1000,
      );
      final List<Product> owners = service.barcodeOwners('6901234567890');

      expect(owners.single.id, owner.id);
      expect(
        ProductDraft.barcodeNotice(owners),
        '⚠️ 这个条码已经给「娃哈哈矿泉水 550ml」用过了。\n'
        '保存后扫码会显示两条商品供选择。',
      );
    });

    test('多条占用 → 名字最多列两个，再多就说「等 N 种商品」', () {
      service.create(goodDraft(name: '甲'), now: 1000);
      service.create(goodDraft(name: '乙'), now: 2000);
      expect(
        ProductDraft.barcodeNotice(service.barcodeOwners('6901234567890')),
        '⚠️ 这个条码已经给「甲」「乙」用过了。\n保存后扫码会显示三条商品供选择。',
      );

      service.create(goodDraft(name: '丙'), now: 3000);
      expect(
        ProductDraft.barcodeNotice(service.barcodeOwners('6901234567890')),
        '⚠️ 这个条码已经给「甲」等 3 种商品用过了。\n保存后扫码会显示四条商品供选择。',
      );
    });

    test('提示里给的是**商品名**，不是编码（用户认名字不认编号）', () {
      service.create(goodDraft(name: '甲'), now: 1000);

      final String? notice = ProductDraft.barcodeNotice(
        service.barcodeOwners('6901234567890'),
      );
      expect(notice, contains('「甲」'));
      expect(notice, isNot(contains('P0001')));
    });

    test('条数超过 9 → 退回阿拉伯数字（「十一条商品」反而难读）', () {
      for (int i = 0; i < 10; i++) {
        service.create(goodDraft(name: '占位$i'), now: 1000 + i);
      }

      expect(
        ProductDraft.barcodeNotice(service.barcodeOwners('6901234567890')),
        contains('11条商品'),
      );
    });
  });

  group('v3 包装换算两列（成对启用，§BD·四 #2）', () {
    test('只填数量不填单位名 ⇒ packageUnit 报', () {
      final ProductDraft draft = goodDraft(packageSize: '12');
      expect(
        draft.validate()[ProductField.packageUnit],
        contains('就要给包装起个名字'),
      );
    });

    test('只填单位名不填数量 ⇒ packageSize 报', () {
      final ProductDraft draft = goodDraft(packageUnit: '箱');
      expect(
        draft.validate()[ProductField.packageSize],
        contains('就要填 1 包 = 多少个'),
      );
    });

    test('数量 ≤ 0 ⇒ 报正整数', () {
      expect(
        goodDraft(packageUnit: '箱', packageSize: '0')
            .validate()[ProductField.packageSize],
        contains('正整数'),
      );
      expect(
        goodDraft(packageUnit: '箱', packageSize: '-3')
            .validate()[ProductField.packageSize],
        contains('正整数'),
      );
    });

    test('包装单位与最小单位相同 ⇒ 报（否则换算语义错乱）', () {
      expect(
        goodDraft(unit: '箱', packageUnit: '箱', packageSize: '12')
            .validate()[ProductField.packageUnit],
        contains('不能和最小单位'),
      );
    });

    test('成对启用 ⇒ 校验通过且落库（create 后读回）', () {
      final Product product = service.create(
        goodDraft(unit: '个', packageUnit: '箱', packageSize: '12'),
      );
      final Product? read = ProductDao(db).findById(product.id);
      expect(read?.packageUnit, '箱');
      expect(read?.packageSize, 12);
    });

    test('都不填 ⇒ 不启用（两列 NULL，行为与 v2 一致）', () {
      final Product product = service.create(goodDraft());
      final Product? read = ProductDao(db).findById(product.id);
      expect(read?.packageUnit, isNull);
      expect(read?.packageSize, isNull);
    });
  });
}