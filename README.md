# 神算子

面向中小企业、个体工商户的仓管 + 记账软件。

- 平台：Windows（主机）+ Android（终端）
- 架构：局域网为主，互联网为辅，无中心服务器
- 授权：开源（AGPL-3.0）
- 数据：本地 SQLite，每日自动备份，加密可选

## 设计立场

1. **数据开放**：不锁用户。备份是普通 ZIP，未加密时可直接用任何 SQLite 工具打开。
2. **本地优先**：Windows 主机是唯一权威数据源。Android 是瘦客户端。
3. **离线可用**：店内断网不影响营业；司机在外可离线签收，回店自动同步。
4. **单机可跑**：不依赖任何云服务。用户的电脑就是服务器。

## 文档分工

| 文档 | 读者 | 内容 |
|---|---|---|
| `Agents.md` | AI Agent / 新加入的开发者 | 纪律、摘要、文档索引 |
| `docs/data_model.md` | 实施者 | 实体、字段、索引、不变量 |
| `docs/sync_protocol.md` | 实施者 | 同步规范：幂等、冲突、重试 |
| `docs/rules.md` | 实施者 | 业务规则 RULE-001 ~ RULE-009 |
| `docs/threat_model.md` | 所有人 | 信任边界与已知风险 |
| `docs/testing.md` | 实施者 | 测试要求（DAO / 不变量 / 规则 / 同步 / 端到端） |
| `docs/data_directory.md` | 实施者 / 所有人 | 数据放哪、怎么校验、怎么找回 |
| `docs/ui_principles.md` | UI 实现者 | 面向中老年用户的界面原则 |

## 目录结构

```text
repo/
├── README.md
├── Agents.md
├── docs/
│   ├── data_model.md
│   ├── sync_protocol.md
│   ├── rules.md
│   ├── threat_model.md
│   ├── data_directory.md
│   ├── ui_principles.md
│   └── testing.md
├── packages/
│   ├── shensuanzi_core/     # 纯 Dart：模型 / DAO / 规则 / 同步协议（DTO + 白名单 + 客户端）
│   ├── shensuanzi_host/     # 纯 Dart：shelf 服务 / SyncServer / 令牌 / 端口 / 二维码数据
│   └── shensuanzi_app/      # 纯 Dart：数据目录策略 / 配置 / 标记 / 启动恢复 / 对话框状态机
└── lib/                     # Flutter 壳（Windows 主机 + Android 客户端）
    ├── main.dart            # runApp
    └── src/
        ├── app.dart         # 启动流程：解析位置 → 弹对话框 → 开库 → 主界面
        ├── folder_picker.dart  # 全项目唯一的插件调用点（系统「选择文件夹」）
        └── ui/              # 左侧常驻导航 / 概览 / 数据目录对话框
            ├── app_shell.dart          # 220px 导航列 + 三重高亮 + 面包屑
            ├── nav_icons.dart          # iconKey → IconData（导航结构是纯 Dart）
            ├── overview_page.dart      # 「数据在哪」
            └── data_directory_dialog.dart
```

**包边界**（2026-09-25 / 09-26 裁定）：

```text
shensuanzi_core        纯 Dart   模型 / DAO / 规则引擎 / 同步协议（DTO / 白名单 / 游标）/ SyncClient
      ↑
shensuanzi_host        纯 Dart   shelf / SyncServer / 令牌 / 端口探测 / 二维码数据
      ↑
shensuanzi_app         纯 Dart   数据目录策略 / 配置文件 / 标记文件 / 启动恢复 / 界面缩放档位
      ↑
Flutter 应用(Windows)  Flutter   UI + 二维码渲染 + 调用 host + app
Flutter 应用(Android)  Flutter   UI + 调用 core.client（**不依赖 host**）
```

**三个包都无 Flutter 依赖**，所以 `dart test` 全程可跑。
二维码**生成**在 host（`qr`，纯 Dart），**渲染**在 Flutter 层（`qr_flutter`）——
把「生成」与「渲染」拆开，是为了让逻辑都能被测试。

`shensuanzi_app` 单独成包的理由：数据目录策略既不是业务规则也不是主机服务，
它是**运行环境**；塞进 core / host 会污染那两个包的语义。

## 威胁模型

```text
信任边界：家庭 / 店铺局域网
不防御：局域网内的恶意设备、ARP 欺骗、物理访问主机
防御：外部网络访问、数据文件被拷走、备份包泄露
```

