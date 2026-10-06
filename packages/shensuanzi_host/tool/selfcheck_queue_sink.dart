// QueueSink → SyncServer 端到端自检：`dart run tool/selfcheck_queue_sink.dart`
//
// B3a（2026-10-06）：主张**客户端入队的 payload，主机原样收下** ——
// 「手机开单 → 入队 → 主机落库（跑规则、换正式单号）」全链路不依赖网络，
// 纯 Dart 就能真跑。与 `test/` 断言等价的本机版本（`dart test` 不可用，
// 见 `docs/testing.md` §零）。**不使用随机数据**，失败可复现。
//
// 退出码：全部通过为 0，否则为 1。
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

int _passed = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failures.add(name);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

void section(String title) => stdout.writeln('\n[$title]');

void main() {
  useLocalSqlite();
  final Db db = Db.openInMemory(foreignKeys: true);

  // ---------- 主数据（core DAO 直接种） ----------
  const int t = 1700000000000;
  ProductDao(db).insert(
    Product(
      id: 'p-1',
      code: 'P001',
      name: '商品',
      costPrice: 350,
      sellPrice: 500,
      createdAt: t,
      updatedAt: t,
    ),
  );
  AccountDao(db).insert(
    Account(
      id: 'a-1',
      name: '现金',
      type: AccountType.cash,
      createdAt: t,
      updatedAt: t,
    ),
  );
  PartyDao(db).insert(
    Party(
      id: 'y-1',
      name: '李姐',
      roles: const <PartyRole>[PartyRole.customer],
      createdAt: t,
      updatedAt: t,
    ),
  );

  final SyncServer server = SyncServer(db);
  final QueueSink queueSink = QueueSink(
    queue: SyncQueueDao(db),
    clock: () => 1700000000000,
  );

  // ---------- ① 销售单：入队 → 主机收下 → 正式单号 ----------
  section('销售：QueueSink → 主机 applied → 正式单号');
  final DocumentSubmitResult sale = queueSink.submitSale(
    SaleDraft(
      partyId: 'y-1',
      date: '2026-10-06',
      lines: const <SaleLineDraft>[
        SaleLineDraft(
          productId: 'p-1',
          productName: '商品',
          quantity: '2',
          unitPrice: '5.00',
        ),
      ],
      payments: const <SalePaymentDraft>[
        SalePaymentDraft(accountId: 'a-1', amount: '10'),
      ],
    ),
  );
  check('销售入队（占位单号）', sale.isQueued && sale.finalDocNo.startsWith('待同步-'));
  final SyncQueueEntry saleEntry = SyncQueueDao(db).all().single;
  final SyncResponse saleResp = server.handle(
    saleEntry.toOperation(),
    now: 1700000000010,
  );
  check('销售 op 主机 applied', saleResp.status == SyncStatus.applied);
  final Document? storedSale = DocumentDao(db).findById(saleEntry.entityId);
  check('销售落库存在', storedSale != null);
  check(
    '占位号换成正式单号 XS*',
    storedSale != null &&
        storedSale.docNo.startsWith('XS') &&
        !storedSale.docNo.startsWith(Document.pendingDocNoPrefix),
  );
  check('立即收款落库 paid_amount = 1000', storedSale?.paidAmount == 1000);

  section('幂等（裁定 ③ 提到的重复推送场景）');
  final SyncResponse again = server.handle(
    saleEntry.toOperation(),
    now: 1700000000020,
  );
  check('同一 op 重推 → already_exists（无害）', again.status == SyncStatus.alreadyExists);

  // ---------- ② 采购超付：找回不落库 ----------
  section('采购：超付封顶（§AY·四）');
  final DocumentSubmitResult purchase = queueSink.submitPurchase(
    PurchaseDraft(
      date: '2026-10-06',
      lines: const <PurchaseLineDraft>[
        PurchaseLineDraft(
          productId: 'p-1',
          productName: '商品',
          quantity: '10',
          unitPrice: '3.50',
        ),
      ],
      payments: const <PurchasePaymentDraft>[
        PurchasePaymentDraft(accountId: 'a-1', amount: '50'),
      ],
    ),
  );
  check('采购入队', purchase.isQueued);
  final SyncQueueEntry purchaseEntry = SyncQueueDao(db).all().last;
  final SyncResponse purchaseResp = server.handle(
    purchaseEntry.toOperation(),
    now: 1700000000030,
  );
  check('采购 op applied', purchaseResp.status == SyncStatus.applied);
  final Document? storedPurchase = DocumentDao(db).findById(
    purchaseEntry.entityId,
  );
  check(
    'paid_amount 封顶 3500（多付的 15 元是找回，不落库）',
    storedPurchase?.paidAmount == 3500,
  );
  check(
    '正式单号 CG*',
    storedPurchase != null && storedPurchase.docNo.startsWith('CG'),
  );

  // ---------- ③ 送货单：无收款区 → in_transit ----------
  section('送货：无收款区 → in_transit');
  final DocumentSubmitResult delivery = queueSink.submitDelivery(
    DeliveryDraft(
      partyId: 'y-1',
      date: '2026-10-06',
      lines: const <DeliveryLineDraft>[
        DeliveryLineDraft(
          productId: 'p-1',
          productName: '商品',
          quantity: '1',
          unitPrice: '6.00',
        ),
      ],
    ),
  );
  check('送货入队', delivery.isQueued);
  final SyncQueueEntry deliveryEntry = SyncQueueDao(db).all().last;
  final SyncResponse deliveryResp = server.handle(
    deliveryEntry.toOperation(),
    now: 1700000000040,
  );
  check('送货 op applied', deliveryResp.status == SyncStatus.applied);
  final Document? storedDelivery = DocumentDao(db).findById(
    deliveryEntry.entityId,
  );
  check(
    'in_transit + 正式单号 SH*',
    storedDelivery != null &&
        storedDelivery.status == DocStatus.inTransit &&
        storedDelivery.docNo.startsWith('SH'),
  );

  // ---------- ④ 三态判定 ----------
  section('三态判定（裁定 ④：sent 之前都算待同步）');
  final SyncQueueTriage triage = SyncQueueDao(db).counts();
  check(
    'pending = 3（尚未 markSent）⇒ 未同步',
    triage.pendingCount == 3 && triage.isSynced == false,
  );

  db.close();

  stdout.writeln('\n==============================================');
  if (_failures.isEmpty) {
    stdout.writeln('全部通过：$_passed 项');
  } else {
    stdout.writeln('失败 ${_failures.length} 项 / 共 ${_passed + _failures.length} 项：');
    for (final String name in _failures) {
      stdout.writeln('  - $name');
    }
    exit(1);
  }
}
