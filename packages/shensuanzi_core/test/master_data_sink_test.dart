// 主数据提交出口（D2，2026-10-08）。
//
// 覆盖两端：
// - `ServiceMasterSink`（主机）：转调 `ProductService`，**行为零变化**，只是把
//   `ProductDraftInvalid` 从抛出改成装进结果；
// - `QueueMasterSink`（客户端）：校验 → 本地 id + 编码 → **乐观写镜像** → 入队。
//
// ⚠️ **端到端那一半（入队 → 主机 `applied`）在 host 包**
// （`tool/selfcheck_queue_sink.dart` 的「主数据入队」段）：那需要 `SyncServer`，
// 而依赖方向是 host → core，core 的测试**不可能** import host。
// 本文件与那一段是**同一批断言的两半**：
// 这里钉「客户端产出什么」，那里钉「主机收下之后是什么」。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);
  setUp(resetClock);

  /// 一个能通过校验的草稿
  ProductDraft goodDraft({
    String name = '矿泉水',
    String unit = '瓶',
    String sellPrice = '2.00',
    String costPrice = '1.20',
    String safetyStock = '24',
    String packageNote = '',
  }) => ProductDraft(
    name: name,
    unit: unit,
    sellPrice: sellPrice,
    costPrice: costPrice,
    safetyStock: safetyStock,
    packageNote: packageNote,
  );

  group('ServiceMasterSink（主机：转调 ProductService，行为零变化）', () {
    late Db db;
    late ServiceMasterSink sink;

    setUp(() {
      db = newMemoryDb();
      sink = ServiceMasterSink(ProductService(db));
    });
    tearDown(() => db.close());

    test('建档 → saved，编码 P0001，落库', () {
      final MasterDataSubmitResult result = sink.createProduct(goodDraft(), now: 1000);
      expect(result.isQueued, isFalse);
      expect(result.queuedNotice, isNull, reason: '主机路径不给「待同步」文案');
      expect(result.product!.code, 'P0001');
      expect(ProductDao(db).findById(result.product!.id)!.name, '矿泉水');
    });

    test('校验失败 → failure（字段级原因），**库里不留半条记录**', () {
      final MasterDataSubmitResult result =
          sink.createProduct(goodDraft(name: ''), now: 1000);
      expect(result.isFailure, isTrue);
      expect(result.error!.errors, contains(ProductField.name));
      expect(
        db.raw.select('SELECT COUNT(*) AS n FROM products').first['n'],
        0,
      );
    });

    test('编辑 → code 不变、sync_version +1（与 ProductService 同口径）', () {
      final Product created = sink.createProduct(goodDraft(), now: 1000).product!;
      final MasterDataSubmitResult edited =
          sink.updateProduct(created.id, goodDraft(name: '矿泉水（大瓶）'), now: 2000);
      expect(edited.product!.code, created.code);
      expect(edited.product!.syncVersion, 1);
      expect(edited.product!.name, '矿泉水（大瓶）');
    });

    test('停用 → 软删（行还在，is_active = 0）', () {
      final Product created = sink.createProduct(goodDraft(), now: 1000).product!;
      final MasterDataSubmitResult off =
          sink.setProductActive(created.id, false, now: 2000);
      expect(off.product!.isActive, isFalse);
      expect(ProductDao(db).findById(created.id), isNotNull, reason: '从不 DELETE');
    });
  });

  group('QueueMasterSink（客户端：乐观写镜像 + 入队）', () {
    late Db mirror;
    late QueueMasterSink sink;

    setUp(() {
      // 镜像 **foreignKeys: false**（与 SyncClient 的镜像同款，见 sync_protocol.md §8.2）
      mirror = newMemoryDb(foreignKeys: false);
      sink = QueueMasterSink(
        mirror: mirror,
        queue: SyncQueueDao(mirror),
        // ⚠️ **必须是单调时钟**（`support/fixtures.dart` 的 `now()`），不能写常量。
        //
        // `SyncQueueDao.all()` 按 `(created_at, id)` 排 —— 冻结时钟会让同一次
        // 用例里的几条队列条目 `created_at` **完全相同**，于是顺序落到 `id` 上；
        // 而 `newId()`（UUIDv7）在**同一毫秒内的顺序由随机尾巴决定**
        // （`util/ids.dart` 原文：「没有保证……实测连续两次 `newId()` 的字典序可能反着」）。
        // ⇒ `.last` / `all()[i]` 变成掷硬币。
        //
        // 2026-10-09 真实踩到：`停用 / 恢复都走 updateMasterData` 偶发红
        // （期望 `updateMasterData`、实得 `createMasterData`）。
        // 根因是**夹具**，不是生产代码 —— `fixtures.dart` 文件头那句
        // 「单调时钟，保证失败可复现（无随机）」才是本意。
        clock: now,
      );
    });
    tearDown(() => mirror.close());

    test('建档 → queued；**乐观写镜像**（列表立刻查得到）', () {
      final MasterDataSubmitResult result = sink.createProduct(goodDraft());

      expect(result.isQueued, isTrue);
      expect(result.queuedNotice, contains(result.product!.code));

      final Product? mirrored = ProductDao(mirror).findById(result.product!.id);
      expect(mirrored, isNotNull);
      expect(mirrored!.name, '矿泉水');
      expect(mirrored.code, result.product!.code);
    });

    test('建档 payload：op = createMasterData，**带 code**、不含主机专属列', () {
      sink.createProduct(goodDraft());
      final SyncOperation op = SyncQueueDao(mirror).all().single.toOperation();

      expect(op.entity, Schema.products);
      expect(op.operation, SyncOpType.createMasterData);
      expect(op.entityId, ProductDao(mirror).findAll(active: null).single.id);
      expect(op.payload, contains('code'), reason: '建档时 code 是客户端的建议');
      expect(op.payload, contains('package_note'));
      for (final String hostOnly in <String>[
        'created_at',
        'updated_at',
        'sync_version',
      ]) {
        expect(op.payload, isNot(contains(hostOnly)), reason: hostOnly);
      }
    });

    test('两条建档 ⇒ 编码递增（从镜像 max+1 生成，与主机同一份生成器）', () {
      final String first = sink.createProduct(goodDraft()).product!.code;
      final String second = sink.createProduct(goodDraft()).product!.code;
      expect(first, 'P0001');
      expect(second, 'P0002');
    });

    test('编辑 payload：op = updateMasterData，**不带 code**，baseVersion = 镜像旧版本', () {
      final Product created = sink.createProduct(goodDraft()).product!;
      final int queueBefore = SyncQueueDao(mirror).all().length;
      sink.updateProduct(created.id, goodDraft(name: '矿泉水（大瓶）'));

      final SyncQueueEntry entry =
          SyncQueueDao(mirror).all()[queueBefore]; // 新增的那一条
      final SyncOperation op = entry.toOperation();

      expect(op.operation, SyncOpType.updateMasterData);
      expect(op.baseVersion, created.syncVersion);
      expect(
        op.payload,
        isNot(contains('code')),
        reason: '§CS·五 契约：系统生成字段客户端不发（sync_protocol.md §8.1）',
      );
      expect(op.payload['name'], '矿泉水（大瓶）');
      expect(op.payload['is_active'], 1, reason: 'wire 布尔用 1/0');
      // 镜像行也被乐观更新了
      expect(ProductDao(mirror).findById(created.id)!.name, '矿泉水（大瓶）');
    });

    test('编辑时 code / created_at 不改（与 ProductService.update 同口径）', () {
      final Product created = sink.createProduct(goodDraft()).product!;
      final Product edited =
          sink.updateProduct(created.id, goodDraft(name: '改名')).product!;
      expect(edited.code, created.code);
      expect(edited.createdAt, created.createdAt);
    });

    test('停用 / 恢复都走 updateMasterData（一条通道，双向）', () {
      final Product created = sink.createProduct(goodDraft()).product!;

      sink.setProductActive(created.id, false);
      expect(ProductDao(mirror).findById(created.id)!.isActive, isFalse);
      SyncOperation off = SyncQueueDao(mirror).all().last.toOperation();
      expect(off.operation, SyncOpType.updateMasterData);
      expect(off.payload['is_active'], 0);

      sink.setProductActive(created.id, true);
      expect(ProductDao(mirror).findById(created.id)!.isActive, isTrue);
      SyncOperation on = SyncQueueDao(mirror).all().last.toOperation();
      expect(on.operation, SyncOpType.updateMasterData);
      expect(on.payload['is_active'], 1);
      expect(on.payload, isNot(contains('code')));
    });

    test('校验失败 ⇒ **不入队、不乐观写**（库与队列都不留半条）', () {
      final int queueBefore = SyncQueueDao(mirror).all().length;

      final MasterDataSubmitResult bad =
          sink.createProduct(goodDraft(name: '', unit: ''));

      expect(bad.isFailure, isTrue);
      expect(bad.error!.errors.keys, containsAll(<ProductField>[
        ProductField.name,
        ProductField.unit,
      ]));
      expect(SyncQueueDao(mirror).all().length, queueBefore);
      expect(
        mirror.raw.select('SELECT COUNT(*) AS n FROM products').first['n'],
        0,
      );
    });

    test('编辑镜像里没有的 id ⇒ StateError（不静默造一条）', () {
      expect(
        () => sink.updateProduct('不存在的-id', goodDraft()),
        throwsStateError,
      );
    });

    test('乐观行与主机下发同 id 收敛的前提：id 由客户端生成且随 payload 走', () {
      final MasterDataSubmitResult result = sink.createProduct(goodDraft());
      final SyncOperation op = SyncQueueDao(mirror).all().single.toOperation();
      expect(op.entityId, result.product!.id);
      expect(op.payload['id'], result.product!.id, reason: 'payload.id 必须等于 entity_id');
    });
  });
}
