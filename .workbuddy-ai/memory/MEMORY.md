# 项目长期约定（神算子）

## 文档产出

- **提案类文档必须中英双语**（用户 2026-10-18 明确要求）。写法：每节中文在前、`English` 段紧随其后，两段内容等价；若有出入**以中文为准**。文件名沿用中文（与 `docs/proposals/` 既有命名一致）。
- 提案放 `docs/proposals/`，不占主台账 §编号；裁定后结果并入 `docs/reply_review.md`，并回填 §AR·二 对应行 + `docs/proposals/README.md` 状态表。

## 工程纪律（摘要，权威见 `Agents.md`）

- 业务数据只插入不更新；`documents` 仅可 UPDATE `status` / `paid_amount` / `updated_at`。
- DAO 不开事务；同步落库走 `RuleEngine`；schema 变更必须走迁移链（`Schema.version` + `migrationStep(N-1)`）。
- 修 bug 先 grep 全仓同款模式（纪律 18）；测试红不等于可改生产代码（纪律 12）；描述与实现必须一致（纪律 17）。
- 交付须「先红后改 + 反向灵敏度 + `test/` 与 `tool/selfcheck` 成对镜像」。

## 本机环境坑（实测）

- **`flutter test` 必须摘代理**：`env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy flutter test --no-pub`，否则 `WebSocketException: Invalid WebSocket upgrade request`。
- **本仓打包的 SQLite 带 `SQLITE_OMIT_LOCALTIME`**：`date(x,'unixepoch','localtime')` **返回 NULL**（不报错、静默退化）。需要本地日期分桶时用整数运算：`((ms + localOffset) / 86400000)`。用 Python 的 sqlite3 验证这类修饰符会得到**假绿**。
