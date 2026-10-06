/// `Transport` 的 **HTTP 实现**（§BL·二，2026-10-05 裁定）—— 绑定由应用层提供，
/// core 零新依赖（`dart:io HttpClient` 是 SDK 自带）。
///
/// ## 裁定的三条硬要求
///
/// 1. **显式 UTF-8**：请求体 `utf8.encode`（`write` 默认编码遇中文直接崩，
///    2026-09-26 端到端自检真实踩过）；响应用 `utf8.decoder` 解（别信
///    `Content-Type` 里一定写了 charset）。
/// 2. **超时必须显式设**（§BL 裁定 ①）：局域网里主机可能关机、IP 变了、
///    手机连了别的 Wi-Fi —— 没有超时的请求会挂到天荒地老。
///    连接 5 秒、读取 10 秒。
/// 3. **超时/连不上 = 可读的失败**：转成 [SyncHttpException]（`statusCode: 0`），
///    文案说「怎么办」—— UI 直接展示，不造句。
///
/// 4xx / 5xx **不是异常** —— 原样返回 `TransportResponse`，由 `SyncClient`
/// 决定语义（401 / 403 → 配对失效，见 `MobileSyncService`）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart' show SyncHttpException, Transport, TransportRequest, TransportResponse;

class HttpTransport implements Transport {
  HttpTransport({
    this.connectTimeout = const Duration(seconds: 5),
    this.readTimeout = const Duration(seconds: 10),
  });

  /// 连接超时（§BL 裁定 ①：3–5 秒，取 5）
  final Duration connectTimeout;

  /// 读取超时（§BL 裁定 ①：10 秒）
  final Duration readTimeout;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = connectTimeout;
    try {
      final HttpClientRequest req = await client
          .openUrl(request.method, request.uri)
          .timeout(connectTimeout);
      request.headers.forEach(req.headers.set);
      if (request.body != null) {
        // ⚠️ 显式 UTF-8 —— `write` 的默认编码遇中文直接抛
        req.add(utf8.encode(request.body!));
      }
      final HttpClientResponse resp = await req.close().timeout(readTimeout);
      // ⚠️ 读 body 也要套超时 —— 服务器发了响应头后卡死的情况，
      // join() 自己永远不会结束（真机「一直拉取中」的根因之一）
      final String body =
          await resp.transform(utf8.decoder).join().timeout(readTimeout);
      return TransportResponse(statusCode: resp.statusCode, body: body);
    } on TimeoutException {
      throw SyncHttpException(
        0,
        '连接主机超时 —— 请确认电脑开着神算子、'
        '和手机连的是同一个 Wi-Fi',
      );
    } on SocketException catch (error) {
      throw SyncHttpException(
        0,
        '连不上主机（${error.address?.address ?? '网络不可达'}）—— '
        '请确认电脑开着神算子、和手机连的是同一个 Wi-Fi',
      );
    } on HttpException catch (error) {
      throw SyncHttpException(0, '连接主机失败（${error.message}）');
    } finally {
      client.close(force: true);
    }
  }
}
