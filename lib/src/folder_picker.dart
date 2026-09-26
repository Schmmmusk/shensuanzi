/// 系统「选择文件夹」对话框。
///
/// **全项目唯一调用 Flutter 插件的地方。** 单独一个文件的原因：
/// 插件在真机上的行为（取消返回什么、权限不够时抛什么）无法在本机验证，
/// 万一有问题，只需改这里 —— 不在 widget 里散落插件调用。
library;

import 'package:file_selector/file_selector.dart';

/// 打开系统文件夹选择器；用户取消或出错时返回 `null`（调用方按「没改」处理）。
Future<String?> pickDirectory() async {
  try {
    return await getDirectoryPath(confirmButtonText: '选这个文件夹');
  } catch (_) {
    return null;
  }
}
