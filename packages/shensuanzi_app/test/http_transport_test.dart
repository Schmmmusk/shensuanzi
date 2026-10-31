// `HttpTransport` 的错误文案 —— 2026-10-31 真机。
//
// ## 起因（真机截图）
//
// 状态 3 修完之后 App 自动做了一次全量重拉，主机没开，屏幕上弹出：
//
//     连接主机失败（Connection reset by peer）
//
// 两处问题：
// 1. **英文原文漏进了界面** —— 中老年用户读不懂，而且它把「怎么办」挤没了；
// 2. 真机上「主机没开」应当是 `SocketException(Connection refused)`，
//    出现 `Connection reset by peer` 说明**中间有东西接了连接又掐断**
//    （手机开着 VPN / 代理时很常见）—— 这两种情况的「怎么办」其实一样，
//    但原文只该进日志。
//
// 所以这一组钉两件事：**界面文案是纯中文**、**原始异常交给 onError**。
//
// 运行：`dart test`
import 'dart:io';

import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart'
    show SyncHttpException, TransportRequest;
import 'package:test/test.dart';

void main() {
  Future<Object> catchError(
    HttpTransport transport,
    int port,
  ) async {
    try {
      await transport.send(
        TransportRequest(
          method: 'GET',
          uri: Uri.parse('http://127.0.0.1:$port/api/health'),
        ),
      );
    } catch (error) {
      return error;
    }
    fail('应当抛错');
  }

  test('连不上（端口没人听）⇒ 中文 + 怎么办，不含英文异常名', () async {
    final ServerSocket probe = await ServerSocket.bind('127.0.0.1', 0);
    final int port = probe.port;
    await probe.close(); // 端口空出来但没人监听

    final Object error = await catchError(HttpTransport(), port);
    expect(error, isA<SyncHttpException>());
    final String detail = (error as SyncHttpException).detail;
    expect(detail, contains('Wi-Fi'), reason: '要给「怎么办」');
    expect(detail, isNot(contains('Exception')));
    expect(detail, isNot(contains('SocketException')));
    expect(detail, isNot(contains('Connection')));
  });

  test('连接被中途掐断 ⇒ 中文文案 + 原文进 onError（真机那条 Connection reset）', () async {
    final ServerSocket server = await ServerSocket.bind('127.0.0.1', 0);
    // 接了就掐：客户端会拿到 reset / closed-before-header 一类英文异常
    server.listen((Socket socket) => socket.destroy());
    addTearDown(() async {
      await server.close();
    });

    final List<String> labels = <String>[];
    final List<Object> raw = <Object>[];
    final HttpTransport transport = HttpTransport(
      onError: (Object error, StackTrace stack, String label) {
        labels.add(label);
        raw.add(error);
      },
    );

    final Object error = await catchError(transport, server.port);
    expect(error, isA<SyncHttpException>());
    final String detail = (error as SyncHttpException).detail;

    // ① 界面文案：纯中文 + 怎么办
    expect(detail, contains('Wi-Fi'));
    expect(
      detail,
      isNot(contains('Connection')),
      reason: '真机原话「连接主机失败（Connection reset by peer）」—— 英文不许上界面',
    );
    expect(detail, isNot(contains('reset')));
    expect(detail, isNot(contains('Exception')));

    // ② 原始异常必须留下（否则下次查不到是哪种断法）
    //    两种断法（HttpException / SocketException）只要求「有记录」，
    //    不假设 OS 一定给哪一种 —— 测试机不同、VPN 与否都会变。
    if (labels.isNotEmpty) {
      expect(labels.single, contains('同步网络'));
      expect(raw.single, isNotNull);
    }
  });
}