完整内容见 [`docs/threat_model.md`](docs/threat_model.md)。

## 数据在哪

**你的经营数据放在你自己的电脑里，不在我们的服务器上。**

首次启动会让你选一个文件夹，默认建议：

```text
D:\神算子数据\                     ← 有非系统盘时优先（重装系统不会丢）
否则 C:\Users\<你>\神算子数据\
```

- 数据目录里有一个 `.shensuanzi-data` 标记文件。
  就算设置被清理软件删掉，只要重选原来的文件夹，数据立刻回来
- **不要放在 U 盘或网盘同步文件夹里** —— 拔盘后打不开，
  而 OneDrive 这类同步盘有把数据库写坏的风险（软件会警告你）
- 备份放在**数据目录旁边**（如 `D:\神算子备份\`），保留最近 30 天

完整规则见 [`docs/data_directory.md`](docs/data_directory.md)。

## 当前状态

v0.4 — 规范冻结，进入实施。

**实施进度**：

| 项 | 包 | 状态 |
|---|---|---|
| `schema`（**12 表** + 26 索引）、可重入事务、迁移 | core | ✅ |
| 模型 + DAO（主数据 / 单据 / 四张流水 / 查询） | core | ✅ |
| RULE-001 采购入库 · RULE-002 店内销售 | core | ✅ |
| RULE-003 送货 | core | ✅ 创建 + **主机本地签收**（`markDelivered`）；离线签收待 `documentAction`（R-3） |
| RULE-004 收款核销 · RULE-005 付款核销 | core | ✅ |
| RULE-006 库存 / 余额查询 | core | ✅ `QueryDao`（含在途与「在店可售」） |
| RULE-007 销售退货 · RULE-008 采购退货 | core | ✅ 含 R-11 成本分摊、拒收 |
| RULE-009 盘点 | core | ✅ |
| 同步协议（DTO / 白名单 / 游标编解码） | core | ✅ |
| `SyncServer`（五类操作 + 拉取 + 乐观锁） | host | ✅ |
| shelf HTTP 服务 · Bearer 鉴权 · 端口探测 · 二维码数据 | host | ✅ |
| 主数据增量同步（R-13 方案 A：并入 `pull`，游标 `(updated_at, id)`） | core + host | ✅ 含软删可见、全部列、跨设备可见 |
| 主数据 REST 接口（§8.3） | host | 未开始（**有意**：便利接口，不承担同步职责） |
| **`SyncClient`**（游标 / 离线队列 / pull 应用 / 退避与死信） | core | ✅ 含 R-14 的 `sync_cursor` 表 |
| 未同步影响（`sync_queue` 派生的 ± 数量 delta） | core | ✅ 只算数量，不算成本/往来/盘点 |
| 端到端：一台主机 + 两台客户端（真实 HTTP） | host | ✅ `client_server_test` + 镜像自检 |
| **数据目录策略**（默认 / 校验三档 / 标记文件 / 启动恢复 / 迁移） | app | ✅ 含配置文件与界面缩放档位 |
| **数据目录对话框**（服务入口 + 状态机 + 三档反馈 + 二次确认） | app（逻辑）+ Flutter（摆放） | ✅ 逻辑 137 个用例 / 116 项自检 |
| **左侧常驻导航**（结构 + 图标映射 + 三重高亮 + 面包屑 + 沉浸模式） | app（结构）+ Flutter（摆放） | ✅ 含「入口常驻可见」的可执行断言 |
| 概览页 · 启动流程（解析位置 → 对话框 → 开库） | Flutter | ✅ 骨架（**需 `flutter analyze` / `flutter test` 验证**） |
| **商品建档**（列表 + 搜索 + 新增/编辑 + 停用恢复 + 条码） | core（逻辑）+ Flutter（摆放） | ✅ 6 字段、`code` 系统生成；逻辑 206 用例 / 501 项自检 |
| 采购入库 · 库存查询 · 销售开单 · 收款 | Flutter | 未开始（**核心闭环，下一步**） |
| 首次启动的欢迎浮层 · 店名 · 账户预设 · 设置页（含缩放） | Flutter | 未开始（回补，见 `docs/ui_principles.md` §6.4） |
| 备份打包 · 打包发布 | — | 未开始 |

运行与验证方式（含本机限制）见 [`docs/testing.md` §零](docs/testing.md)。