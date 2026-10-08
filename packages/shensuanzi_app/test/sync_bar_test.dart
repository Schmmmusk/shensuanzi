// 三态条判定（`mobile_sync_service.dart` 的 `SyncLinkState` / `syncBarLabel` /
// `syncBarToneOf`，M04）的单元测试。
//
// ## 核心回归
//
// **没配对过的手机，队列是空的** —— 老判定「队列空 ⇒ 已同步」会把
// 「还没连上电脑」显示成「已同步」，用户以为单已经传过去了。
// 这是信任问题（`docs/reply.md` §二·1），所以这里把它钉死。
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

const SyncQueueTriage _empty = SyncQueueTriage(pendingCount: 0, failedCount: 0);

void main() {
  group('syncLinkStateOf', () {
    test('没配对 ⇒ notPaired（**哪怕队列是空的**）', () {
      expect(
        syncLinkStateOf(paired: false, everSynced: false),
        SyncLinkState.notPaired,
      );
      expect(
        syncLinkStateOf(paired: false, everSynced: true),
        SyncLinkState.notPaired,
        reason: '连配对都没有，everSynced 不该被采信',
      );
    });

    test('配对过但从没同步成功 ⇒ neverSynced', () {
      expect(
        syncLinkStateOf(paired: true, everSynced: false),
        SyncLinkState.neverSynced,
      );
    });

    test('配对过且同步成功过 ⇒ linked', () {
      expect(
        syncLinkStateOf(paired: true, everSynced: true),
        SyncLinkState.linked,
      );
    });
  });

  group('syncBarLabel', () {
    test('未配对 + 空队列 ≠「已同步」（M04 核心回归）', () {
      final String label = syncBarLabel(
        link: SyncLinkState.notPaired,
        triage: _empty,
      );
      expect(label, isNot('已同步'));
      expect(label, '尚未连接电脑');
    });

    test('配对过但没同步过也说清', () {
      expect(
        syncBarLabel(link: SyncLinkState.neverSynced, triage: _empty),
        '还没同步过',
      );
    });

    test('linked 之后队列才有话语权', () {
      expect(syncBarLabel(link: SyncLinkState.linked, triage: _empty), '已同步');
      expect(
        syncBarLabel(
          link: SyncLinkState.linked,
          triage: const SyncQueueTriage(pendingCount: 2, failedCount: 0),
        ),
        '待同步 2 条',
      );
      expect(
        syncBarLabel(
          link: SyncLinkState.linked,
          triage: const SyncQueueTriage(pendingCount: 2, failedCount: 1),
        ),
        '待同步 2 条 · 失败 1 条',
        reason: 'pending 与 failed 并列，不互相覆盖',
      );
    });
  });

  group('syncBarToneOf', () {
    test('未链接恒为中性（没连上不是错误，别用红色吓人）', () {
      expect(
        syncBarToneOf(
          link: SyncLinkState.notPaired,
          triage: const SyncQueueTriage(pendingCount: 0, failedCount: 3),
        ),
        SyncBarTone.neutral,
      );
    });

    test('linked：失败红 / 待同步主色 / 空则中性', () {
      expect(
        syncBarToneOf(
          link: SyncLinkState.linked,
          triage: const SyncQueueTriage(pendingCount: 0, failedCount: 1),
        ),
        SyncBarTone.error,
      );
      expect(
        syncBarToneOf(
          link: SyncLinkState.linked,
          triage: const SyncQueueTriage(pendingCount: 1, failedCount: 0),
        ),
        SyncBarTone.active,
      );
      expect(
        syncBarToneOf(link: SyncLinkState.linked, triage: _empty),
        SyncBarTone.neutral,
      );
    });
  });
}
