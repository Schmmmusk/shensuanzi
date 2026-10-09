// MasterDataPolicy（§CV·七 裁定 ① 乙，2026-10-09）—— 主数据门控的**值对象**。
//
// 断言重点是**默认值**：桌面全开（零变化）、手机 v1 只开商品。
// 将来放开往来 / 账户只改 `MasterDataPolicy.mobile()`，那 5 个页面一行不动
// —— 这正是选值对象（而不是两个反向 bool）的理由。
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

void main() {
  group('MasterDataPolicy.desktop（桌面）', () {
    const MasterDataPolicy policy = MasterDataPolicy.desktop();

    test('三族全部可建（单机版行为，零变化）', () {
      expect(policy.canCreateProducts, isTrue);
      expect(policy.canCreateParties, isTrue);
      expect(policy.canCreateAccounts, isTrue);
    });
  });

  group('MasterDataPolicy.mobile（手机 v1）', () {
    const MasterDataPolicy policy = MasterDataPolicy.mobile();

    test('只开商品（§CH §8 的 v1 范围）', () {
      expect(policy.canCreateProducts, isTrue, reason: '手机能离线建商品');
      expect(
        policy.canCreateParties,
        isFalse,
        reason: '往来 v1 仍「保留入口 + 引导到电脑」',
      );
      expect(
        policy.canCreateAccounts,
        isFalse,
        reason: '账户 v1 仍「保留入口 + 引导到电脑」',
      );
    });
  });

  test('显式构造：三族能力各自独立（互不牵连）', () {
    const MasterDataPolicy onlyParties = MasterDataPolicy(
      canCreateProducts: false,
      canCreateParties: true,
      canCreateAccounts: false,
    );
    expect(onlyParties.canCreateProducts, isFalse);
    expect(onlyParties.canCreateParties, isTrue);
    expect(onlyParties.canCreateAccounts, isFalse);
  });
}
