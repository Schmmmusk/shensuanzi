# 神算子

面向中小企业、个体工商户的**仓管 + 记账**软件。

- 平台：Windows（主机，已可部署）；Android（终端，**开发中**）
- 架构：局域网为主，互联网为辅，无中心服务器
- 授权：开源（**AGPL-3.0**，见 [`LICENSE`](LICENSE)）
- 数据：本地 SQLite；每天自动备份；备份是**普通的数据库文件**

---

## 快速上手

1. **解压**这个压缩包到任意文件夹（比如 `D:\神算子\`）
2. **双击 `shensuanzi.exe`**
   - 如果 Windows 弹出「已保护你的电脑」蓝色提示：点「更多信息」→「仍要运行」。
     **只需要做一次**，这是没购买数字证书的软件都会遇到的提示，不是病毒警告。
3. 第一次启动会问你**把数据放在哪** —— 建议选 `D盘`（重装系统不会丢）
4. 开始用：先到「商品」页建商品，再到「库存」页用「录入现有货物」把现在的存货录进去

> 不知道从哪下手？软件里点左边最下面的「**帮助**」—— 顶部有「**查看完整手册**」（15 章详细说明），
> 也有四步上手和常见问题。手册另有网页版：随包分发的「用户手册.html」，双击用浏览器打开、可打印。

### 怎么删除

1. 删掉解压出来的**文件夹** = 删掉程序
2. 如果想连数据一起删：到「**设置**」页看一眼「数据位置」，手动删除那个文件夹
3. 备份文件夹在数据文件夹**旁边**（如 `D:\神算子备份\`），可以一起删

> ⚠️ **删之前建议先把备份拷到 U 盘** —— 这一步只要一分钟，但删错了就找不回来了。

---

## 设计立场

1. **数据开放**：不锁用户。备份是**普通的 SQLite 数据库文件**，用任何 SQLite 工具都能打开；
   导出的报表是**普通 CSV**，Excel / WPS 都能看。就算哪天不用神算子了，数据还是用户的。
2. **本地优先**：Windows 主机是唯一权威数据源，Android 是瘦客户端。
3. **离线可用**：店内断网不影响营业。
4. **单机可跑**：不依赖任何云服务 —— 用户的电脑就是服务器。

> 以上四条在实现上被一条原则收束：**面向用户的输出优先开放格式，不引入专有封装**
> （`Agents.md`「数据可携带性原则」）。它同时解释了「为什么备份不是 ZIP」「为什么导出只做 CSV」。

---

## 数据在哪

**你的经营数据放在你自己的电脑里，不在我们的服务器上。**

首次启动会让你选一个文件夹，默认建议：

```text
D:\神算子数据\                     ← 有非系统盘时优先（重装系统不会丢）
否则 C:\Users\<你>\神算子数据\
```

- 数据目录里有一个 `.shensuanzi-data` 标记文件。就算设置被清理软件删掉，
  只要重选原来的文件夹，数据立刻回来
- **不要放在 U 盘或网盘同步文件夹里** —— 拔盘后打不开，
  而 OneDrive 这类同步盘有把数据库写坏的风险（软件会警告你）
- 备份放在**数据目录旁边**（如 `D:\神算子备份\`），自动备份保留最近 30 天，
  手动备份**永不自动清理**
- **日志**不在数据目录里，在 `%APPDATA%\神算子\日志\` ——
  换电脑没必要把日志带走（数据与设备状态分开）
- 加密：**暂不提供**。加了口令就多一条「忘记密码 = 数据全丢」的路径，
  目标用户记不住密码，所以不做

完整规则见 [`docs/data_directory.md`](docs/data_directory.md)。

---

## 当前状态

**版本 0.1.0（第一个可部署版本）** —— 数据格式版本 `schema v2`（v1 老库自动迁移：`products` 补 `package_note` 备注列，无需手工干预）。

### ✅ 已实现（可以真用了）

| 功能 | 说明 |
|---|---|
| 商品建档 | 名称 / 单位 / 售价 / 进价 / 条码 / 安全库存；停用与恢复；条码重复**允许**并提示 |
| 期初录入 | 「录入现有货物」一次性把现在的存货记进来 |
| 采购入库 | 开单、部分付款、最小供应商建档、同名往来方合并 |
| 店内销售 | 开单、议价、散客当场结清、赊账、负库存告警 |
| 库存查询 | 账面 / 在途 / **在店可售** / 成本；三档告警（负 / 低 / 正常） |
| 往来方 | 应收应付、汇总、流水、完整建档 / 编辑 / 停用 |
| 单据列表 | 时间范围 + 类型筛选、复制单号 |
| 单据详情 | 明细 + 收付款记录；单据列表可点进去 |
| 收款核销 | 单据详情页「收款 / 付款」；填多了按应收入账、**多出的算找零**并明确告知 |
| 账户 | 资金账户建档（期初余额只读）、余额、停用 / 恢复 |
| 送货 | 送货开单（客户必选、无收款区）+ 客户签收 |
| 数据安全 | **自动备份 + 手动备份**、备份目录可打开、超过 3 天红字提醒 |
| 导出 | 商品 / 库存 / 往来方 / 单据 / 流水五处导出 CSV（给会计、给 Excel） |
| 设置 | 界面缩放五档（含重置）、店名、数据位置、**多设备同步开关** |
| 帮助 | 「查看完整手册」入口（**18 章全文**）+ 四步上手 + 常见问题 |

### 🚧 开发中

| 功能 | 说明 |
|---|---|
| 手机端连过来 | 主机侧**已经能开**（设置页「多设备同步」→ 打开开关 → 手机扫码配对、配对码旁边有主机地址兜底）；**手机端还没开始做**，所以现在还没有手机上的神算子可连 |
| 退货 | 业务规则的**数据层已完成**，界面还没有 |

### 📋 计划

Android 客户端 · 打印单据 · 安装包（当前是便携版）

> 这张表**只讲现在是什么**，不写「下个版本会做什么」——
> 那是承诺不是现状。排期与设计讨论在 [`docs/`](docs/) 里。

---

## 开发与运行

三种位置用**不同的运行器**（详见 [`docs/testing.md`](docs/testing.md) §零）：

```bash
# 纯 Dart 包（数据层 / 主机服务 / 应用运行时）
cd packages/shensuanzi_core && dart pub get && dart test
cd packages/shensuanzi_host && dart pub get && dart test
cd packages/shensuanzi_app  && dart pub get && dart test

