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
│   └── testing.md
├── lib/ test/ windows/ android/    # Flutter 壳（Windows 主机 + Android 客户端）
└── shensuanzi_core/                # Dart 数据层包
    ├── lib/
    └── test/
```

## 威胁模型

```text
信任边界：家庭 / 店铺局域网
不防御：局域网内的恶意设备、ARP 欺骗、物理访问主机
防御：外部网络访问、数据文件被拷走、备份包泄露
```

完整内容见 [`docs/threat_model.md`](docs/threat_model.md)。

## 当前状态

v0.4 — 规范冻结，进入实施。

**实施进度**（数据层 `shensuanzi_core/`，纯 Dart 包）：

| 项 | 状态 |
|---|---|
| `schema`（11 表 + 23 索引）、可重入事务、迁移 | ✅ |
| 模型 + DAO（主数据 / 单据 / 四张流水 / 查询） | ✅ |
| RULE-001 采购入库 · RULE-002 店内销售 | ✅ |
| RULE-003 送货 | ✅ 创建 + **主机本地签收**（`markDelivered`）；离线签收待 `documentAction`（R-3） |
| RULE-004 收款核销 · RULE-005 付款核销 | ✅ |
| RULE-006 库存 / 余额查询 | ✅ `QueryDao`（含在途与「在店可售」） |
| RULE-007 销售退货 · RULE-008 采购退货 | ✅ 含 R-11 成本分摊、拒收 |
| RULE-009 盘点 | ✅ |
| **`SyncServer` 领域层**（推送 / 拉取 / 白名单 / 乐观锁） | ✅ 纯 Dart，**不含 HTTP** |
| HTTP 适配层（shelf）+ 配对 + Windows UI | 未开始 |
| Android 客户端 + SyncClient | 未开始 |

运行与验证方式（含本机限制）见 [`docs/testing.md` §零](docs/testing.md)。