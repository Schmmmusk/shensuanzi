// 扫码失败的中文解释（M03，2026-10-08）。
//
// 覆盖两件事：
// ① 归类：`MobileScannerErrorCode.name` → 三种可行动类别（未知值兜底 generic）；
// ② 措辞：**绝不回显英文原文**（「Camera permission denied.」这种），
//    且每一类都要给「怎么办」。
//
// ⚠️ 这里**不 import `mobile_scanner`** —— 本包是纯 Dart（见 `scan_error.dart`
// 文件头的边界说明），入参就是枚举的**名字符串**。
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

void main() {
  group('scanFailureKindOf（M03：插件错误码 → 可行动类别）', () {
    test('permissionDenied 是唯一「用户能自己修」的一类', () {
      expect(
        scanFailureKindOf('permissionDenied'),
        ScanFailureKind.permissionDenied,
      );
    });

    test('unsupported → 设备层面的问题', () {
      expect(scanFailureKindOf('unsupported'), ScanFailureKind.unsupported);
    });

    test('其余/未知错误码一律兜底 generic（宁可笼统，也不乱指引）', () {
      for (final String name in <String>[
        'genericError',
        'controllerDisposed',
        'controllerAlreadyInitialized',
        'controllerUninitialized',
        'controllerInitializing',
        'controllerNotAttached',
        '', // 空串也要能答，不能抛
        '某个将来才加的新错误码',
      ]) {
        expect(
          scanFailureKindOf(name),
          ScanFailureKind.generic,
          reason: 'name=$name',
        );
      }
    });
  });

  group('scanFailureMessage（M03：中文 + 「怎么办」，不回显英文）', () {
    test('三类文案都非空且是多行（含「怎么办」）', () {
      for (final ScanFailureKind kind in ScanFailureKind.values) {
        final String msg = scanFailureMessage(kind);
        expect(msg.trim(), isNotEmpty, reason: '$kind');
        expect(msg, contains('\n'), reason: '$kind 要有独立的「怎么办」一行');
      }
    });

    test('权限被拒：指路到系统设置里的「相机」权限（可执行）', () {
      final String msg = scanFailureMessage(ScanFailureKind.permissionDenied);
      expect(msg, contains('设置'));
      expect(msg, contains('相机'));
      expect(msg, contains('权限'));
    });

    test('**绝不出现插件英文原文 / 类名**（否则用户以为软件坏了）', () {
      const List<String> forbidden = <String>[
        'Camera permission denied',
        'Camera',
        'permission denied',
        'MobileScanner',
        'Exception',
        'unsupported',
      ];
      for (final ScanFailureKind kind in ScanFailureKind.values) {
        final String msg = scanFailureMessage(kind);
        for (final String bad in forbidden) {
          expect(
            msg,
            isNot(contains(bad)),
            reason: '$kind 的文案里不该出现「$bad」',
          );
        }
      }
    });
  });
}
