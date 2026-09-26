/// 传输抽象（`docs/sync_protocol.md` §8）。
///
/// ## 为什么是抽象类而不是一个函数
///
/// 最初考虑过 `Future<HttpResult> Function(Uri, String?)`，但一个函数签名
/// **表达不了三件事**：`method`（`push` 是 POST、`pull` 是 GET）、
/// `headers`（`Authorization: Bearer <token>` 没地方塞）、以及响应要含
/// `statusCode`。而且将来加超时 / 重试 / 日志钩子时，
/// **装饰器包装比改所有调用点便宜**。
///
/// ## 边界
///
/// **本包（`shensuanzi_core`）不含任何传输实现** —— 保持纯 Dart、零新依赖，
/// 于是 `dart test` 全程可跑。具体绑定由应用层提供：
///
/// | 层 | 实现 |
/// |---|---|
/// | Windows / Android 应用 | `package:http` 或 `dart:io HttpClient` |
/// | 测试 | 假的 `Transport`（断言请求、返回罐头响应） |
///
/// 这样「同步逻辑」与「怎么发出去」彻底解耦 —— 与 `SyncServer` 不含 HTTP
/// 是同一条纪律的两端。
library;

/// 一次请求
class TransportRequest {
  const TransportRequest({
    required this.method,
    required this.uri,
    this.headers = const <String, String>{},
    this.body,
  });

  /// `'GET'` / `'POST'`（大写）
  final String method;

  final Uri uri;
  final Map<String, String> headers;
  final String? body;

  @override
  String toString() {
    final String payload = body == null ? '' : ', ${body!.length} 字节';
    return 'TransportRequest($method $uri$payload)';
  }
}

/// 一次响应。[body] 是**原文**，由调用方决定是否解析 JSON。
class TransportResponse {
  const TransportResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  String toString() =>
      'TransportResponse($statusCode, ${body.length} 字节)';
}

/// 发送请求。实现方**不抛出**网络异常以外的错误 ——
/// HTTP 层的 4xx / 5xx 应当作为 [TransportResponse] 正常返回，
/// 由 `SyncClient` 决定语义（例如 401 → 需要重新配对）。
///
/// ## ⚠️ 实现提示：请求体必须**显式 UTF-8 编码**
///
/// [TransportRequest.body] 是 `String`，里面会有中文（商品名、往来方名、备注）。
/// `dart:io` 的 `HttpClientRequest.write` **默认编码不是 UTF-8**，
/// 遇到中文会直接抛 `Invalid argument: Contains invalid characters`：
///
/// ```dart
/// // ❌ 中文 payload 必崩
/// request.write(body);
/// // ✅
/// request.headers.contentType = ContentType.json; // application/json; charset=utf-8
/// request.add(utf8.encode(body));
/// ```
///
/// 同理，读响应要 `transform(utf8.decoder)`。这条在 2026-09-26 的端到端自检里
/// 真实踩到过 —— 报错出现在**第一次推送主数据**时，看着像「同步层坏了」。
abstract class Transport {
  Future<TransportResponse> send(TransportRequest request);
}

/// 主机返回了非 200 —— **协议层失败**，不是业务层 `rejected`。
///
/// 区分这两者很重要：`rejected` 是**某一条 op** 的业务结果（要写进队列重试、
/// 死信），而本异常表示**整次通信**没成功（网络、鉴权、路由器）。
/// 把 401 当成 `rejected` 写进队列，会让「令牌过期」伪装成「单据被业务规则拒绝」。
class SyncHttpException implements Exception {
  const SyncHttpException(this.statusCode, this.detail);

  final int statusCode;
  final String detail;

  /// 需要重新配对（令牌失效）
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => 'SyncHttpException($statusCode): $detail';
}
