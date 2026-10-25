// F15（2026-10-25 复跑）：同步失败只给**人话**，原始异常只进日志。
//
// 复跑实测：界面把 `Bad state: 落库 products 的行（…）失败：UNIQUE constraint failed:
// products.code …` 原样印出来 —— 用户看到的是源码，不是「我该怎么办」。
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

void main() {
  /// 任何一类都**不许**把源码漏到界面上
  void expectNoRawText(String message) {
    for (final String raw in <String>[
      'Bad state',
      'Exception',
      'UNIQUE constraint',
      'products.code',
      'SqliteException',
      'SocketException',
      'FormatException',
      'StateError',
    ]) {
      expect(
        message.contains(raw),
        isFalse,
        reason: '界面文案里出现了源码片段「$raw」：$message',
      );
    }
  }

  test('传输层异常 ⇒ 直接用它自己的分类文案', () {
    const SyncHttpException e = SyncHttpException(
      0,
      '连不上电脑（127.0.0.1:17890）—— 检查两台设备是否在同一个 Wi-Fi',
    );
    expect(syncFailureMessage(e), contains('Wi-Fi'));
  });

  test('UNIQUE 冲突 ⇒ 指向「重建本机数据副本」，不提编码细节', () {
    final String m = syncFailureMessage(
      StateError(
        '落库 products 的行（id=01a1…）失败：UNIQUE constraint failed: products.code',
      ),
    );
    expect(m, contains('重建本机数据副本'));
    expectNoRawText(m);
  });

  test('数据库问题 ⇒ 说「数据文件打不开」并给重试 + 重建两条路', () {
    final String m = syncFailureMessage(
      Exception('SqliteException(14): unable to open database file'),
    );
    expect(m, contains('数据文件打不开'));
    expect(m, contains('重试'));
    expectNoRawText(m);
  });

  test('网络问题 ⇒ 让人去查 Wi-Fi 与电脑开关', () {
    final String m = syncFailureMessage(
      Exception('SocketException: Connection refused'),
    );
    expect(m, contains('同一个 Wi-Fi'));
    expectNoRawText(m);
  });

  test('格式/版本不一致 ⇒ 让人把两端更新到同一版本', () {
    final String m = syncFailureMessage(
      const FormatException('Unexpected character'),
    );
    expect(m, contains('版本'));
    expectNoRawText(m);
  });

  test('未知异常 ⇒ 兜底「重试 + 把日志发给技术支持」，绝不猜原因', () {
    final String m = syncFailureMessage(StateError('something odd'));
    expect(m, contains('重试'));
    expect(m, contains('日志'));
    expectNoRawText(m);
  });
}
