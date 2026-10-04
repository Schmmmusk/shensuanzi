import 'dart:async';
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'src/app.dart';

/// 真正的入口。这里只做**跟「出错了怎么留下现场」有关的事**，业务在 [ShensuanziApp]。
///
/// ## 为什么要有日志（§AG-5 裁定）
///
/// 目标用户（个体户 / 中老年）遇到问题**只会说「打不开了」** ——
/// 没有日志，客服 / 开发者拿不到任何现场：不知道版本、不知道系统、
/// 不知道崩在哪一行。文件很小、成本极低，但把「无法定位」变成「一眼看到堆栈」。
///
/// ## 两条捕获路径（缺一不可）
///
/// | 路径 | 抓什么 |
/// |---|---|
/// | `FlutterError.onError` | **框架内**异常：build / layout / 手势回调里抛的 |
/// | `runZonedGuarded` | **异步**异常：没被 await 的 Future 抛出来的 |
///
/// 两者覆盖了「用户看到界面卡住 / 白屏」的绝大多数成因。
/// ⚠️ **刻意不设 `PlatformDispatcher.instance.onError`** —— 设了它之后引擎错误
/// 不再走 zone，两条路径会**重复记同一次崩溃**，反而干扰排障。
///
/// ## 日志放哪
///
/// 跟随配置文件：`%APPDATA%\神算子\日志\神算子-日志.txt`
/// （**不放在数据目录** —— 那里是用户会拷来拷去的经营数据，见 `log.dart` 文件头）
void main() {
  // §BH·五 B1b（2026-10-04 裁定）：Android 的 config/log 要先定位到**应用私有
  // 目录**（path_provider，异步）才能建，而 %APPDATA% 在 Android 上不存在 ——
  // 走独立引导。桌面路径**一字不改**（Windows 行为零变化，§BH B1 待确认 2）。
  if (shellKindFor(operatingSystem: Platform.operatingSystem) ==
      ShellKind.mobile) {
    _mainMobile();
    return;
  }
  _mainDesktop();
}

Future<void> _mainMobile() async {
  // 必须先初始化：path_provider 的平台通道与 FlutterError.onError 都依赖绑定
  WidgetsFlutterBinding.ensureInitialized();

  // 私有目录 = /data/user/0/<pkg>/files（getFilesDir，§BH·四 补正 1）。
  // config/log 沿用桌面的相对布局：<base>/神算子/config.json + <base>/神算子/日志/。
  final Directory support = await getApplicationSupportDirectory();
  final AppConfigStore store = AppConfigStore(
    File(p.join(support.path, '神算子', 'config.json')),
  );
  final AppLog log = AppLog.besideConfig(store);

  runZonedGuarded<void>(() {
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      log.crash(details.exception, details.stack ?? StackTrace.current);
    };

    log.startup(
      appVersion: AppVersion.value,
      schemaVersion: '${Schema.version}',
    );

    runApp(
      ShensuanziApp(
        configStore: store,
        // §AH-6：私有目录根，app.dart 据此组织 data/backup/export（B1b）
        dataRoot: support.path,
      ),
    );
  }, (Object error, StackTrace stack) {
    log.crash(error, stack);
  });
}

void _mainDesktop() {
  final AppEnvironment environment = AppEnvironment.detect();
  final AppLog log = AppLog.besideConfig(
    AppConfigStore.forEnvironment(environment),
  );

  runZonedGuarded<void>(() {
    // 必须先初始化：`FlutterError.onError` 与 `runApp` 都依赖绑定
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (FlutterErrorDetails details) {
      // 保留 Flutter 原有的控制台输出（开发时看得到）
      FlutterError.presentError(details);
      log.crash(details.exception, details.stack ?? StackTrace.current);
    };

    // 启动行：时间 + 版本 + 数据格式版本 + 操作系统 —— 排障的四问一次答完
    log.startup(
      appVersion: AppVersion.value,
      schemaVersion: '${Schema.version}',
    );

    // 环境探测降级：**不弹窗**（这是启动路径，弹窗只会让用户以为软件坏了），
    // 只留一条日志。两种降级分开记（`docs/reply_review.md` §AT / §AT·六-3）：
    //   ① 盘符枚举整体失败 ⇒ 本次按「没有非系统盘」处理
    //   ② 某些盘符占着位、但类型问不出来 ⇒ 已跳过
    // 没有它，「软件能开、但某块盘不见了」永远查不出原因。
    if (environment.isWindows && environment.drives.isEmpty) {
      log.write('环境探测降级：盘符枚举失败，本次按「没有非系统盘」处理');
    }
    if (environment.probeFailures.isNotEmpty) {
      log.write(
        '环境探测降级：${environment.probeFailures.join('、')} 盘的类型问不出来，已跳过这些盘',
      );
    }

    runApp(const ShensuanziApp());
  }, (Object error, StackTrace stack) {
    log.crash(error, stack);
  });
}
