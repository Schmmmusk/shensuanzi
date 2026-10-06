// `StockDelta`（C1 自 `SyncClient` 抽出的库存叠加计算）的单元测试。
//
// 核心主张：**与 `SyncClient` 同名方法逐字段等价**（抽取是纯搬运），
// 以及叠加语义本身（权威 + 未同步、contributors、盘点贡献 0）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// 永不发请求的桩 —— `SyncClient` 构造必需，等价性检查用不到传输
class _NoTransport implements Transport {
  @override
  Future<TransportResponse> send(TransportRequest request) async =>
      throw UnimplementedError('等价性检查不应发请求');
}

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late SyncQueueDao queue;
  late StockDelta delta;

  /// 一条「卖出 2 件」的入队条目（payload = createDocument wire 形状）
  void enqueueSale(String id, String productId, int quantity) {
    queue.enqueue(
      SyncQueueEntry(
        id: id,
        entity: Schema.documents,
        entityId: 'd-$id',
        operation: SyncOpType.createDocument,
        payload: <String, Object?>{
          'document': <String, Object?>{
            'id': 'd-$id',
            'doc_no': '${Document.pendingDocNoPrefix}$id',
            'doc_type': 'sale',
            'status': 'confirmed',
            'occurred_at': 1700000000000,
          },
          'lines': <Object?>[
            <String, Object?>{
              'id': 'l-$id',
              'document_id': 'd-$id',
              'product_id': productId,
              'quantity': quantity,
              'unit_price': 500,
              'amount': quantity * 500,
            },
          ],
        },
        createdAt: 1700000000000,
      ),
    );
  }

  /// 给镜像塞权威库存（直接写流水 —— 与 pull 落库同表）
  void seedStock(String productId, int quantity) {
    insertStock(db.raw, 's-$productId', product: productId, quantity: quantity);
  }

  setUp(() {
    db = Db.openInMemory(foreignKeys: false);
    queue = SyncQueueDao(db);
    delta = StockDelta(db: db, queue: queue);
  });

  tearDown(() => db.close());

  test('空镜像 + 空队列 ⇒ authoritative 0 / unsynced 0 / 已同步', () {
    final StockView view = delta.stockViewOf('p-1');
    expect(view.authoritative, 0);
    expect(view.unsynced, 0);
    expect(view.display, 0);
    expect(view.hasUnsynced, isFalse);
    expect(view.contributors, isEmpty);
    expect(delta.unsyncedDelta(), isEmpty);
  });

  test('权威 10 + 待同步卖出 2 ⇒ display 8，contributors 1 条', () {
    seedStock('p-1', 10);
    enqueueSale('q1', 'p-1', 2);

    final StockView view = delta.stockViewOf('p-1');
    expect(view.authoritative, 10);
    expect(view.unsynced, -2);
    expect(view.display, 8);
    expect(view.hasUnsynced, isTrue);
    expect(view.contributors, hasLength(1));
    expect(delta.unsyncedDelta(), <String, int>{'p-1': -2});
  });

  test('多张单叠加（采购 +3、卖出 2、再卖 4）⇒ 权威与未同步分开算', () {
    seedStock('p-1', 10);
    enqueueSale('q1', 'p-1', 2);
    enqueueSale('q2', 'p-1', 4);
    // 采购入队：sign = +1
    queue.enqueue(
      SyncQueueEntry(
        id: 'q3',
        entity: Schema.documents,
        entityId: 'd-q3',
        operation: SyncOpType.createDocument,
        payload: <String, Object?>{
          'document': <String, Object?>{
            'id': 'd-q3',
            'doc_type': 'purchase',
            'status': 'confirmed',
            'occurred_at': 1700000000000,
          },
          'lines': <Object?>[
            <String, Object?>{
              'id': 'l-q3',
              'document_id': 'd-q3',
              'product_id': 'p-1',
              'quantity': 3,
            },
          ],
        },
        createdAt: 1700000000001,
      ),
    );

    final StockView view = delta.stockViewOf('p-1');
    expect(view.unsynced, -3, reason: '-2 -4 +3');
    expect(view.display, 7, reason: '权威 10 + 未同步 -3');
    expect(view.contributors, hasLength(3));
  });

  test('sent / failed 也算未同步影响（裁定：三种状态都算）', () {
    seedStock('p-1', 10);
    enqueueSale('q1', 'p-1', 2);
    queue.markSent('q1'); // 主机收下了，但还没 pull 确认
    enqueueSale('q2', 'p-1', 3);
    queue.markFailed(
      'q2',
      error: 'boom',
      retryCount: SyncClient.maxRetries + 1,
      nextRetryAt: 0,
      dead: true,
    );

    expect(delta.stockViewOf('p-1').unsynced, -5, reason: 'sent + failed 都算');
  });

  test('盘点条目贡献 0（客户端算不出 —— 诚实，§一）', () {
    seedStock('p-1', 10);
    queue.enqueue(
      SyncQueueEntry(
        id: 'q1',
        entity: Schema.documents,
        entityId: 'd-q1',
        operation: SyncOpType.createDocument,
        payload: <String, Object?>{
          'document': <String, Object?>{
            'id': 'd-q1',
            'doc_type': 'stocktake',
            'status': 'confirmed',
            'occurred_at': 1700000000000,
          },
          'lines': <Object?>[
            <String, Object?>{
              'id': 'l-q1',
              'document_id': 'd-q1',
              'product_id': 'p-1',
              'quantity': 99,
            },
          ],
        },
        createdAt: 1700000000000,
      ),
    );
    expect(delta.stockViewOf('p-1').unsynced, 0);
    expect(delta.stockViewOf('p-1').contributors, isEmpty);
  });

  test('与 SyncClient 同名方法**逐字段等价**（抽取 = 纯搬运的回归守卫）', () {
    seedStock('p-1', 10);
    enqueueSale('q1', 'p-1', 2);
    seedStock('p-2', 5);
    enqueueSale('q2', 'p-2', 1);

    final SyncClient client = SyncClient(
      db: db,
      transport: _NoTransport(),
      baseUri: Uri.parse('http://127.0.0.1:1'),
      token: 't',
    );

    // 逐商品等价
    for (final String productId in <String>['p-1', 'p-2', 'p-3']) {
      final StockView viaClient = client.stockViewOf(productId);
      final StockView viaDelta = delta.stockViewOf(productId);
      expect(viaClient.authoritative, viaDelta.authoritative, reason: productId);
      expect(viaClient.unsynced, viaDelta.unsynced, reason: productId);
      expect(viaClient.display, viaDelta.display, reason: productId);
      expect(viaClient.contributors.length, viaDelta.contributors.length,
          reason: productId);
    }
    expect(client.unsyncedDelta(), delta.unsyncedDelta());
  });

  test('静态 deltaOf 等价（SyncClient 转调 StockDelta）', () {
    seedStock('p-1', 10);
    enqueueSale('q1', 'p-1', 2);
    final SyncQueueEntry entry = queue.all().single;
    expect(SyncClient.deltaOf(entry), StockDelta.deltaOf(entry));
    expect(SyncClient.deltaOf(entry), <String, int>{'p-1': -2});
  });
}
