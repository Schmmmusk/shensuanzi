/// 系统「选择文件夹」对话框。
///
/// **全项目唯一调用 Flutter 插件的地方 —— 也是唯一被注入的地方。**
///
/// 它是唯一会「卡住测试」的依赖（真弹系统框，widget 测试直接挂死），
/// 所以 `ShensuanziApp`（`lib/src/app.dart`）把它做成可选参数，
/// 测试传桩、生产用默认值。
/// 于是这个文件**不再是一个实现，而是一个注入点** ——
/// 将来 Android 端要换「选择文件夹」的方案，只改这里。
///
/// 单独一个文件的原因：插件在真机上的行为（取消返回什么、权限不够时抛什么）
/// 无法在本机验证，万一有问题，只需改这里 —— 不在 widget 里散落插件调用。
library;

import 'package:file_selector/file_selector.dart';

/// 打开系统文件夹选择器；用户取消或出错时返回 `null`（调用方按「没改」处理）。
///
/// 名字刻意与参数名 `pickDirectory` 区分开：**参数名到处都是，
/// 真实实现只有这一个**。
Future<String?> pickFolderFromSystem() async {
  try {
    return await getDirectoryPath(confirmButtonText: '选这个文件夹');
  } catch (_) {
    return null;
  }
}
