/// 同步失败的**人话文案**（F15，2026-10-25 复跑；裁定见台账 §CV·一百零九）。
///
/// ## 它解决什么
///
/// 复跑实测：手机端把 `Bad state: 落库 products 的行（…）失败：UNIQUE constraint failed:
/// products.code 若为 UNIQUE 冲突：… 修复路径是重建镜像 + 全量重新拉取（游标清空即从头拉）。`
/// **原样印在界面上** —— 用户看到的是源码，不是「我该怎么办」。
///
/// 这违反项目自己的 **M15 两通道**（原始异常只进日志、界面给分类文案）：
/// 详情页、启动页都执行了，唯独同步这条漏了。
///
/// ## 规矩
///
/// - **只按类别说话**：每类给一句人话 + **一个动作**（重试 / 重建 / 更新版本 / 找技术支持）；
/// - **绝不拼接 `error.toString()`**（那是日志的事，由 `MobileSyncService.onError` 转出去）；
/// - 纯函数、无 Flutter 依赖 ⇒ 可逐类断言（见 `test/sync_failure_message_test.dart`）。
library;

import 'package:shensuanzi_core/shensuanzi_core.dart' show SyncHttpException;

/// 把同步异常翻译成「用户能照做」的一句话。
String syncFailureMessage(Object error) {
  // ① 传输层已分类（连不上 / 超时 / 401）—— 它自己的文案就是人话，直接用
  if (error is SyncHttpException) return error.detail;

  final String raw = error.toString();

  // ② 编码冲突 = 镜像里还留着另一台主机的商品（F14 的现场）
  if (raw.contains('UNIQUE constraint')) {
    return '本机存的数据和电脑上的对不上（有同名的编码）。'
        '到「设置 → 多设备同步」点一次「重建本机数据副本」就能修好 —— '
        '你还没传上去的单不会丢。';
  }

  // ③ 数据库本身出了问题（打不开 / 表缺了 / 库坏了）
  if (raw.contains('SqliteException') ||
      raw.contains('database') ||
      raw.contains('Database')) {
    return '手机上的数据文件打不开（可能被清理软件删了、或存储空间不够）。'
        '先点「重试」；一直这样请到「设置 → 多设备同步」点「重建本机数据副本」。';
  }

  // ④ 网络层（没经过 SyncHttpException 的那些）
  if (raw.contains('SocketException') ||
      raw.contains('TimeoutException') ||
      raw.contains('Connection refused')) {
    return '连不上电脑。确认两台设备连着同一个 Wi-Fi、电脑上的同步开关还开着，然后再试。';
  }

  // ⑤ 两端对不上话（版本不一致 / 返回格式变了）
  if (raw.contains('FormatException') ||
      raw.contains('type ') ||
      raw.contains('is not a subtype')) {
    return '电脑回的内容看不懂 —— 手机和电脑可能不是同一个版本，都更新到最新版再试。';
  }

  // ⑥ 兜底：不猜原因，给"重试 + 找技术支持"，原始异常进日志
  return '同步时出了点问题。先点「重试」；一直这样请把软件的日志发给技术支持。';
}
