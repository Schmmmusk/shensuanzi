/// 主数据「能不能在**本机**建档」的 UI 策略（§CV·七 裁定 ① 乙，2026-10-09）。
///
/// ## 为什么是值对象，不是两个 bool
///
/// v1 只开商品（`reply_review.md` §CH §8），但**往来 / 账户迟早要放开**。
/// 用两个反向的 bool（`canCreateProducts` + `readOnlyPartyData`）有两个毛病：
///
/// 1. **同一份代码里两种语义方向** —— 读 `if (!readOnlyPartyData …)` 要反向想一次；
/// 2. **将来每放开一类就要再加一个参数** ⇒ 那 5 个页面**再动一遍**
///    （`sale_page` / `delivery_page` / `purchase_page` / `parties_page` / `stock_page`）。
///
/// 值对象只改这里的默认值（`MasterDataPolicy.mobile()`），页面**一行不动**。
/// 与项目一贯的「为将来留位置」一致（`ShellKind` / `DocumentSink` 同套路）。
///
/// ## ⚠️ 边界：它**只表达 UI 层面允不允许**，不改变 sink 的能力面
///
/// `MasterDataSink` 仍是 **product-only**（§CH §8）。将来放开往来 = **两件事**：
/// 改这里的默认值 + 加一个 `QueuePartySink`。值对象本身不提供任何写入能力。
library;

/// 三族主数据在**本机**的建档能力（桌面全开；手机 v1 只开商品）。
class MasterDataPolicy {
  const MasterDataPolicy({
    required this.canCreateProducts,
    required this.canCreateParties,
    required this.canCreateAccounts,
  });

  /// **桌面**：全部可建 —— 单机版行为，**零变化**。
  const MasterDataPolicy.desktop()
    : canCreateProducts = true,
      canCreateParties = true,
      canCreateAccounts = true;

  /// **手机 v1**：只开**商品**（§CH §8）；往来 / 账户仍「保留入口 + 引导到电脑」
  /// （`Agents.md` 4.3：不隐藏入口）。
  const MasterDataPolicy.mobile()
    : canCreateProducts = true,
      canCreateParties = false,
      canCreateAccounts = false;

  /// 商品建档（手机 v1 = `true`）。
  final bool canCreateProducts;

  /// 往来方建档（手机 v1 = `false` ⇒ 点击给引导）。
  final bool canCreateParties;

  /// 资金账户建档（手机 v1 = `false` ⇒ 点击给引导）。
  final bool canCreateAccounts;

  @override
  String toString() => 'MasterDataPolicy(products: $canCreateProducts, '
      'parties: $canCreateParties, accounts: $canCreateAccounts)';
}
