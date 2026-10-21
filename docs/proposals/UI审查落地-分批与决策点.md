# UI 审查报告的落地方案（2026-10-21）

> ✅ **已裁定（2026-10-21，`docs/reply.md`）**：`Q1 先补测试再删 · Q2 取 max · Q3 同意 · Q4 一次一个 · Q5 挑核心 · Q6 进 0.6.2`。
> **批 0 已完成**（`a990ab2`，全仓 format 206 文件）。用户另提 3 个工程坑（见 §四）与 1 处盲点（性能 → 批 2）。
>
> 原状态：待裁定。来源：`docs/ui-review-2026-10-21.md`（P0 2 · P1 18 · P2 30，逐条带 `文件:行号`）。
> 本文件只做两件事：**核实报告结论**、**给出分批落地与需要你裁的决策点**。
> 双语：每节中文在前、`English` 段紧随；有出入**以中文为准**。

---

## 一、先核实：报告可信吗

我抽查了 5 条（含 2 条 P0、3 条漂移），**全部成立**：

| 结论 | 核实方式 | 结果 |
|---|---|---|
| **P0-1** 设置页持有陈旧配置 | `settings_page.dart:121` `late AppConfig _current = widget.config;`；**全文无 `didUpdateWidget`**；`:192-193` 的 `_apply` 用的正是 `_current.dataDirectory` | ✅ 成立。迁移数据位置后改任何设置 ⇒ 旧路径写回 |
| **P0-2** 三个流水页夹字号 1.15 | `grep withClampedTextScaling` ⇒ `stock_flow_page:103` / `account_flow_page:98` / `party_flow_page:91` | ✅ 成立，三处逐字复制 |
| **漂移 2** 送货页库存快照过期 | `delivery_page.dart:263` `late final _stockSnapshot`；`:412` `_afterSaved` 复用同一 State | ✅ 成立（第二张送货单会少算上一单已扣的量） |
| **漂移 1** 商品页搜不到说「还没有商品」 | `products_page.dart:349` 的 `_Empty` 是**无条件**文案，不区分 `hasQuery` | ✅ 成立 |
| **术语漂移** 承运 vs 司机 | `parties_page.dart:382` 硬编码「承运」；词汇表 `format.dart:83` 是「司机」 | ✅ 成立 |

报告自述「未跑 analyze / test」，但**仓库门禁是可用的**（我刚跑过：根侧 240 / core 641 / host 152 / app 328 / analyze 0）
⇒ 落地时可以「先红后改」，不用盲改。

### English

I spot-checked 5 claims (2 P0s + 3 drifts) — **all hold**. The report says it did not run analyze/tests, but the
gates work in this workspace (240/641/152/328, analyze clean), so we can do red-before-green.

---

## 二、总体策略：按「机制」收口，不按「页面」修

50 条如果逐页修，就是 50 次改动、50 次回归风险。报告自己已经指出了**共同根因**，我按根因分四类：

| 根因 | 覆盖条目 | 处理方式 |
|---|---|---|
| **A. 状态快照陈旧**（页面持有一份会变的副本） | P0-1、漂移 2、设置页每键写盘 | 一条纪律：**派生值不入 State，或必须 `didUpdateWidget` 回灌** |
| **B. 缩放只放大字、不放大布局** | P0-2、§2.5 全部尺寸项、§三·A、附录 B | 一批「尺寸/断点派生」改造 + 补回归测试 |
| **C. 同构代码漂移**（纪律 18 预警的那类） | 漂移 1–5、术语、橙常量、`_fmtDate` 三份 | **收敛成共用组件/常量**，而不是逐处对齐 |
| **D. 文案单一来源被绕开** | §2.3 全部 7 条 | 文案回 core，加禁用词 |

> 一句话：**A 与 D 立刻做（小、硬、可断言）；C 分批收敛（防复发）；B 最后做（工作量大，但要先补测试护栏）。**

### English

Fix by **mechanism**, not by page: (A) stale snapshots, (B) scaling-as-font-only, (C) isomorphic drift,
(D) copy with no single source. A and D are small and testable — do first; C converges into shared widgets;
B is the biggest and needs test rails **before** the change.

---

## 三、分批方案

### 批 0：先把格式噪音清掉（前置，~30 分钟）

`dart format` 现在不在门禁里，且 `app_shell.dart:315-483`、`stock_page.dart:258-306` 缩进是乱的。
**如果先改逻辑再格式化，后面每个 diff 都会混进几百行空白改动** ⇒ 必须先做。

- 单独一个 commit：`chore: dart format`（纯空白，零逻辑）
- 同批把 `dart format --set-exit-if-changed` 加进门禁脚本
- 判据：格式化后**全门禁仍绿**（证明只动了空白）

### 批 1：数据安全 + 最容易拿到收益（P0 全清，1 天）

| # | 内容 | 判据（可执行） |
|---|---|---|
| 1 | **P0-1** 设置页：加 `didUpdateWidget` 回灌；`_apply` 一律基于 `widget.config.copyWith(...)` | 新增用例：宿主换 `config` 后点「调字号」⇒ `onChanged` 收到的 `dataDirectory` 是**新的** |
| 2 | **P0-2** 删三处 1.15 clamp | **同时**补三个流水页的 200% 用例（先红后改）——只删护栏不补测试 = 换一个坑 |
| 3 | 保存失败定位（四页统一）：滚到第一个出错字段 + 按钮上方「还有 N 处要填」 | 用例：散客欠款 ⇒ 断言滚动位置与提示文案 |
| 4 | 商品页空态按 `hasQuery` 分两句 | 用例：有 80 条商品 + 搜「zzz」⇒ 文案是「没有匹配…」不是「还没有商品」 |
| 5 | 帮助页/手册：备份恢复步骤、装箱换算字段（**同一段文案，一处定义**） | 用例：两处文本**逐字相等** |
| 6 | **纪律 17 收口**：`Agents.md:84` 与 README 能力表更新包装换算已接线 | 人工核对（文本类） |

