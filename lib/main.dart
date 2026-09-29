import 'dart:async';

import 'package:flutter/material.dart';
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

    runApp(const ShensuanziApp());
  }, (Object error, StackTrace stack) {
    log.crash(error, stack);
  });
}
