// 「草稿 → 实体」纯构造的单元测试（B3a-①）。
//
// `document_build.dart` 是主机落库与客户端入队**共用**的唯一构造 ——
// 这里钉住它的形状；主机路径的行为零变化由既有 sale/purchase/delivery
// 服务测试守卫（它们构造自这里）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

void main() {
  const String product = 'p-test';
  const String party = 'y-test';
  const String account = 'a-test';

  group('buildSaleDocument', () {
    test('主单：占位单号 / confirmed / 备注去空白；documentId = document.id', () {
      final DocumentBuild build = buildSaleDocument(
        SaleDraft(
          partyId: party,
          date: '2026-10-06',
          remark: '  白送一件  ',
          lines: const <SaleLineDraft>[
            SaleLineDraft(
              productId: product,
              productName: '商品',
              quantity: '2',
              unitPrice: '5.00',
            ),
          ],
        ),
        now: 1700000000000,
      );

      expect(build.document.docNo, startsWith(Document.pendingDocNoPrefix));
      expect(build.document.docType, DocType.sale);
      expect(build.document.status, DocStatus.confirmed);
      expect(build.document.partyId, party);
      expect(build.document.totalAmount, 1000);
      expect(build.document.remark, '白送一件');
      expect(build.documentId, build.document.id);
    });

    test('明细：空行跳过；quantity = 换算后最小单位数量；entry_* = 录入原文', () {
      final DocumentBuild build = buildSaleDocument(
        SaleDraft(
          date: '2026-10-06',
          lines: const <SaleLineDraft>[
            SaleLineDraft(), // 空行 ⇒ 跳过
            SaleLineDraft(
              productId: product,
              productName: '商品',
              quantity: '3',
              unitPrice: '2.00',
            ),
          ],
        ),
        now: 1700000000000,
      );

      expect(build.lines, hasLength(1));
      expect(build.lines.single.quantity, 3);
      expect(build.lines.single.amount, 600);
      expect(build.lines.single.documentId, build.document.id);
      expect(build.lines.single.entryQuantity, 3);
      expect(build.lines.single.discountAmount, 0);
    });

    test('立即收付款：落库走**钳制后**金额（§AX·一），0 元行跳过', () {
      // 应收 1000；填 [12, 空] ⇒ 逐行钳制 recorded = [1000, 0]
      final SaleDraft draft = SaleDraft(
        date: '2026-10-06',
        lines: const <SaleLineDraft>[
          SaleLineDraft(
            productId: product,
            productName: '商品',
            quantity: '2',
            unitPrice: '5.00',
          ),
        ],
        payments: const <SalePaymentDraft>[
          SalePaymentDraft(accountId: account, amount: '12'),
          SalePaymentDraft(accountId: account), // 空行 ⇒ recorded 0 ⇒ 跳过
        ],
      );
      expect(draft.recordedPaymentCents, <int>[1000, 0]);

      final DocumentBuild build = buildSaleDocument(draft, now: 1700000000000);

      expect(build.payments, hasLength(1), reason: '0 元行不进收付款');
      expect(build.payments.single.accountId, account);
      expect(build.payments.single.amount, 1000, reason: '落库 = 钳制后金额');
    });
  });

  group('buildPurchaseDocument', () {
    test('主单与明细同构；付款封顶（§AY·四）', () {
      final DocumentBuild build = buildPurchaseDocument(
        PurchaseDraft(
          date: '2026-10-06',
          lines: const <PurchaseLineDraft>[
            PurchaseLineDraft(
              productId: product,
              productName: '商品',
              quantity: '10',
              unitPrice: '3.50',
            ),
          ],
          payments: const <PurchasePaymentDraft>[
            PurchasePaymentDraft(accountId: account, amount: '50'),
          ],
        ),
        now: 1700000000000,
      );

      expect(build.document.docNo, startsWith(Document.pendingDocNoPrefix));
      expect(build.document.docType, DocType.purchase);
      expect(build.document.status, DocStatus.confirmed);
      expect(build.document.totalAmount, 3500);
      expect(build.lines.single.quantity, 10);
      // 付 50 > 应收 35 ⇒ 落库按封顶后的 3500
      expect(build.payments.single.amount, 3500);
    });
  });

  group('buildDeliveryDocument', () {
    test('没有收款区 ⇒ payments 恒为空；状态给合法初值 in_transit', () {
      final DocumentBuild build = buildDeliveryDocument(
        DeliveryDraft(
          partyId: party,
          date: '2026-10-06',
          lines: const <DeliveryLineDraft>[
            DeliveryLineDraft(
              productId: product,
              productName: '商品',
              quantity: '4',
              unitPrice: '6.00',
            ),
          ],
        ),
        now: 1700000000000,
      );

      expect(build.document.docType, DocType.delivery);
      expect(build.document.status, DocStatus.inTransit);
      expect(build.document.totalAmount, 2400);
      expect(build.payments, isEmpty, reason: '送货单没有收款区');
      expect(build.lines.single.quantity, 4);
    });
  });

  test('两次构造生成不同 id（UUIDv7 = 同步幂等键，不撞）', () {
    final SaleDraft draft = SaleDraft(
      date: '2026-10-06',
      lines: const <SaleLineDraft>[
        SaleLineDraft(
          productId: product,
          productName: '商品',
          quantity: '1',
          unitPrice: '1.00',
        ),
      ],
    );
    final DocumentBuild first = buildSaleDocument(draft, now: 1700000000000);
    final DocumentBuild second = buildSaleDocument(draft, now: 1700000000001);
    expect(first.documentId, isNot(second.documentId));
    expect(first.lines.single.id, isNot(second.lines.single.id));
  });
}