> 批 1 为什么把 5、6 放进来：它们**零代码风险**，但「照着做走不通」对中老年用户是硬伤。

### 批 2：同构漂移收口（防复发，1–2 天）

| # | 内容 | 关键点 |
|---|---|---|
| 7 | 送货页库存快照改「按需失效」 | 与销售页**共用同一个实现**（不是各写一遍 —— 这正是漂移的成因） |
| 8 | 采购页补必填红星 + 供应商选择器空态 | 与销售/送货**同一份**红星组件 |
| 9 | `⋮` → 「编辑 / 停用」文字按钮（往来方、账户） | 照 `products_page.dart:300-311` |
| 10 | 「停用」收敛成**一套安全等级**（余额非 0 ⇒ 确认；否则撤销 SnackBar） | 做成一个 `confirmDisable(...)`，三页共用 |
| 11 | 术语统一（附录 A）+ 橙色常量提 `AppColors` | 术语要**你先定**（见 §四·③） |
| 12 | 概览：空库也有入口、「打开文件夹」、「不会上传」承诺 | 文案回 core |

### 批 3：缩放与结构（收益最大、工作量最大，2–3 天）

| # | 内容 |
|---|---|
| 13 | 尺寸 + 断点随缩放派生（导航项 48→`48*scale`、固定宽度 96/120/72、断点 `<480*scale`） |
| 14 | 一屏引导页全部可滚（启动错误页、扫码页） |
| 15 | 系统字号策略（见 §四·②） |
| 16 | 五页共用列表骨架（常驻搜索 + × 清空 + 清空筛选 + **真实总数** + 行箭头） |
| 17 | 手册目录/跳转；帮助页 FAQ 分组 |
| 18 | **大字号回归测试补到缺的 12 个页面**（附录 B）—— 这是前 17 项不回退的唯一机械保证 |

### English

**Batch 0** format-only commit + gate (so later diffs stay readable). **Batch 1** the two P0s + save-failure
locating + empty-state copy + help/manual copy unification + capability table. **Batch 2** converge the five
isomorphic drifts into shared widgets, unify terminology/colors, fix overview entry points. **Batch 3** derive
sizes/breakpoints from scale, scrollable full-screen pages, system-font policy, shared list skeleton, manual TOC,
and large-text regression tests for the 12 uncovered pages.

---

## 四、需要你裁的 6 件事（其余我按推荐执行）

**① 删 P0-2 的 clamp 之后，窄屏 200% 会不会溢出？**
→ 我的做法：**同一批里先补测试再删**。如果测试红且短期修不好，**退回「夹到 1.5」而不是 1.15**（保可用性，不骗人）。
**要你确认**：接受「先补测试再删」这个顺序吗？

**② 系统字号与应用档位怎么叠？**
报告建议「相乘或取大」。**相乘风险大**（系统 1.3 × 应用 2.0 = 2.6 倍，界面必崩）。
→ 我推荐 **取较大值**（`max(系统, 应用档位)`），并在设置页写一句「系统字号更大时会跟着系统」。

**③ 术语定哪套？**（附录 A 有 8 组）
我建议：司机（不用「承运」）· **恢复**（不用「恢复启用」）· 导航「账户」页标题也写「账户」·
往来方视角「欠款 / 还款」、单据视角「未收 / 未付」· 「更改」（不用「更改位置 / 换一个文件夹」）·
「界面大小」统一（规范里叫「界面缩放」也一并改成「界面大小」）。

**④ 要不要做共用组件（批 2/3 的 7/8/10/16）？**
历史教训是「同构代码漏改」，解药正是收敛。但收敛会动 5 个页面，**回归面大**。
→ 我推荐做，但**一次只收敛一个**（先「停用」，再「列表骨架」）。

**⑤ P2 的 30 条要不要全做？**
→ 我建议**只挑 3 类**：对比度（`Colors.red` → `colorScheme.error`）、点击区 < 44px、清空筛选。
其余（手册目录、导出按钮视觉权重等）留到 0.7。

**⑥ 这批进哪个版本？**
0.6.1 已发布全量部署 ⇒ 这批**全部进 0.6.2**，不热修。

---

## 五、明确不做（避免顺手改坏）

报告 §五 列的 13 处**做对了、不要动**：字体栈、左侧常驻导航三重高亮、首启对话框、条码重复内联、
超收找零文案链、库存成本三态、往来方余额三重表达、单据页「搜索自动跨时间范围并明说」、导出反馈链、
手机送货页指路、手册排版、`KeyboardReveal`、`nav_icons` 兜底。

> 特别是**不要为了「统一」给已做对的三处再加弹窗**（退货确认、期初确认、停用有余额的往来方）。

---

## 六、风险与回滚

| 风险 | 应对 |
|---|---|
| 批 3 动尺寸导致**新的溢出** | 每改一个页面，先补该页 200% 用例；用例红就停 |
| 术语统一动了用户已熟悉的词 | 只改「同一件事的多种说法」，**不改导航项名称**（导航改名 = 重新教学） |
| `dart format` 产生巨量 diff | 单独 commit、单独 review，绝不与逻辑混提 |
| 收敛组件时漏改某一页 | 收敛后 `grep` 旧实现必须 **0 命中**（纪律 18 的机械判据） |

### English

Risks and mitigations: add 200% tests per page before touching sizes; unify only synonyms (never rename nav
items); keep the format commit isolated; after converging a widget, `grep` the old implementation must return 0.
