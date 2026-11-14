// 在店可售的唯一公式（提案 61 决策 61-⑦ 下沉 core）。
//
// 这三条不是「再测一遍加法」，而是钉住三个**业务口径**：
//  1. 桌面端 `unsynced ≡ 0` ⇒ 与旧口径 `book - inTransit` 逐字相同（零回归）；
//  2. 手机端未同步**加**进去（开单后还没推，货已经实际少了）；
//  3. 送货在途**减**掉（送货单创建时账面已扣，货已离店）。
//
// 缺货榜的所有判定都建在它上面（`lib/src/ui/shortage.dart`），
// 所以口径漂了会同时在库存页和缺货榜上错 —— 单源的意义就在这里。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

void main() {
  group('effectiveInStoreOf', () {
    test('桌面端 unsynced = 0 时与旧口径 book - inTransit 逐字相同', () {
      expect(effectiveInStoreOf(book: 10, unsynced: 0, inTransit: 0), 10);
      expect(effectiveInStoreOf(book: 10, unsynced: 0, inTransit: 3), 7);
      expect(effectiveInStoreOf(book: 0, unsynced: 0, inTransit: 0), 0);
    });

    test('手机端未同步影响参与相加（负 = 已卖未推）', () {
      expect(effectiveInStoreOf(book: 10, unsynced: -4, inTransit: 0), 6);
      expect(effectiveInStoreOf(book: 10, unsynced: 5, inTransit: 0), 15);
    });

    test('送货在途扣减，三者叠加', () {
      // 账面 10、本地又卖 4 件没同步、另有 3 件在途 ⇒ 在店可售 3
      expect(effectiveInStoreOf(book: 10, unsynced: -4, inTransit: 3), 3);
    });

    test('允许为负（超卖不拦 —— threat_model.md §3.4）', () {
      expect(effectiveInStoreOf(book: 0, unsynced: -3, inTransit: 0), -3);
      expect(effectiveInStoreOf(book: 0, unsynced: 0, inTransit: 100), -100);
    });
  });
}
