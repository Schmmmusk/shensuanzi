import 'package:flutter/scheduler.dart';

/// 让**忙碌态先画出来**，再开始干重活。
///
/// ## 为什么必须有这一句（2026-11-09，用户实测「点了没反应 → 假死 → 忽然好了」）
///
/// `setState(() => _busy = true)` 只是**标记重建**：帧要等当前这个同步块
/// 跑完才会画。而导出 / 备份的重活是在 `await` 之前就**同步**跑起来的 ——
/// 实测（26.4 万单，PC/NVMe）：查库 1.7 s + 拼表 2.0 s + 拼 CSV 0.6 s = **4.4 s**。
/// 于是「导出中…」这行字**永远画不出来**，用户看到的就是假死。
///
/// `endOfFrame` 在空闲时会**自己排一帧**（`SchedulerBinding` 的行为），
/// 所以调用方不需要再 `scheduleFrame()`。
///
/// ⚠️ 这一句只保证「反馈是真的」，**不减少**任何耗时 —— 重活该挪 isolate 还得挪
/// （见 `ExportService` 的单据导出与 `BackupService` 的校验）。
Future<void> letBusyStatePaint() => SchedulerBinding.instance.endOfFrame;
