import 'document.dart';

/// 一张单据在某本流水账上的**方向约定**。
///
/// ## 三种状态必须分开
///
/// 因为它们对「完整性」的含义完全不同：
///
/// | 值 | 含义 | 消费方该怎么做 |
/// |---|---|---|
/// | [absent] | 这类单据**不产生**这本账的流水 | **一行都不许有** |
/// | [either] | 会产生，但**方向不固定** | 允许有，但不比方向 |
/// | [positive] / [negative] | 固定方向 | 有符号合计必须等于预期 |
///
/// ⚠️ 这里曾经用 `int` 的 `0` 同时表示前两种 —— 那是错的：
/// 「收付款单不写库存流水」和「盘点可以写、但差额可正可负」是**两件不同的事**。
/// 混成一个 `0` 之后，调用方很容易把盘点也当成「不许有库存流水」；
/// 反过来，抢救器也漏掉了「符号表说不产生 ⇒ 出现了就是坏数据」这条约束
/// （用户审查 2026-10-30）。
///
/// ## 与规则层的关系
///
/// `RuleEngine` 各处是**显式**写符号的（`quantity: -line.quantity`、
/// `amount: -doc.totalAmount`）—— 那样在规则正文里一眼能看懂。
/// 本表是同一套约定的**集中表述**，由 `ledger_signs_test.dart` 用真引擎
/// 逐类型对拍：谁改了规则里的符号而没改这张表，测试立刻红。
enum LedgerDirection {
  /// 这类单据**不产生**这本账的流水（出现了就是坏数据）
  absent,

  /// 会产生，但**方向不固定**（盘点：差额可正可负）
  either,

  /// 固定为正（入库 / 应收增加 / 收款）
  positive,

  /// 固定为负（出库 / 应付增加 / 付款）
  negative;

  /// `+1` / `−1`；[absent] 与 [either] 没有固定符号 ⇒ `null`。
  int? get sign => switch (this) {
    LedgerDirection.positive => 1,
    LedgerDirection.negative => -1,
    _ => null,
  };

  /// 这类单据**是否可能**产生这本账的流水。
  ///
  /// `false` ⇒ 出现任何一行都是坏数据。
  bool get mayHaveRows => this != LedgerDirection.absent;
}

/// 库存流水 `quantity` 的方向。
///
/// | 单据 | 方向 | 含义 |
/// |---|---|---|
/// | `purchase` | [LedgerDirection.positive] | 入库 |
/// | `sale` / `delivery` | [LedgerDirection.negative] | 出库 |
/// | `sale_return` | [LedgerDirection.positive] | 退货回库 |
/// | `purchase_return` | [LedgerDirection.negative] | 退货出库 |
/// | `stocktake` | [LedgerDirection.either] | 差额可正可负 —— **允许有流水** |
/// | `receipt` / `payment` | [LedgerDirection.absent] | 收付款单不碰库存 |
/// ⚠️ 下面三个 `switch` **都不写 `_ =>` 兜底**，逐个列出 —— 将来给 `DocType`
/// 加新类型时，编译器会在这里报「未覆盖」，逼我们明确表态。
/// 用 `_ => absent` 的话，新类型会**悄悄**被当成「不产生任何流水」，
/// 而那是所有默认值里最危险的一种（用户审查 2026-10-30）。
LedgerDirection stockDirectionOf(DocType type) => switch (type) {
  DocType.purchase || DocType.saleReturn => LedgerDirection.positive,
  DocType.sale ||
  DocType.delivery ||
  DocType.purchaseReturn => LedgerDirection.negative,
  DocType.stocktake => LedgerDirection.either,
  DocType.receipt || DocType.payment => LedgerDirection.absent,
  DocType.transfer => LedgerDirection.absent,
};

/// 往来流水 `amount` 的方向。
///
/// | 单据 | 方向 | 含义 |
/// |---|---|---|
/// | `sale` / `delivery` | [LedgerDirection.positive] | 客户欠我（应收增加） |
/// | `purchase` | [LedgerDirection.negative] | 我欠供应商（应付增加） |
/// | `sale_return` | [LedgerDirection.negative] | 冲销应收 |
/// | `purchase_return` | [LedgerDirection.positive] | 冲销应付 |
/// | `receipt` | [LedgerDirection.negative] | 收到钱，欠款减少 |
/// | `payment` | [LedgerDirection.positive] | 付出钱，欠款减少 |
/// | `stocktake` | [LedgerDirection.absent] | 盘点不涉及往来 |
LedgerDirection partyDirectionOf(DocType type) => switch (type) {
  DocType.sale ||
  DocType.delivery ||
  DocType.purchaseReturn ||
  DocType.payment => LedgerDirection.positive,
  DocType.purchase ||
  DocType.saleReturn ||
  DocType.receipt => LedgerDirection.negative,
  DocType.stocktake || DocType.transfer => LedgerDirection.absent,
};

/// 资金流水 `amount` 的方向。
///
/// 主单（`sale` / `purchase` / `delivery` / 退货 / 盘点）**不写**
/// `money_ledger` —— 钱一律挂在自动生成的收付款单下（`rule_engine` §边界）。
LedgerDirection moneyDirectionOf(DocType type) => switch (type) {
  DocType.receipt => LedgerDirection.positive,
  DocType.payment => LedgerDirection.negative,
  DocType.purchase ||
  DocType.sale ||
  DocType.delivery ||
  DocType.saleReturn ||
  DocType.purchaseReturn ||
  DocType.stocktake ||
  DocType.transfer => LedgerDirection.absent,
};
