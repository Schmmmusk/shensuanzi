/// 导航图标映射表：`iconKey`（纯 Dart 里的名字）→ `IconData`。
///
/// 导航结构存在 `shensuanzi_app`（纯 Dart，可 `dart test`），所以那里只能存
/// **图标名**。这张表是唯一的映射点。
///
/// **查不到时用兜底图标** —— 写错一个名字只会让那一个图标变样，
/// **不会崩**（导航是启动路径上的东西，不能因为一个图标名让程序打不开）。
library;

import 'package:flutter/material.dart';

IconData navIcon(String key) {
  switch (key) {
    case 'dashboard':
      return Icons.dashboard;
    case 'point_of_sale':
      return Icons.point_of_sale;
    case 'inventory_2':
      return Icons.inventory_2;
    case 'category':
      return Icons.category;
    case 'warehouse':
      return Icons.warehouse;
    case 'description':
      return Icons.description;
    case 'people':
      return Icons.people;
    case 'account_balance_wallet':
      return Icons.account_balance_wallet;
    case 'settings':
      return Icons.settings;
    case 'help_outline':
      return Icons.help_outline;
    default:
      return Icons.circle_outlined;
  }
}
