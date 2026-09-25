# 推荐 A

## 三点理由

1. **core 的语义边界**：一旦塞进 shelf，core 就不再是"数据层"——未来 mDNS、证书管理、文件监听都会往里挤。包名和职责对不上，是最难改的债。
2. **你的测试约束**：`flutter test` 跑不了。凡是核心逻辑，必须落在纯 Dart 包里。A 让 host 100% `dart test` 可测。
3. **传输层可替换**：v2 可能换 WebSocket、或加本地 socket 加速。core 不依赖 shelf，就不用动。

## host 的边界：只放"传输层 + 主机专属设施"

**应包含**：

- `shelf` HTTP 服务绑定
- `SyncServer`（协议处理 + RuleEngine 分派）
- Token 生成 / 校验 / 重置
- 端口探测（17890→17900）
- 二维码**数据**生成（用 `qr` 包，纯 Dart）
- Windows 防火墙引导（若实现）

**不应包含**：

- DTO（`SyncPushRequest` / `SyncOp` / `SyncOpResult`）→ **core**
- `SyncClient` 的队列逻辑 → **core**
- 二维码**渲染** widget → 根 Flutter 应用

## 依赖图

```
shensuanzi_core        纯 Dart   models / dao / rules / sync DTO / sync client
      ↑
shensuanzi_host        纯 Dart   shelf / SyncServer / token / 端口 / qr 数据
      ↑
根 Flutter 应用(Windows)  Flutter  UI + 二维码渲染 + 调用 host
      ↑
根 Flutter 应用(Android)  Flutter  UI + 调用 core.client
```

Android 端**不依赖 host**。它只用 core 里的 DTO 和 SyncClient。

## 二维码的拆分是关键

这是 A 能不能成立的技术要点：

| 部分 | 包 | 依赖 | 可测性 |
|---|---|---|---|
| 生成二维码字符串 | `shensuanzi_host` | `qr`（纯 Dart） | ✅ `dart test` |
| 生成二维码图片数据 | `shensuanzi_host` | `image`（纯 Dart） | ✅ `dart test` |
| 渲染到 Widget | 根应用 | `qr_flutter`（Flutter） | ❌ `flutter test` |

**把"生成"和"渲染"分开**，host 里所有逻辑都可测，只有最后的 `QrImageView(data: host.qrData)` 一行在 Flutter 层。这一行无需测试。

## host 的最小 pubspec

```yaml
name: shensuanzi_host
description: 神算子主机端——shelf 服务、配对、令牌
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.5.0

dependencies:
  shensuanzi_core:
    path: ../shensuanzi_core
  shelf: ^1.4.2
  shelf_router: ^1.1.4
  qr: ^3.0.2
  crypto: ^3.0.6        # token 哈希

dev_dependencies:
  test: ^1.25.0
  lints: ^5.0.0
```

**无 Flutter 依赖**。`dart test` 可直接跑。

## 对根应用的影响

根应用的 `pubspec.yaml`：

```yaml
dependencies:
  shensuanzi_core:
    path: packages/shensuanzi_core
  shensuanzi_host:
    path: packages/shensuanzi_host    # 仅 Windows 目标需要
  qr_flutter: ^4.1.0
```

Android 目标可以条件性不引入 `shensuanzi_host`（Flutter 目前不支持按平台区分依赖，但可以通过不在代码里 import 来避免打进 APK——tree shaking 会处理）。

## 目录结构

```
repo/
├── packages/
│   ├── shensuanzi_core/       # 纯 Dart
│   └── shensuanzi_host/       # 纯 Dart
├── windows_app/               # Flutter Windows
├── android_app/               # Flutter Android
└── docs/
```

**注意**：如果 Windows 和 Android 共享大量 UI 代码，也可以只做一个 Flutter 应用，用 `Platform.isWindows` 分支。但**包结构不变**——core 和 host 仍是独立包。

---

## 一句话

**A。** host 只放传输与主机设施，DTO 与客户端逻辑留在 core，二维码生成与渲染拆开——这样 host 是纯 Dart 的，`dart test` 全程可跑，core 的语义边界也守住了。