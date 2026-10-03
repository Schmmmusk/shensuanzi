/// 神算子主机端。
///
/// ## 包边界（2026-09-25 裁定）
///
/// ```
/// shensuanzi_core        纯 Dart   模型 / DAO / 规则 / 同步协议（DTO + 白名单）
///       ↑
/// shensuanzi_host        纯 Dart   shelf 服务 / SyncServer / 令牌 / 端口 / 二维码数据
///       ↑
/// 根 Flutter 应用         Flutter   UI + 二维码渲染 + 调用 host
/// ```
///
/// 本包**只放「传输层 + 主机专属设施」**：
///
/// | 在本包 | 不在本包 |
/// |---|---|
/// | shelf HTTP 绑定与路由 | 同步 DTO（→ core） |
/// | `SyncServer`（协议处理 + RuleEngine 分派） | 客户端离线队列（→ core） |
/// | 令牌生成 / 校验 / 重置 | 二维码**渲染** widget（→ 根 Flutter 应用） |
/// | 端口探测 17890→17900 | 业务规则（→ core 的 `RuleEngine`） |
/// | 二维码**数据**生成（`qr`） | |
///
/// **本包无 Flutter 依赖** —— `dart test` 全程可跑。
library;

export 'src/auth.dart' show HostIdentity, HostIdentityStore, HostToken;
export 'src/http_server.dart' show HostHttpServer, PortRange;
export 'src/local_ip.dart' show LocalIp, NetCandidate;
export 'src/pairing.dart' show PairingPayload, PairingQr;
export 'src/service_controller.dart'
    show
        HostServiceController,
        HostServiceSnapshot,
        HostServiceState,
        hostIdentityFile,
        hostIdentityFileName;

// 同步服务端实现（协议 DTO 由 shensuanzi_core 提供，此处只导出服务端）
export 'src/sync_server.dart' show SyncServer;
