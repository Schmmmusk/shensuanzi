// 版本号一致性（§AG-1）。
//
// 起因是**真实缺陷**：`pubspec.yaml` 写着 `1.0.0+1`，帮助页写着 `v0.1.0` ——
// 两处不一致，用户看到的版本和构建出来的版本不是一个东西。
//
// 这条断言把「两处必须一起改」变成测试期就能发现的事：
// 读 `pubspec.yaml`，与 `AppVersion`（**唯一来源**）逐字段比对。
//
// ⚠️ 为什么不让代码直接读 pubspec：那需要 `package_info_plus` 之类的依赖，
// 而这个项目坚持不引「为了一行版本号」的依赖。**用断言钉住，比引依赖便宜。**
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

void main() {
  test('AppVersion 与 pubspec.yaml 的 version 一致（§AG-1）', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch? match = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(match, isNotNull, reason: 'pubspec.yaml 里找不到 version: 行');

    // 形态：<版本>+<构建号>
    final List<String> parts = match!.group(1)!.split('+');
    expect(parts, hasLength(2), reason: 'version 必须是 `x.y.z+n` 形态');

    expect(
      parts.first,
      AppVersion.value,
      reason:
          'pubspec 的版本号与 AppVersion.value 不一致 —— '
          '改一边忘了另一边（用户看到的与构建出来的就会不是一个东西）',
    );
    expect(
      int.parse(parts[1]),
      AppVersion.build,
      reason: '构建号不一致（Windows 的文件版本会跟着 pubspec 走）',
    );
  });

  /// 1..99 的中文数字（只覆盖本仓会用到的范围）。
  ///
  /// ⚠️ **不手抄**「第九个 / 第十个」：那样每 bump 一次版本要改两个文件，
  /// 而漏改的那一边只有跑测试才发现。这里从 `AppVersion.build` **算**出来，
  /// 于是 `version.dart` 是唯一需要动的地方（2026-10-31 改成这样）。
  String chineseNumeral(int n) {
    const List<String> digits = <String>[
      '零',
      '一',
      '二',
      '三',
      '四',
      '五',
      '六',
      '七',
      '八',
      '九',
    ];
    if (n <= 0 || n >= 100) throw ArgumentError('只支持 1..99，收到 $n');
    if (n < 10) return digits[n];
    if (n == 10) return '十';
    if (n < 20) return '十${digits[n - 10]}';
    final int tens = n ~/ 10;
    final int ones = n % 10;
    return ones == 0 ? '${digits[tens]}十' : '${digits[tens]}十${digits[ones]}';
  }

  test('给用户看的版本号带限定词（§AG-1：消除「是不是试用版」的疑虑）', () {
    expect(AppVersion.display, contains(AppVersion.value));
    expect(
      AppVersion.display,
      contains('第${chineseNumeral(AppVersion.build)}个可部署版本'),
      reason:
          '限定词必须与 `AppVersion.build` 一致（这里是从 build 算出来的，'
          '不是手抄的）—— 不一致说明 `version.dart` 的 display 忘了改',
    );
  });

  test('Runner.rc 的 ProductVersion 与 AppVersion.value 一致（§AG-1）', () {
    final String rc = File('windows/runner/Runner.rc').readAsStringSync();
    final RegExpMatch? match = RegExp(
      r'VALUE\s+"ProductVersion"\s*,\s*"([^"]+)"',
    ).firstMatch(rc);

    expect(
      match,
      isNotNull,
      reason:
          'Runner.rc 里必须有一条「带引号字面量」的 ProductVersion '
          '（用宏 `VERSION_AS_STRING` 会带上构建号，属性页会显示成 0.1.0+1）',
    );
    expect(
      match!.group(1),
      AppVersion.value,
      reason:
          'Runner.rc 的 ProductVersion 是写死的 —— 改版本号时这里也要改，'
          '它在「文件属性」里用户直接能看到',
    );
  });

  test('Runner.rc 保持纯 ASCII（裁定：编码一致性 > 没人看的属性页）', () {
    final List<int> nonAscii = File(
      'windows/runner/Runner.rc',
    ).readAsBytesSync().where((int b) => b > 127).toList();

    expect(
      nonAscii,
      isEmpty,
      reason:
          'rc.exe 按**系统代码页**解码源文件（简体中文机器 = GBK），'
          '而 Flutter 生成的 CMake 的 `/utf-8` 是语言限定的（只给 C/C++），'
          '管不到资源编译器（`docs/windows_build.md` §7.1）。'
          '⚠️ 注意：rc.exe 本身**支持** `/utf-8`（MSVC 2019 16.x 起）——'
          '保持 ASCII 是**代价收益的裁定**，不是技术上做不到。',
    );
  });

  test('Runner.rc 的 FileDescription 是裁定固定的英文字符串（§AG-7）', () {
    final String rc = File('windows/runner/Runner.rc').readAsStringSync();
    final RegExpMatch? m = RegExp(
      r'VALUE\s+"FileDescription"\s*,\s*"([^"]+)"',
    ).firstMatch(rc);
    expect(m, isNotNull, reason: '找不到 FileDescription');
    expect(
      m!.group(1),
      'Shensuanzi - Inventory & Bookkeeping',
      reason:
          '2026-09-29 裁定：属性页保持英文；`&` 代替 `and` + '
          '首字母大写是属性页观感（40 字符栏宽里更紧凑）',
    );
  });
}
