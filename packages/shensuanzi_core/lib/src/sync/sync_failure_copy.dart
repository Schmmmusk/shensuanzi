// 同步队列「失败条目」的用户文案：reason_code + last_error 到一句「怎么办」。
//
// #24 的落地，2026-11-05 裁定甲（N-e）：可达码全接，业务拒绝保留主机原文。
//
// 为什么单独一个文件、而且在 core：判据是纯映射，不碰控件也不碰插件。摆进
// Flutter 就只能起壳测，放 core 可以直接喂枚举（test/sync_failure_copy_test.dart）。
// 与 sync_failure.dart 是一对：那个管「主机给客户端」的回执怎么写，这个管
// 「客户端给用户」的话怎么说。
//
// 三条规则：
// 1. 业务拒绝透传（rule_validation_failed / return_exceeds_original）：主机那句
//    中文是规则层写的、带具体数字（原单共 2、累计 3），是用户唯一能照做的线索。
//    换成通用文案等于把唯一有用的信息扔掉。
// 2. 其余码替换：主机那句是给对账的人看的（提到对象不存在），而用户需要的是下一步
//    动作。尤其 reference_missing，它是唯一「等一会儿重推就好」的码，照原文显示会
//    让人以为单子废了。
// 3. 认不出的码不许降级成「原因不明」：reason_code 只增不改，主机可以比客户端新
//    （RejectCode.fromWire 故意返回 null 而不是抛）。遇到新码时退回主机中文，
//    宁可笼统，也不丢信息。
//
// 文案要过 forbiddenDevTermsInUserText（数据库要说数据文件，参数是禁词）。
// 测试逐个断言，改文案前先跑 sync_failure_copy_test。
import '../reject_code.dart';

// 透传组的兜底句（正常情况下不会从这里返回，syncQueueFailureText 已提前处理）。
// 单独抽出来是为了让 switch 的穷尽性检查继续生效：加了新 RejectCode 而忘了在这里
// 表态，编译就过不去（比运行时静默降级好）。
const String _ruleRejectionFallback =
    '这张单里的数量或金额电脑不同意，请改小一点后再传。';

// 队列条目 reason_code 的原始字符串（SyncQueueEntry.reasonCode，可为 null）。
//
// 返回一句给用户看的话：说清「发生了什么」加「下一步做什么」。
String syncQueueFailureText({
  required String? reasonCode,
  required String? lastError,
}) {
  final String? trimmed =
      (lastError == null || lastError.isEmpty) ? null : lastError;
  final RejectCode? code = RejectCode.fromWire(reasonCode);

  // 1) 业务拒绝：主机的中文比任何固定文案都有用，原样透传。
  if (code == RejectCode.ruleValidationFailed ||
      code == RejectCode.returnExceedsOriginal) {
    return trimmed ?? _ruleRejectionFallback;
  }

  // 2) 认识的码：一句「怎么办」。
  if (code != null) return _actionText(code);

  // 3) 没有码、或认不出的新码：退回原文。换主机挂起那段话就走这里 —— 它本身就是
  //    写给用户看的中文，按码分支绝不能把它盖掉。
  return trimmed ??
      '推送没成功，原因不明。可以点「重试」再传一次，或者把这张单删掉重开。';
}

// 每个码的专属文案。
//
// 枚举有 19 个码，逐个都要有归属（测试「RejectCode 覆盖」组钉住「没有第三种」）。
// 「协议没写对」那一类七个码共用一句：它们全是「客户端发了主机不收的东西」，
// 用户能做的动作完全相同，拆成七句只会让六句是废话。
String _actionText(RejectCode code) {
  switch (code) {
    // —— 用户能自己做点什么的：各自一句 ——
    case RejectCode.referenceMissing:
      // 唯一「等一会儿重推就好」的码：先拉一次，把缺的资料拿到，这条会自动重传。
      return '这条单要用的资料在电脑上还没有。先同步一次（点「立即同步」），之后会自动重传，不用重开这张单。';
    case RejectCode.unknownAction:
      return '电脑上的软件版本太旧，不认识这张单要做的事。请在电脑上更新软件，然后回来重试。';
    case RejectCode.targetMissing:
      return '要改的那张单在电脑上已经变了或者没了。请先刷新列表确认它现在的状态，再决定要不要重开一张。';
    case RejectCode.fieldTypeMismatch:
      return '手机上的软件版本和电脑对不上。请把手机上的软件更新到最新版，再传这张单。';
    case RejectCode.hostStorage:
      return '电脑存不下这笔数据（磁盘满了，或者数据文件正被别的程序占用）。请在电脑上腾出地方后点「重试」。';
    case RejectCode.duplicate:
      return '这张单电脑上已经收到过了，不用再传一遍。请先同步一次，确认它已经在列表里。';
    case RejectCode.dataInvalid:
      return '这张单里有填得不对的地方，电脑没有收下。请回到单据里核对数量和金额，改好后重开一张。';
    case RejectCode.unsupportedDocType:
      return '这种单据电脑还不认识。请在电脑上更新软件后再传这张单。';
    case RejectCode.actionNotApplicable:
      return '这张单现在的状态不允许做这一步。请先刷新，看看它是不是已经处理过了。';
    case RejectCode.ruleInternalError:
      // 与 sync_failure.dart 的 ruleInternalErrorReason 同一立场：用户修不了，
      // 但要给出出口（日志在电脑上，不在本机）。
      return '电脑处理这张单时自己出了错，不是你的操作问题。请把电脑上记录的日志发给帮你装软件的人。';

    // —— 「协议没写对」七个码：用户动作完全相同，共用一句 ——
    case RejectCode.notWritableTable:
    case RejectCode.unknownField:
    case RejectCode.unwritableColumn:
    case RejectCode.missingField:
    case RejectCode.idMismatch:
    case RejectCode.malformedParameter:
    case RejectCode.payloadMutuallyExclusive:
      return '这条数据手机发得不对，电脑没有收下。请把手机上的软件更新到最新版；如果还不行，请重开这张单。';

    // —— 透传组在上面已处理；这里只为穷尽性检查存在 ——
    case RejectCode.ruleValidationFailed:
    case RejectCode.returnExceedsOriginal:
      return _ruleRejectionFallback;
  }
}
