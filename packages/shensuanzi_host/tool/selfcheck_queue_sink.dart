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

/// **单调**时钟（本自检专用）。
///
/// ⚠️ 不要写成 `clock: () => 1700000000000` 这种常量 —— `SyncQueueDao.all()` 按
/// `(created_at, id)` 排，而 `newId()`（UUIDv7）在**同一毫秒内的顺序由随机尾巴
/// 决定**（`util/ids.dart` 原文：「没有保证」）。冻结时钟 ⇒ 同一次自检里的几条
/// 队列条目 `created_at` 完全相同 ⇒ `.last` / `all()[i]` 变成掷硬币。
/// （2026-10-09：core `master_data_sink_test` 正是因此偶发红。）
int _tick = 1700000000000;
int tick() => _tick++;

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
    clock: tick, // 单调 ⇒ 队列顺序确定（理由见文件头 `tick`）
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

  // ---------- ⑤ 主数据入队（D2，2026-10-08）----------
  //
  // ⚠️ 这一段用**两个库**：`mirror` = 手机镜像（队列挂在它上面），`host` = 主机。
  // 上面 ①–④ 用单库是简化（队列与主机同库）；主数据**乐观写**必须两库才测得准
  // —— 乐观行写在镜像里，主机收到 createMasterData 时**自己那边还没有这个 id**。
  section('主数据入队：乐观写镜像 → 主机 applied（D2）');
  {
    final Db mirror = Db.openInMemory(foreignKeys: false);
    final Db host = Db.openInMemory(foreignKeys: true);
    final SyncServer hostServer = SyncServer(host);
    final QueueMasterSink masterSink = QueueMasterSink(
      mirror: mirror,
      queue: SyncQueueDao(mirror),
      clock: tick, // 单调 ⇒ 三条条目（建档 / 编辑 / 停用）顺序确定
    );

    final MasterDataSubmitResult created = masterSink.createProduct(
      ProductDraft(
        name: '矿泉水',
        unit: '瓶',
        sellPrice: '2.00',
        costPrice: '1.20',
        safetyStock: '24',
        packageNote: '1 箱 = 48 瓶',
      ),
    );
    check('建档入队（含编码）', created.isQueued && created.product != null);
    check('入队文案给了编码', (created.queuedNotice ?? '').contains(created.product!.code));

    final Product mirrorRow = ProductDao(mirror).findById(created.product!.id)!;
    check('**乐观写镜像**：列表立刻能查到',
        mirrorRow.name == '矿泉水' && mirrorRow.code == created.product!.code);

    final List<SyncQueueEntry> entries = SyncQueueDao(mirror).all();
    check('镜像队列恰好 1 条', entries.length == 1);
    check('op = createMasterData',
        entries.single.toOperation().operation == SyncOpType.createMasterData);
    check(
      'payload **带 code**（建档时它是客户端的建议，主机可改派）',
      entries.single.toOperation().payload.containsKey('code'),
    );
    check(
      'payload **不含主机专属列**（created_at / updated_at / sync_version）',
      <String>['created_at', 'updated_at', 'sync_version']
          .every((String k) => !entries.single.toOperation().payload.containsKey(k)),
    );

    final SyncResponse hostResp =
        hostServer.handle(entries.single.toOperation(), now: 1700000001010);
    check('主机 applied（编码未冲突 ⇒ 原样采用）',
        hostResp.status == SyncStatus.applied && hostResp.reason == null,
        '${hostResp.reason}');
    final Product hostRow = ProductDao(host).findById(mirrorRow.id)!;
    check('主机编码 == 镜像编码', hostRow.code == mirrorRow.code);
    check('主机写了 sync_version = 0', hostRow.syncVersion == 0);

    // 编辑：payload **不带 code**（§CS·五 契约）
    final MasterDataSubmitResult edited = masterSink.updateProduct(
      mirrorRow.id,
      ProductDraft(
        name: '矿泉水（大瓶）',
        unit: '瓶',
        sellPrice: '2.50',
        costPrice: '1.20',
        safetyStock: '24',
      ),
    );
    check('编辑入队', edited.isQueued && edited.product!.name == '矿泉水（大瓶）');
    check('镜像行已更新（乐观）',
        ProductDao(mirror).findById(mirrorRow.id)!.name == '矿泉水（大瓶）');

    final SyncQueueEntry editEntry = SyncQueueDao(mirror).all().last;
    final SyncOperation editOp = editEntry.toOperation();
    check('op = updateMasterData', editOp.operation == SyncOpType.updateMasterData);
    check('base_version = 镜像行的旧版本（0）', editOp.baseVersion == 0,
        '${editOp.baseVersion}');
    check(
      'payload **不带 code**（系统生成字段客户端不发 —— §CS·五）',
      !editOp.payload.containsKey('code'),
    );

    final SyncResponse editResp = hostServer.handle(editOp, now: 1700000001020);
    check('主机 applied 且版本 +1',
        editResp.status == SyncStatus.applied &&
            ProductDao(host).findById(mirrorRow.id)!.syncVersion == 1,
        '${editResp.reason}');
    check('主机侧编码一个字没动',
        ProductDao(host).findById(mirrorRow.id)!.code == mirrorRow.code);

    // 停用：同样走 updateMasterData（带 is_active）
    final MasterDataSubmitResult off =
        masterSink.setProductActive(mirrorRow.id, false);
    check('停用入队', off.isQueued && off.product!.isActive == false);
    final SyncQueueEntry offEntry = SyncQueueDao(mirror).all().last;
    check('停用也走 updateMasterData', 
        offEntry.toOperation().operation == SyncOpType.updateMasterData);
    final SyncResponse offResp =
        hostServer.handle(offEntry.toOperation(), now: 1700000001030);
    check('主机 applied 且 is_active = 0',
        offResp.status == SyncStatus.applied &&
            ProductDao(host).findById(mirrorRow.id)!.isActive == false,
        '${offResp.reason}');

    // 校验失败：镜像不留行、队列不增项
    final int queueBefore = SyncQueueDao(mirror).all().length;
    final int mirrorCountBefore =
        mirror.raw.select('SELECT COUNT(*) AS n FROM products').first['n']! as int;
    final MasterDataSubmitResult bad =
        masterSink.createProduct(ProductDraft(name: '', unit: '瓶'));
    check('空名字 ⇒ failure（字段级原因在）',
        bad.isFailure && bad.error!.errors.containsKey(ProductField.name));
    check(
      '失败时**不入队、不乐观写**',
      SyncQueueDao(mirror).all().length == queueBefore &&
          (mirror.raw.select('SELECT COUNT(*) AS n FROM products').first['n']!
                  as int) ==
              mirrorCountBefore,
    );

    mirror.close();
    host.close();
  }

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
