import 'document.dart';

/// 四张流水表里，各类单据的**方向**（符号）。
///
/// ## 为什么需要一张表
///
/// 符号不是格式，是**业务含义本身**：
///
/// - 库存少 10 瓶与多 10 瓶，绝对值一样，账上完全相反；
/// - 收客户 100 元与付客户 100 元，绝对值一样，余额反着走。
///
/// 所以「预期方向」必须有**一处**权威定义。与 `linesAmountAppliesTo()`
/// 同一个思路：消费方（抢救器、对账工具）直接查表，不各自维护一份。
///
/// ## 与规则层的关系
///
/// `RuleEngine` 各处是**显式**写符号的（`quantity: -line.quantity`、
/// `amount: -doc.totalAmount`）—— 那样在规则正文里一眼能看懂。
/// 本表是同一套约定的**集中表述**，由 `ledger_signs_test.dart` 用真引擎
/// 逐类型对拍：谁改了规则里的符号而没改这张表，测试立刻红。
///
/// 返回 `0` 表示**这类单据不产生这张表的流水**（不是「方向为零」）。

/// 库存流水 `quantity` 的符号。
///
/// | 单据 | 符号 | 含义 |
/// |---|---|---|
/// | `purchase` | +1 | 入库 |
/// | `sale` / `delivery` | −1 | 出库 |
/// | `sale_return` | +1 | 退货回库 |
/// | `purchase_return` | −1 | 退货出库 |
/// | `stocktake` | 0 | 差额可正可负，**不适用本表** |
int stockSignOf(DocType type) => switch (type) {
  DocType.purchase || DocType.saleReturn => 1,
  DocType.sale || DocType.delivery || DocType.purchaseReturn => -1,
  _ => 0,
};

/// 往来流水 `amount` 的符号。
///
/// | 单据 | 符号 | 含义 |
/// |---|---|---|
/// | `sale` / `delivery` | +1 | 客户欠我（应收增加） |
/// | `purchase` | −1 | 我欠供应商（应付增加） |
/// | `sale_return` | −1 | 冲销应收 |
/// | `purchase_return` | +1 | 冲销应付 |
/// | `receipt` | −1 | 收到钱，欠款减少 |
/// | `payment` | +1 | 付出钱，欠款减少 |
int partySignOf(DocType type) => switch (type) {
  DocType.sale ||
  DocType.delivery ||
  DocType.purchaseReturn ||
  DocType.payment => 1,
  DocType.purchase || DocType.saleReturn || DocType.receipt => -1,
  _ => 0,
};

/// 资金流水 `amount` 的符号。
///
/// 主单（`sale` / `purchase` / `delivery` / 退货 / 盘点）**不写**
/// `money_ledger` —— 钱一律挂在自动生成的收付款单下（`rule_engine` §边界）。
int moneySignOf(DocType type) => switch (type) {
  DocType.receipt => 1,
  DocType.payment => -1,
  _ => 0,
};
