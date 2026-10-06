/// 扫码配对页（§BL·三，2026-10-05 裁定 ③）。
///
/// ## 权限的两段式
///
/// 先给**理由文案**（「神算子需要相机权限来扫描电脑上的配对二维码。
/// 扫码只在本机处理，不会上传。」—— 裁定原文），用户点「开始扫码」
/// 才挂 `MobileScanner` —— 相机的系统权限弹窗在这一刻触发。
/// **不引 `permission_handler`**：`mobile_scanner` 启动即请求权限，
/// 理由前置 + 一次点击，少一个第三方依赖。
///
/// ## 流程
///
/// 扫到码 → `service.pairFromCode` 解析（非法码 = 页面内红字提示，不退出）
/// → 立即 `syncNow()` 首拉（成功才 pop 回设置页；失败把原因留在页面上，
/// 让用户能看着改）。
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

/// 返回值：配对 + 首拉都成功时的提示语；取消/失败返回 `null`。
Future<String?> showPairingScanPage(BuildContext context, MobileSyncService service) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (BuildContext context) => PairingScanPage(service: service)),
    );

class PairingScanPage extends StatefulWidget {
  const PairingScanPage({super.key, required this.service});

  final MobileSyncService service;

  @override
  State<PairingScanPage> createState() => _PairingScanPageState();
}

class _PairingScanPageState extends State<PairingScanPage> {
  /// `null` = 还在给理由 / 没开始扫
  bool _scanning = false;

  /// 扫码 / 连接过程中的错误（页内红字，不退出 —— 用户能照着改）
  String? _error;

  /// 首拉进行中（扫到码之后、pop 之前）
  bool _busy = false;

  /// 防重复处理同一帧的多个码
  bool _handled = false;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled || _busy) return;
    for (final Barcode barcode in capture.barcodes) {
      final String? raw = barcode.rawValue;
      if (raw == null || !raw.startsWith('shensuanzi://pair')) continue;
      _handled = true;
      await _pair(raw);
      return;
    }
  }

  Future<void> _pair(String raw) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.service.pairFromCode(raw);
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _handled = false;
          _error = '${error.message} 请对着电脑设置页上的二维码重新扫。';
        });
      }
      return;
    }
    // 首拉：成功才回设置页；失败把原因留在页面上（配对信息已存，
    // 用户可以回设置页直接「立即同步」重试，不用再扫一次）。
    // ⚠️ syncNow 的结果保证不抛（服务内全兜底），但这里再兜一层 ——
    // 转圈永远停不下来比报错糟糕一万倍（真机踩过：§BL·落地·补 1）
    SyncOutcome outcome;
    try {
      outcome = await widget.service.syncNow();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _handled = false;
          _error = '同步时出错（$error）—— 请回设置页重试，或重新扫码。';
        });
      }
      return;
    }
    if (!mounted) return;
    if (outcome.kind == SyncOutcomeKind.ok) {
      Navigator.of(context).pop(outcome.message);
      return;
    }
    setState(() {
      _busy = false;
      _handled = false;
      _error = outcome.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('扫码连接主机')),
      body: _busy
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('连接主机、拉取数据…', style: TextStyle(height: 1.6)),
                ],
              ),
            )
          : _scanning
              ? Column(
                  children: <Widget>[
                    if (_error != null)
                      Container(
                        width: double.infinity,
                        color: theme.colorScheme.errorContainer,
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _error!,
                          style: TextStyle(height: 1.6, color: theme.colorScheme.error),
                        ),
                      ),
                    Expanded(
                      child: MobileScanner(
                        onDetect: (BarcodeCapture capture) => _onDetect(capture),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '对着电脑「设置 → 多设备同步」里的二维码。',
                        style: TextStyle(height: 1.6, color: theme.textTheme.bodySmall?.color),
                      ),
                    ),
                  ],
                )
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        '神算子需要相机权限来扫描电脑上的配对二维码。'
                        '扫码只在本机处理，不会上传。',
                        style: TextStyle(height: 1.6),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '先在电脑上打开「设置 → 多设备同步」，把二维码显示出来。',
                        style: TextStyle(
                          height: 1.6,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                      if (_error != null) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(height: 1.6, color: theme.colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: () => setState(() => _scanning = true),
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('开始扫码'),
                      ),
                    ],
                  ),
                ),
    );
  }
}
