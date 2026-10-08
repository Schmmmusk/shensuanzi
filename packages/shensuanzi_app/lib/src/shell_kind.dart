/// 壳形态判定（§AH-5 / §BH·三 B1a）。
///
/// **判断放纯 Dart，Flutter 只摆放** —— `lib/src/app.dart` 把
/// `Platform.operatingSystem` 以**字符串**传入（本文件不 import `dart:io`，
/// 测试里随便造字符串就能覆盖全部分支，`dart test` 直接钉住）。
///
/// 非 Android 一律 [ShellKind.desktop]：Windows 行为**零变化**（§BH·B1 待确认 2），
/// iOS/macOS/web 等 未支持平台也落回桌面壳 —— 那些平台不在 v1 范围内，
/// 落桌面壳 = 明确的「未适配」，而不是装作能用。
library;

/// 壳的形态：桌面（左侧常驻导航）或移动（底部导航 5 入口）。
enum ShellKind { desktop, mobile }

/// 按操作系统名判壳。⚠️ 判定**只有一条**：`android` ⇒ 移动，其余 ⇒ 桌面。
ShellKind shellKindFor({required String operatingSystem}) =>
    operatingSystem == 'android' ? ShellKind.mobile : ShellKind.desktop;

/// 概览页「从这里开始」的指路文案（M05，2026-10-08）。
///
/// 桌面壳是**左侧常驻导航**，手机壳是**底部导航** —— 同一句话在两套壳里
/// 说错了地方就是错的（真机：手机上仍写「左边的功能列表」）。摆放由壳给
/// （`overview_page.dart` 的 `mobileShell` 参数），措辞在这里，`dart test` 钉得住。
String overviewNavHint({required bool mobileShell}) => mobileShell
    ? '底部的按钮一直可见：开单、查库存、管商品都在那里。'
    : '左边的功能列表一直可见：开单、查库存、管商品都在那里。';
