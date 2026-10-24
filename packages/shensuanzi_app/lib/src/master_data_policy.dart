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
/// 每一种「能不能建」背后都要有**对应的出口**：商品 = `QueueMasterSink`、
/// **往来方 = `QueuePartySink`（2026-10-20 已补，见 §CV·七十七）**、账户 = 还没有
/// （`canCreateAccounts` 仍为 `false`）。值对象本身不提供任何写入能力。
///
/// ⇒ **放开一族 = 两件事**：改这里的默认值 + 确认对应出口已存在。
library;

/// 三族主数据在**本机**的建档能力（桌面全开；手机开放**商品 + 往来方**，
/// 账户仍未开）。
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

  /// **手机**：开**商品**（§CH §8）与**往来方**（2026-10-20 用户要求放开，
  /// §CV·七十七）；账户仍未开 —— 它的出口还没写，开了就是「写入不同步」的坑。
  const MasterDataPolicy.mobile()
    : canCreateProducts = true,
      canCreateParties = true,
      canCreateAccounts = false;

  /// 商品建档（手机 v1 = `true`）。
  final bool canCreateProducts;

  /// 往来方建档（手机 = `true`，2026-10-20 §CV·七十七 已补 `QueuePartySink`；
  /// 更早的「手机 v1 = false ⇒ 点击给引导」已过时）。
  final bool canCreateParties;

  /// 资金账户建档（手机 v1 = `false` ⇒ 点击给引导）。
  final bool canCreateAccounts;

  @override
  String toString() =>
      'MasterDataPolicy(products: $canCreateProducts, '
      'parties: $canCreateParties, accounts: $canCreateAccounts)';
}
