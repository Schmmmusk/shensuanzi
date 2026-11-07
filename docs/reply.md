这次更新确实把上一轮的核心意见落地了，而且有两项超出了原先要求：

- `doc_search` 已按生产代码修正，连搜索计数查询 `doc_search_count` 也单独补了基准。
- 新增 `gross_margin` 和 `overview_load`，不再只测零散 SQL，而是开始关注毛利图和概览页的整体查询成本。
- 修复了多步查询的 `--explain` 参数错误。
- 性能手册已补充 VM 专项判读、六文件分发清单、门禁说明，以及迁移夹具库与压测库不能混用的红线。

*上一轮四项整改：主体已落地*

不过，逐行审查后我还发现了几处需要处理的问题，其中有一处是测试手册给出的命令与实际脚本不匹配，另一处会影响你们判断探针是否出现性能退化。下面按影响程度展开。

## 一、开测前建议修正的项目

### 1. `machine_info.py --json` 实际上不支持写文件

明确缺陷

这是我最建议先处理的一项。

测试手册 §4.3b 要求：

```batch
python tool/machine_info.py --json machine.json
```

附录 A 也把接口写成：

```batch
python machine_info.py [--json F]
```

但我检查了 [machine_info.py](https://github.com/Schmmmusk/shensuanzi/blob/master/tool/machine_info.py) 的完整入口：它没有 argparse，也没有读取 `sys.argv`，只会：

1. 调用 `collect()`；
2. 把 JSON 打印到终端；
3. 继续打印机器摘要；
4. 打印受限或未采集项目。

因此，当前命令不会生成 `machine.json`，而且不会提示参数不受支持——它会静默忽略 `--json machine.json`。

建议直接给它补一个真正的 CLI：

```batch
python tool/machine_info.py --json machine.json
```

执行后将 JSON 写入文件，终端另外显示一行摘要。最好保证文件内容是纯 JSON，方便以后自动汇总多台测试机的数据。

顺便还有一处小漂移：[tool/README.md](https://github.com/Schmmmusk/shensuanzi/blob/master/tool/README.md) 声称 `machine_info.py` 会采集电源计划，但当前实现没有采集该信息。建议要么补实现，要么从说明中删除，电源计划继续要求人工记录。

### 2. 单据列表和搜索基准仍没有完全覆盖生产执行路径

建议正式定门禁前修正

这次我继续往 DAO 里面追了一层，发现一个容易遗漏的查询。

生产代码 `DocumentDao._summaries()` 的执行过程是：

```text
第一段：查询符合条件的单据 ID
    ↓
第二段：查询这批 ID 对应的单据、退货汇总、收款汇总
    ↓
第三段：settlementCountsMany()
    ↓
返回完整的 DocumentSummary
```

第三段的 SQL 是：

```sql
SELECT target_doc_id AS t, COUNT(*) AS n
FROM settlements
WHERE target_doc_id IN (...)
GROUP BY target_doc_id
```

源码位置：[DocumentDao.\_summariesOfRows()](https://github.com/Schmmmusk/shensuanzi/blob/master/packages/shensuanzi_core/lib/src/dao/document_dao.dart)

但当前 `perf_bench.py` 的：

- `q_list_documents`
- `q_list_roots`
- `q_doc_search`

均只执行了前两段，没有执行第三段。

虽然脚本已经单独提供 `settled_counts`，但它目前的取数方式是：

```sql
WHERE target_doc_id IN (
    SELECT id FROM documents
    ORDER BY created_at DESC
    LIMIT ?
)
```

这不是生产代码的真实取数方式。生产代码使用的是前两段实际筛选出来的 ID，而不是直接取最新 200 张原始单据。

所以这里存在两个问题：

第一，完整列表与搜索的耗时被低估了。

第二，独立的 `settled_counts` 测量的是相似查询，不是完全相同的实际页面查询。

我不认为这必然造成很大的耗时误差——它使用了 `idx_settle_target`，而且只针对一页单据。但我们不能未经测量就假设它可以忽略。

建议 Agent 修改为：两段查询取到实际 ID 后，继续执行一次 `settlementCountsMany()`，将第三段纳入整体计时。

另外，搜索页面的实际加载也不是只有 `doc_search`：

```text
countDocuments(query)
    ↓
listDocuments(query)
    ├── 第一段
    ├── 第二段
    └── settlementCountsMany
```

因此，建议在保留每条查询单独结果的同时，增加一个 `doc_search_load`，测量这次完整操作的总耗时。

这项对 N-d 尤其重要：如果只给 `doc_search` 加门禁，却遗漏搜索计数与核销笔数，可能保护了单条 SQL，却没有保护用户实际感受到的搜索延迟。

### 3. `--explain` 对新增的复合基准覆盖不足

建议修正

这次修复了多步查询传参错误，我很赞成。但目前新的两个复合查询还有一个缺口。

| 基准              | 实际执行        | 当前 `--explain` |
| --------------- | ----------- | -------------- |
| `gross_margin`  | 6 条 SQL     | 只解释 1 条        |
| `overview_load` | 最多 16 条 SQL | 只解释 1 条        |

例如 `q_gross_margin()` 会执行：

- 营收的 3 条 SQL；
- 销售、送货成本；
- 盘点损失；
- 退货成本调整。

但当前只设置了一个 `explain_sql`，对应第一条销售/送货成本 SQL。

`q_overview_load()` 更明显：它只为 `stockTop` 设置了一个 `explain_sql`，其余营收、应收应付、毛利查询均没有单独输出计划。

这意味着运行：

```batch
python tool/perf_bench.py --data-dir "D:\perf-data" --only overview_load --explain --no-gate
```

即使整次概览加载很慢，也不能根据这份 `EXPLAIN` 输出判断是哪条查询没有命中索引。

我建议未来把 callable 的接口从单个：

```python
explain_sql
explain_params
```

扩展为多个带标签的 `explain_steps`。

例如：

```text
gross_margin:
  revenue_sale
  revenue_delivery
  revenue_return
  sale_delivery_cost
  stocktake_loss
  return_cost_adjust

overview_load:
  has_any_document
  revenue_*
  today_summary
  receivables
  payables
  stock_top
  gross_margin_*
```

不用为了漂亮输出而把所有重复参数展开得过于复杂，但至少应该让复合查询里的每一种 SQL 都能被核查。

这项不一定阻止第一轮性能实测，不过会影响后续定位瓶颈的效率。

## 二、测试判读和数据口径还有几处需要收尾

### 4. `probe_*_ms` 仍不应该统一与 `before.csv` 比较

你们已经在 `perf_monitor.py` 里明确写出了「探针 ≠ 页面耗时」，这是正确的。

但 [性能手册 §4.2–4.3](https://github.com/Schmmmusk/shensuanzi/blob/master/docs/perf_test_guide.md) 还保留着一条较宽泛的判据：

> 与 `before.csv` 比较 p95，涨 ≥ 2 倍。

问题是，三个探针与 `perf_bench` 基准的对应关系并不相同。

| 探针                | 对照基准          | 我的判读建议                                        |
| ----------------- | ------------- | --------------------------------------------- |
| `probe_stock_ms`  | `stock_group` | SQL 接近，但不是页面完整查询，只适合近似参考                      |
| `probe_list_ms`   | 没有严格对应项       | 不要与 `list_documents` / `list_roots` 的绝对耗时直接比较 |
| `probe_window_ms` | `pull_window` | 基本同形，可以直接比较趋势和耗时                              |

尤其 `probe_list_ms`，现在仍使用单段查询、表达式排序，没有 roots 过滤；生产页面却已经采用两段式和 `business_day` 索引。

因此我建议把手册里的判据细分：

- `probe_window_ms`：可以和 `pull_window` 做 p95 对比。
- `probe_stock_ms`：只与 `stock_group` 作近似参考，不能当成页面完整耗时。
- `probe_list_ms`：只比较同一探针在不同时间或不同会话中的变化；真正的列表首屏用 `list_roots` 或人工 `s/e` 测量。

这样就不会出现「探针变慢了两倍，于是认为真实列表也变慢了两倍」的错误归因。

### 5. VM 的「60 GB 虚拟 SSD」措辞不严谨

这是文档中的事实问题。

你此前提供的是：

- 存储 60 GB；
- 系统约占 11 GB；
- VMware 基本显示程序。

但没有确认宿主机物理存储介质是 SSD 还是 HDD。

而 [perf_test_guide.md §4.3b](https://github.com/Schmmmusk/shensuanzi/blob/master/docs/perf_test_guide.md) 写的是：

> 60 GB 虚拟 SSD

虚拟磁盘不等于宿主物理 SSD。即使 Guest 系统识别出固定磁盘，也不能据此推断宿主存储介质。

建议改为：

> 60 GB 虚拟磁盘（宿主物理介质类型未确认）

如果能确认宿主机实际使用 NVMe SSD 或机械盘，再单独记录。

### 6. 搜索基准只有一个固定搜索词，覆盖范围还不够

`_search_params()` 当前固定使用：

```python
pat = "%1%"
```

这可以作为一条代表性搜索测试，但不能证明四路匹配条件都得到了充分测试。

当前生产的四路是：

1. 单据编号；
2. 往来方名称；
3. 子单编号；
4. 单据及其子单明细中的商品名称。

而性能造数生成的单号本身带有日期与序号，数字 `1` 很容易在单据编号中命中。这样一来，不同搜索词可能产生很不一样的执行路径。

我建议至少增加几种搜索场景：

| 测试场景 | 示例搜索词       | 主要观察        |
| ---- | ----------- | ----------- |
| 主单号  | `1`         | 常规高命中搜索     |
| 商品名  | `牛奶`        | 商品明细 EXISTS |
| 往来方名 | `老板`        | 往来方匹配       |
| 子单号  | `SK` 或 `FK` | 子单编号匹配      |

不必马上把所有组合纳入门禁，但报告最好分别列出。这样才知道搜索性能的边界在哪里。

## 三、文档与开发治理

还有两项我建议顺手处理。

第一，N-d 的源码注释没有跟上决策单。

`perf_bench.py` 的 `GATES` 附近仍写：

> 是否给 `doc_search` / `today_summary` 也加门禁。

但最新版 `待裁事项-2026-11-04.md` 已经把候选扩充为四条：

- `doc_search`
- `today_summary`
- `gross_margin`
- `overview_load`

而现在我们又发现 `doc_search_count` 和完整列表查询路径也值得评估。

建议把注释改成「候选清单以 N-d 决策单为准」，避免再出现代码、提案和文档各自维护一份候选名单的情况。

第二，10 月 27 日的 I 组执行方案仍然保留着旧版本测试命令。

[docs/proposals/I-组性能测试-今晚执行方案.md](https://github.com/Schmmmusk/shensuanzi/blob/master/docs/proposals/I-%E7%BB%84%E6%80%A7%E8%83%BD%E6%B5%8B%E8%AF%95-%E4%BB%8A%E6%99%9A%E6%89%A7%E8%A1%8C%E6%96%B9%E6%A1%88.md) 目前仍包含：

- 0.6.5；
- schema v5；
- 旧的 15 条查询；
- `--app-version 0.6.5`；
- 旧的 v5 覆盖索引预期。

虽然它开头已经声明测试手册是权威，但文件名仍然叫「今晚执行方案」，很容易被后来的 Agent 或测试者误当成现行执行清单。

建议在文件顶部加醒目的历史标记：

> 本文为 2026-10-27、0.6.5 / schema v5 的历史执行记录。当前 0.7.5 / schema v8 的性能测试以 `docs/perf_test_guide.md` 和最新测试计划为准，不得直接复制本文命令。

这样比删除历史记录好。

## 四、我建议 Agent 下一轮怎么改

我把问题按优先级归拢了一下：

| 优先级 | 工作                                     | 是否阻止当前开测  |
| --- | -------------------------------------- | --------- |
| P1  | 实现 `machine_info.py --json`，或修正文档命令    | 建议先修      |
| P1  | 将 `settlementCountsMany` 纳入实际列表/搜索基准   | 建议先修      |
| P1  | 修正 VM「虚拟 SSD」表述                        | 应修，成本极低   |
| P2  | 复合查询支持多条 `EXPLAIN`                     | 可与开测准备并行  |
| P2  | 修订探针与 `before.csv` 的比较口径               | 正式判读前修    |
| P2  | 补充 `doc_search_count`、完整搜索操作以及不同搜索词测试  | N-d 定稿前处理 |
| P3  | 更新 GATES 注释、旧 I 组方案历史标记、README 的电源计划说明 | 顺手收尾      |

## 五、最终结论：可以开始测试了吗？

可以开始准备大数据测试，但我不建议现在就用这些数据给 N-d 门禁定稿。

我认为 0.7.5 当前的测试体系已经有了不错的骨架：

- 大数据库造数与迁移夹具区分明确；
- 生产查询同步意识明显提高；
- 新毛利功能获得了独立基准；
- 概览完整加载有了复合基准；
- 监控探针的边界终于写清楚；
- 虚拟机环境也有了专门的判读标准。

但正式开始前，至少应该把 `machine_info` 的命令修正，以及列表/搜索缺少第三段核销计数这两项补上。否则容易在第一轮留下无法解释的缺口。

我最希望本次测试最后能拿到这样一张表：

| 实际用户动作  | 性能基准                                 |
| ------- | ------------------------------------ |
| 概览页完整加载 | `overview_load`                      |
| 毛利图     | `gross_margin`                       |
| 单据页首次加载 | 完整的 `list_roots`                     |
| 单据页搜索   | `doc_search_count` + 完整 `doc_search` |
| 库存查询    | 库存页实际查询                              |
| 开单保存    | 真实 UI 操作计时                           |
| 首次启动    | 含自动备份的冷启动实测                          |

这样一来，我们不仅知道「哪条 SQL 快」，还知道「用户点了一个按钮之后究竟等多久」。

本轮审查范围： 最新 master `00222b824190e90533c60d37be375881f619a016`，主要核对了 `perf_bench.py`、`perf_monitor.py`、`machine_info.py`、`DocumentDao`、`DocumentsPage` 和性能测试文档。没有在 VMware 中实际执行脚本或应用，也没有独立重跑提交记录里的测试。

[查看本次更新提交](https://github.com/Schmmmusk/shensuanzi/commit/00222b824190e90533c60d37be375881f619a016)

总体来说，我很认可这一轮的方向。现在的重点已经不再是「多写几条性能测试」，而是确保测试真的测到了用户实际执行的路径。这比单纯堆测试数量更有价值。🫡