# R-6 裁定：不建议方案 B，建议方案 C

## 方案 B 的真实边界

方案 B 的规则写成一句话是：

> `status = settled` 等价于"全额已收"；`paid_amount` 只表达"经收/付款单核销的金额"。

这在两个场景下成立：

| 场景 | status | paid_amount | 已收额正确吗 |
|---|---|---|---|
| 店内全款收款 | settled | 0 | ✅（settled 即全额） |
| 全款赊账 | confirmed | 0 | ✅ |
| 事后部分收款 | confirmed | 500 | ✅ |

**但下面这个场景，方案 B 无解**：

> 客户买 5000 的货，当场付 3000，余 2000 下周结。

- `status` 该填什么？`settled` 不对（没结清），`confirmed` 也行
- 那"立即收的 3000"记在哪？
  - 记在 `paid_amount` 里 → 违反 B 的语义（"仅经收付款单核销的金额"）
  - 不记 → 已收额 = 0，实际收了 3000，账错了
  - 记成一条 receipt 单 → **这就是方案 C**

所以方案 B 不是"另一种设计"，而是**方案 C 在"立即部分收款"不存在时的退化形式**。既然要选，不如直接选 C，让规则只有一条。

## 方案 C：立即收款自动生成收付款单

用户视角：

```
收银时填商品 → 选收款方式
  ├─ 现金全额 → 系统自动生成：sale 单 + receipt 单（现金）
  ├─ 现金部分 → 系统自动生成：sale 单 + receipt 单（部分金额）
  └─ 挂账    → 系统自动生成：sale 单（无 receipt）
```

用户看到的还是"一张销售单"，底层的 receipt 单在 UI 上合并展示。单据列表里可以选择"显示/隐藏自动生成的收付款单"。

### 记账规则（RULE-002 改写）

```
创建 sale 单（party_ledger = +total_amount，无论收款方式）
→ StockLedger(quantity = -qty)

若立即收款 > 0：
  自动创建 receipt 单（doc_type=receipt, ref_doc_id=sale.id, total_amount=收款额）
  → settlement(receipt_doc_id=receipt.id, target_doc_id=sale.id, amount=收款额)
  → money_ledger(receipt.id, +收款额)
  → party_ledger(receipt.id, -收款额)   ← 客户欠款减少
  → sale.paid_amount = 收款额
  → 若 paid_amount == total_amount：sale.status = settled
    否则：sale.status = confirmed
否则（全赊）：
  → sale.status = confirmed
```

### 三个关键收益

| 收益 | 说明 |
|---|---|
| **`paid_amount` 语义唯一** | 永远是 `SUM(settlements WHERE target_doc_id = X)`，没有分支 |
| **收付款单列表完整** | 立即收款也会出现在收付款单历史里，审计、对账、导出 CSV 都统一 |
| **部分收款天然支持** | 不需要为"立即部分收款"写特例 |

### 需要改的规范

| 文件 | 修改 |
|---|---|
| `rules.md` RULE-002 | 改为"立即收款 = 自动生成 receipt 单"，删除 `status = settled` 的直写路径 |
| `rules.md` RULE-007 / RULE-008 | 立即退款同理，自动生成 payment 单 |
| `data_model.md` §五 B4 | 保持 `SUM(settlements.amount) GROUP BY target_doc_id`，无需排除 receipt/payment |
| `sync_protocol.md` §8.1 | `createDocument` payload 增加可选 `allocations` 字段（R-1 已裁定）；自动生成的 receipt 单不进 payload，由主机端生成 |
| `Agents.md` §四 | 增加一条裁定："立即收款由主机自动生成 receipt 单" |

## 方案 A 为什么不推荐

方案 A（receipt_doc_id 指向 sale 单自己）能做到同样的查询正确性，但有两个隐患：

1. **字段名与语义不符**：`receipt_doc_id` 应该指向收付款单，指向 sale 单自己会让后续维护者困惑
2. **收付款单列表缺失立即收款**：用户想导出"这周所有收款记录"，方案 A 里立即收的那部分查不到

方案 C 用一张真实的 receipt 单解决了这两个问题，代价是多一张单据——而这对 SQLite 来说可以忽略。

## 如果你坚持方案 B

也不是不行，但要接受三个后果，并写进规范：

1. **明确 v1 不支持"立即部分收款"**。UI 上必须强制用户二选一：全款 / 全赊。想部分收款请分两步操作。
2. **不变量 B4 加限定**："仅适用于存在收付款单的场景"。
3. **UI 必须按 `(doc_type, status)` 双分支展示已收额**：
   ```
   已收 = status == settled ? total : paid_amount
   ```
   并接受"settled 但 paid_amount = 0"这个中间状态的合理性。

如果目标客户以零售为主，这三条都能接受；如果有批发，第二条会和 R-1（`allocations` 随 payload 传入）的设计目标打架——因为 R-1 的 `allocations` 正是为了支持"一张收款单核销多张销售单"，而其中一张可能已经被"立即全额收款"settled 了。

## 我的最终建议

**选方案 C**。它把"资金流动"统一为一件事：**任何一笔钱进或出，都对应一张收付款单**。这条规则越简单，实现、测试、UI 分支就越少。

如果你家里店铺确实**只有零售全额收款**，方案 B 可以作为简化版的 v1，但要在 `Agents.md` 的"待裁定清单"里写一条：

> 若未来支持部分收款，需将立即收款改为自动生成 receipt 单（方案 C）。

这样至少不会忘记这笔债。

---
