// `MirrorView`（C1·§CC：手机端镜像只读视图）的单元测试。
//
// 主张：镜像库上构造的查询面能读、叠加算得对；类只做「包 db」，边界见类文档。
// 运行：`dart test`（本机由用户执行；临时真跑脚本与测试逻辑等价，已先行验证）
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late MobileSyncService sync;
  late MirrorView view;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_mirror_view_');
    sync = MobileSyncService(
      mirrorPath: p.join(box.path, 'mirror', 'shensuanzi_mirror.db'),
      pairingStore: PairingStore(File(p.join(box.path, 'pairing.json'))),
    );
    view = MirrorView.of(sync);
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 镜像库可能还开着 —— 删不掉不影响结论
    }
  });

  test('空镜像 ⇒ 查询面返回空、叠加为 0（不炸）', () {
    expect(view.products.findAll(), isEmpty);
    expect(view.parties.findAll(role: PartyRole.customer), isEmpty);
    expect(view.queries.stockByProduct(), isEmpty);
    final StockView stock = view.stock.stockViewOf('p-1');
    expect(stock.display, 0);
    expect(stock.hasUnsynced, isFalse);
  });

  test('镜像有主数据 ⇒ 选择器读得到（权威副本）', () {
    final int t = 1700000000000;
    ProductDao(sync.openMirror()).insert(
      Product(
        id: 'p-1',
        code: 'P0001',
        name: '红富士苹果',
        sellPrice: 500,
        createdAt: t,
        updatedAt: t,
      ),
    );
    PartyDao(sync.openMirror()).insert(
      Party(
        id: 'y-1',
        name: '李姐',
        roles: const <PartyRole>[PartyRole.customer],
        createdAt: t,
        updatedAt: t,
      ),
    );

    expect(view.products.findAll().single.name, '红富士苹果');
    expect(view.parties.findAll(role: PartyRole.customer).single.id, 'y-1');
  });

  test('库存叠加：权威（stock_ledger）+ 队列未同步，一次算好', () {
    final Db mirror = sync.openMirror();
    final int t = 1700000000000;
    // stock_ledger 直插（与 pull 落库同表）—— FK 关闭，无需父行
    mirror.raw.execute(
      'INSERT INTO stock_ledger '
      '(id, product_id, document_id, quantity, unit_cost, total_cost, seq_no, '
      'occurred_at, created_at) VALUES '
      "('s1', 'p-1', 'd0', 10, 100, 1000, 1, $t, $t)",
    );
    SyncQueueDao(mirror).enqueue(
      SyncQueueEntry(
        id: 'q1',
        entity: Schema.documents,
        entityId: 'd-q1',
        operation: SyncOpType.createDocument,
        payload: <String, Object?>{
          'document': <String, Object?>{
            'id': 'd-q1',
            'doc_type': 'sale',
            'status': 'confirmed',
            'occurred_at': t,
          },
          'lines': <Object?>[
            <String, Object?>{
              'id': 'l1',
              'document_id': 'd-q1',
              'product_id': 'p-1',
              'quantity': 3,
            },
          ],
        },
        createdAt: t,
      ),
    );

    final StockView stock = view.stock.stockViewOf('p-1');
    expect(stock.authoritative, 10);
    expect(stock.unsynced, -3);
    expect(stock.display, 7, reason: '§BS 验收 ②：权威 + 未同步叠加');
    expect(stock.contributors, hasLength(1));
  });
}