# 仓库根（Flutter 应用）
dart run tool/import_guard.dart            # 跨文件导入守卫（缺桶导入 / 缺同胞文件导入）
dart run tool/selfcheck_import_guard.dart  # 验证守卫本身 —— **改守卫后必跑**
flutter analyze     # 唯一的全仓 lint 门禁，目标 0 issues
flutter test
flutter build windows --release
```

**换台机器开发？** 先看 [`docs/windows_build.md`](docs/windows_build.md) **§零「环境准备清单」**
（Flutter 版本要求 / Visual Studio 的 C++ 工作负载 / **SQLite 源码预置** / Python / 原生库）。

**Windows 构建前提**：`sqlite3_flutter_libs` 在配置阶段需要 SQLite 源码。
仓库**不存**这份源码（`third_party/` 被忽略）——
**换台机器克隆下来构建不了，必须先按 [`docs/windows_build.md`](docs/windows_build.md) §三 预置源码**。
打包与发布流程见同文件 §八。

### 文档分工

| 文档 | 读者 | 内容 |
|---|---|---|
| [`Agents.md`](Agents.md) | AI Agent / 新加入的开发者 | **入口**：纪律、关键裁定、文档索引 |
| [`docs/data_model.md`](docs/data_model.md) | 实施者 | 实体、字段、索引、不变量 |
| [`docs/rules.md`](docs/rules.md) | 实施者 | 业务规则 RULE-001 ~ RULE-009 |
| [`docs/sync_protocol.md`](docs/sync_protocol.md) | 实施者 | 同步规范：幂等、冲突、重试 |
| [`docs/data_directory.md`](docs/data_directory.md) | 所有人 | 数据放哪、怎么校验、怎么找回 |
| [`docs/ui_principles.md`](docs/ui_principles.md) | UI 实现者 | 面向中老年用户的界面原则 |
| [`docs/testing.md`](docs/testing.md) | 实施者 | 测试要求与运行前提 |
| [`docs/windows_build.md`](docs/windows_build.md) | 实施者 | Windows 构建 / 运行 / **发布打包** |
| [`docs/threat_model.md`](docs/threat_model.md) | 所有人 | 信任边界与已知风险 |
| [`docs/reply_review.md`](docs/reply_review.md) | 想让事情有据可查的人 | **裁定台账**（每条决定的来历） |
| [`THIRD_PARTY.md`](THIRD_PARTY.md) | 审查者 / 分发者 | 第三方组件与许可声明 |

### 目录结构

```text
repo/
├── lib/                     # Flutter 壳（Windows 主机；Android 客户端将来共用摆放层）
│   └── src/ui/              # 各页面（判断都在纯 Dart 包里，这里只摆放）
├── packages/
│   ├── shensuanzi_core/     # 纯 Dart：模型 / DAO / 规则引擎 / 同步协议 + SyncClient
│   ├── shensuanzi_host/     # 纯 Dart：shelf 服务 / SyncServer / 令牌 / 配对数据
│   └── shensuanzi_app/      # 纯 Dart：数据目录策略 / 配置 / 备份 / 导出 / 日志 / 字体栈
├── test/                    # 根 Flutter 应用的 widget 测试
├── tool/                    # 仓库根的静态守卫（`import_guard` + 它的自检）
├── windows/                 # Windows runner（仅这里放 C++）
└── docs/                    # 规范与台账
```

**包边界**（2026-09-25 / 09-26 裁定）：

```text
shensuanzi_core        纯 Dart   模型 / DAO / 规则引擎 / 同步协议 / SyncClient
shensuanzi_host        纯 Dart   shelf / SyncServer / 令牌 / 端口探测 / 配对数据
shensuanzi_app         纯 Dart   数据目录 / 配置 / 标记 / 恢复 / 备份 / 导出 / 日志
Flutter 应用(Windows)  Flutter   UI + 调用 host + app
Flutter 应用(Android)  Flutter   UI + 调用 core 的 SyncClient（**不依赖 host**）
```

**三个包都无 Flutter 依赖**，所以 `dart test` 全程可跑 ——
**判断放纯 Dart、Flutter 只摆放**是这个项目的铁律（`Agents.md` §二）。

### 威胁模型

```text
信任边界：家庭 / 店铺局域网
不防御：局域网内的恶意设备、ARP 欺骗、物理访问主机
防御：外部网络访问、数据文件被拷走、备份包泄露
```

完整内容见 [`docs/threat_model.md`](docs/threat_model.md)。

---

## 许可

**AGPL-3.0** —— 见 [`LICENSE`](LICENSE)。第三方组件与字体说明见 [`THIRD_PARTY.md`](THIRD_PARTY.md)。

Copyright (C) 2026 神算子贡献者（Shensuanzi contributors）
