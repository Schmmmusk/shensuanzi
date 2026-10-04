// `toBaseQuantity` —— v3 包装换算的唯一实现（`docs/data_model.md` §3.2 第 4 条）。
//
// 覆盖：成功三分支（null / baseUnit / packageUnit）+ 三种失败（§BD·九，
// 文案逐字钉住）+ 边界（档案没设包装）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

void main() {
  group('toBaseQuantity（成功分支）', () {
    test('entryUnit = null ⇒ 原样（没切单位）', () {
      final QuantityConversion r = toBaseQuantity(
        entryQuantity: 3,
        entryUnit: null,
        baseUnit: '个',
        packageUnit: '箱',
        packageSize: 12,
      );
      expect(r, isA<ConversionSuccess>());
      expect(r.baseQuantityOrNull, 3);
    });

    test('entryUnit = baseUnit ⇒ 原样（显式选了最小单位）', () {
      final QuantityConversion r = toBaseQuantity(
        entryQuantity: 3,
        entryUnit: '个',
        baseUnit: '个',
        packageUnit: '箱',
        packageSize: 12,
      );
      expect(r.baseQuantityOrNull, 3);
    });

    test('entryUnit = packageUnit ⇒ entryQuantity × packageSize', () {
      final QuantityConversion r = toBaseQuantity(
        entryQuantity: 3,
        entryUnit: '箱',
        baseUnit: '个',
        packageUnit: '箱',
        packageSize: 12,
      );
      expect(r.baseQuantityOrNull, 36);
    });
  });

  group('toBaseQuantity（三种失败 —— 文案逐字钉住，§BD·九）', () {
    test('选了包装单位但没设 packageSize ⇒ packageSizeMissing', () {
      final QuantityConversion r = toBaseQuantity(
        entryQuantity: 3,
        entryUnit: '箱',
        baseUnit: '个',
        packageUnit: '箱',
        packageSize: null,
      );
      expect(r, isA<ConversionFailed>());
      final ConversionFailed f = r as ConversionFailed;
      expect(f.reason, ConversionFailureReason.packageSizeMissing);
      expect(
        conversionFailureMessage(f.reason),
        '这个商品没设包装换算',
      );
    });

    test('packageSize <= 0 ⇒ packageSizeInvalid（纯函数兜底）', () {
      final QuantityConversion r = toBaseQuantity(
        entryQuantity: 3,
        entryUnit: '箱',
        baseUnit: '个',
        packageUnit: '箱',
        packageSize: 0,
      );
      expect(r, isA<ConversionFailed>());
      final ConversionFailed f = r as ConversionFailed;
      expect(f.reason, ConversionFailureReason.packageSizeInvalid);
      expect(conversionFailureMessage(f.reason), '包装换算无效');
    });

    test('第三种单位 ⇒ unknownUnit（档案没设包装也一样）', () {
      for (final (String? pkgUnit, String unit) in (<(String?, String)>[
        ('箱', '桶'), // 档案有包装，但单位谁都不是
        (null, '箱'), // 档案没包装，却给了个单位
      ])) {
        final QuantityConversion r = toBaseQuantity(
          entryQuantity: 3,
          entryUnit: unit,
          baseUnit: '个',
          packageUnit: pkgUnit,
          packageSize: pkgUnit == null ? null : 12,
        );
        expect(r, isA<ConversionFailed>(), reason: 'pkgUnit=$pkgUnit');
        final ConversionFailed f = r as ConversionFailed;
        expect(f.reason, ConversionFailureReason.unknownUnit);
        expect(conversionFailureMessage(f.reason), '单位不合法');
      }
    });
  });

  group('QuantityConversion.baseQuantityOrNull', () {
    test('成功取数字、失败取 null（便利取值不抛）', () {
      expect(
        toBaseQuantity(
          entryQuantity: 2,
          entryUnit: '箱',
          baseUnit: '个',
          packageUnit: '箱',
          packageSize: 12,
        ).baseQuantityOrNull,
        24,
      );
      expect(
        toBaseQuantity(
          entryQuantity: 2,
          entryUnit: '箱',
          baseUnit: '个',
          packageUnit: '箱',
          packageSize: null,
        ).baseQuantityOrNull,
        isNull,
      );
    });
  });

  group('convertEntryPriceCents（§BG 方案 A：切单位换预填价）', () {
    // 经典场景：瓶价 ¥2.50（250 分），1 箱 = 12 瓶
    test('最小 → 包装：× packageSize（¥2.50/瓶 → ¥30.00/箱）', () {
      expect(
        convertEntryPriceCents(
          priceCents: 250,
          fromUnit: '',
          toUnit: '箱',
          baseUnit: '瓶',
          packageUnit: '箱',
          packageSize: 12,
        ),
        3000,
      );
    });

    test('包装 → 最小：整除 ⇒ ~/ packageSize（¥30.00/箱 → ¥2.50/瓶）', () {
      expect(
        convertEntryPriceCents(
          priceCents: 3000,
          fromUnit: '箱',
          toUnit: '',
          baseUnit: '瓶',
          packageUnit: '箱',
          packageSize: 12,
        ),
        250,
      );
    });

    test('包装 → 最小：除不尽 ⇒ null（¥10.00/箱 → 每瓶表达不出）', () {
      expect(
        convertEntryPriceCents(
          priceCents: 1000,
          fromUnit: '箱',
          toUnit: '',
          baseUnit: '瓶',
          packageUnit: '箱',
          packageSize: 12,
        ),
        isNull,
      );
    });

    test('归一后同单位 ⇒ 原样（含空串↔ baseUnit 的等价口径）', () {
      expect(
        convertEntryPriceCents(
          priceCents: 250,
          fromUnit: '',
          toUnit: '瓶',
          baseUnit: '瓶',
          packageUnit: '箱',
          packageSize: 12,
        ),
        250,
      );
      expect(
        convertEntryPriceCents(
          priceCents: 250,
          fromUnit: '瓶',
          toUnit: '瓶',
          baseUnit: '瓶',
          packageUnit: '箱',
          packageSize: 12,
        ),
        250,
      );
    });

    test('换算上下文无效 ⇒ null（没设 size / size ≤ 0 / 单位不认得）', () {
      for (final (String? pkgUnit, int? size) in (<(String?, int?)>[
        (null, 12), // 档案没设包装
        ('箱', null), // size 缺
        ('箱', 0), // size 无效
      ])) {
        expect(
          convertEntryPriceCents(
            priceCents: 250,
            fromUnit: '',
            toUnit: '箱',
            baseUnit: '瓶',
            packageUnit: pkgUnit,
            packageSize: size,
          ),
          isNull,
          reason: 'pkgUnit=$pkgUnit, size=$size',
        );
      }
    });

    test('两边都不是最小/包装的对 ⇒ null（兜底）', () {
      expect(
        convertEntryPriceCents(
          priceCents: 250,
          fromUnit: '箱',
          toUnit: '桶',
          baseUnit: '瓶',
          packageUnit: '箱',
          packageSize: 12,
        ),
        isNull,
      );
    });
  });

  group('§BG 两句辅助文案（逐字钉住，UI 不造句）', () {
    test('packageEntryHint —— 只在切到包装单位时显示的那句', () {
      expect(
        packageEntryHint(baseUnit: '瓶', packageUnit: '箱', packageSize: 12),
        '1 箱 = 12 瓶，入库按 12 瓶记。',
      );
    });

    test('entryPriceKeptHint —— 除不尽保留原值时的告知', () {
      expect(
        entryPriceKeptHint(keptUnit: '瓶', otherUnit: '箱'),
        '单价折算除不尽：这个数现在按「瓶」计；想按「箱」计请重新输入单价。',
      );
    });
  });
}
