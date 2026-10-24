// 草稿 JSON 往返（真实诉求批 ①，2026-10-24，§CV·一百零一）。
//
// 这个文件钉三件事：
// ① **往返一字不差** —— 草稿存的是用户输入原文，恢复后不能有任何换算/舍入；
// ② **读不懂就返回 null** —— 损坏 / 版本更新 / 种类不符，一律当作「没有草稿」
//    （宁可丢草稿，也不要把不认识的形状塞进表单）；
// ③ **判空** —— 空表单不该写草稿（否则下次进页挂一个「空草稿」的橙条）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(useLocalSqlite);

  const SaleLineDraft lineA = SaleLineDraft(
    productId: 'p-1',
    productName: '蒙牛纯牛奶',
    quantity: '3',
    unitPrice: '5.00',
    entryUnit: '箱',
    discountAmount: '1.50',
    baseUnit: '瓶',
    packageUnit: '箱',
    packageSize: 24,
  );

  const SaleLineDraft lineEmpty = SaleLineDraft();

  group('销售草稿往返', () {
    test('字段逐个还原（含包装单位 / 让价 / 收付款）', () {
      const SaleDraft draft = SaleDraft(
        partyId: 'y-1',
        partyName: '王老板',
        date: '2026-10-24',
        remark: '下午送',
        lines: <SaleLineDraft>[lineA, lineEmpty],
        payments: <SalePaymentDraft>[
          SalePaymentDraft(
            accountId: 'a-1',
            accountName: '现金',
            amount: '15.00',
          ),
        ],
      );

      final SaleDraft? back = saleDraftFromJson(saleDraftToJson(draft));
      expect(back, isNotNull);
      expect(back!.partyId, 'y-1');
      expect(back.partyName, '王老板');
      expect(back.date, '2026-10-24');
      expect(back.remark, '下午送');
      expect(back.lines, hasLength(2));
      expect(back.payments, hasLength(1));

      final SaleLineDraft a = back.lines.first;
      expect(a.productId, 'p-1');
      expect(a.productName, '蒙牛纯牛奶');
      expect(a.quantity, '3');
      expect(a.unitPrice, '5.00', reason: '原文必须原样回来 —— 不做 5.00 → 500 的换算');
      expect(a.entryUnit, '箱');
      expect(a.discountAmount, '1.50');
      expect(a.baseUnit, '瓶');
      expect(a.packageUnit, '箱');
      expect(a.packageSize, 24);

      // 空行也要能回来（用户点过「加一行」但还没填）
      expect(back.lines.last.productId, '');
      expect(back.lines.last.quantity, '');

      expect(back.payments.single.accountId, 'a-1');
      expect(back.payments.single.accountName, '现金');
      expect(back.payments.single.amount, '15.00');
    });

    test('savedAt 能读回来（橙条文案用）', () {
      final Map<String, Object?> json = saleDraftToJson(
        const SaleDraft(lines: <SaleLineDraft>[lineA]),
      );
      final DateTime? at = draftSavedAt(json);
      expect(at, isNotNull);
      expect(
        DateTime.now().difference(at!).inSeconds.abs(),
        lessThan(5),
        reason: '写的时候取当前时间',
      );
    });
  });

  group('采购 / 送货草稿往返', () {
    test('采购：字段与销售同形', () {
      const PurchaseDraft draft = PurchaseDraft(
        partyId: 'y-2',
        partyName: '批发部',
        date: '2026-10-23',
        lines: <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: 'p-2',
            productName: '可乐',
            quantity: '10',
            unitPrice: '2.50',
          ),
        ],
      );
      final PurchaseDraft? back = purchaseDraftFromJson(
        purchaseDraftToJson(draft),
      );
      expect(back!.partyName, '批发部');
      expect(back.lines.single.unitPrice, '2.50');
      expect(back.payments, isEmpty);
    });

    test('送货：没有 payments 也能往返', () {
      const DeliveryDraft draft = DeliveryDraft(
        partyId: 'y-3',
        partyName: '小卖部',
        date: '2026-10-22',
        lines: <DeliveryLineDraft>[
          DeliveryLineDraft(
            productId: 'p-3',
            productName: '矿泉水',
            quantity: '24',
            unitPrice: '1.00',
          ),
        ],
      );
      final DeliveryDraft? back = deliveryDraftFromJson(
        deliveryDraftToJson(draft),
      );
      expect(back!.partyId, 'y-3');
      expect(back.lines.single.quantity, '24');
    });
  });

  group('读不懂就返回 null（宁可丢草稿，也不塞错形状）', () {
    test('null / 空 map / 种类不符', () {
      expect(saleDraftFromJson(null), isNull);
      expect(saleDraftFromJson(<String, Object?>{}), isNull);
      expect(
        saleDraftFromJson(<String, Object?>{'v': 1, 'kind': 'purchase'}),
        isNull,
        reason: '销售页不该读进采购草稿',
      );
    });

    test('版本更新（v = 99）⇒ null', () {
      expect(
        saleDraftFromJson(<String, Object?>{'v': 99, 'kind': 'sale'}),
        isNull,
        reason: '草稿来自更新版本 —— 不认识的字段不敢硬塞',
      );
    });

    test('字段类型不对 ⇒ null（不抛）', () {
      expect(
        saleDraftFromJson(<String, Object?>{
          'v': 1,
          'kind': 'sale',
          'lines': 'not-a-list',
        }),
        isNull,
      );
    });
  });

  group('判空：空表单不写草稿', () {
    test('全空 ⇒ false（含一条完全空的行）', () {
      expect(saleDraftHasContent(const SaleDraft()), isFalse);
      expect(
        saleDraftHasContent(const SaleDraft(lines: <SaleLineDraft>[lineEmpty])),
        isFalse,
        reason: '点过「加一行」但没填 —— 不该被当成有内容的草稿',
      );
      expect(purchaseDraftHasContent(const PurchaseDraft()), isFalse);
      expect(deliveryDraftHasContent(const DeliveryDraft()), isFalse);
    });

    // 回归：开单页**默认就有一条「现金」空行**（账户已选、金额空）。
    // 拿 `payments.isNotEmpty` 判会把空表单当成有内容 ⇒ 每次进页挂个空橙条。
    test('只有一条**金额为空**的收付款行 ⇒ 仍算空', () {
      expect(
        saleDraftHasContent(
          const SaleDraft(
            payments: <SalePaymentDraft>[
              SalePaymentDraft(accountId: 'a-1', accountName: '现金', amount: ''),
            ],
          ),
        ),
        isFalse,
      );
      expect(
        saleDraftHasContent(
          const SaleDraft(
            payments: <SalePaymentDraft>[
              SalePaymentDraft(
                accountId: 'a-1',
                accountName: '现金',
                amount: '  ',
              ),
            ],
          ),
        ),
        isFalse,
        reason: '全是空格也算空',
      );
      expect(
        saleDraftHasContent(
          const SaleDraft(
            payments: <SalePaymentDraft>[
              SalePaymentDraft(
                accountId: 'a-1',
                accountName: '现金',
                amount: '5',
              ),
            ],
          ),
        ),
        isTrue,
        reason: '填了金额才算',
      );
    });

    test('填了任意一项 ⇒ true', () {
      expect(
        saleDraftHasContent(const SaleDraft(lines: <SaleLineDraft>[lineA])),
        isTrue,
      );
      expect(
        saleDraftHasContent(const SaleDraft(partyId: 'y-1')),
        isTrue,
        reason: '只选了客户也算（用户可能只是还没填行）',
      );
      expect(saleDraftHasContent(const SaleDraft(remark: '明天补')), isTrue);
      expect(
        saleDraftHasContent(
          const SaleDraft(lines: <SaleLineDraft>[SaleLineDraft(quantity: '2')]),
        ),
        isTrue,
        reason: '只填了数量也算',
      );
    });
  });

  test('normalizeProductName 去首尾空格（与 SQL 的 TRIM(name) 同口径）', () {
    expect(normalizeProductName('  蒙牛纯牛奶 '), '蒙牛纯牛奶');
    expect(normalizeProductName('\t可乐\n'), '可乐');
    expect(normalizeProductName(''), '');
  });
}
