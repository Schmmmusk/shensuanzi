/// 手机端「保留入口 + 点击引导」对话框（C2·§CC 裁定三）。
///
/// 文案与判定在 app 包 `mobile_guidance.dart`（纯 Dart，UI 不造句铁律）；
/// 本文件只负责把它摆成一个 AlertDialog。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

/// 弹「这一步在电脑上做」引导。手机端主数据禁建的各处入口共用
/// （往来 / 商品 / 账户的新建与编辑、期初录入 —— 清单见 `MobileGuideTopic`）。
Future<void> showMobileGuideDialog(
  BuildContext context,
  MobileGuideTopic topic,
) async {
  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(mobileGuideTitle(topic)),
      content: Text(
        mobileGuideMessage(topic),
        style: const TextStyle(height: 1.6),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
