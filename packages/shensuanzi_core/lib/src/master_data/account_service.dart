/// 账户建档服务：草稿 → 校验 → 落库，与 `ProductService` 同构。
///
/// ## 为什么这一层存在
///
/// - **草稿校验不能假设调用方做过** —— 将来的同步层 / 导入入口可能直接调它
/// - **「编辑不改期初余额」钉在这里**（Z-3 方案 A）：`update` 从库里读回
///   原值写回，**草稿里的期初余额被忽略** —— 就算调用方绕过 UI 传了新值，
///   历史余额也不会被重算
library;

import '../dao/account_dao.dart';
import '../dao/query_dao.dart';
import '../models/account.dart';
import '../util/ids.dart';
import 'account_draft.dart';

/// 草稿校验失败：**带字段级原因**，界面直接标红对应输入框。
class AccountDraftInvalid implements Exception {
  AccountDraftInvalid(this.fieldErrors);

  final Map<AccountField, String> fieldErrors;

  /// 拼成一句话（日志 / 汇总提示用）
  String get summary => fieldErrors.values.join('；');

  @override
  String toString() => 'AccountDraftInvalid($summary)';
}

/// 账户建档服务。
class AccountService {
  AccountService(this._dao);

  final AccountDao _dao;

  /// 新建账户。
  ///
  /// 校验不通过抛 [AccountDraftInvalid]；`id` / 时间戳 / 版本列在这里补齐，
  /// 调用方（表单）不用知道。
  Account create(AccountDraft draft, {int? now}) {
    final Map<AccountField, String> errors = draft.validate();
    if (errors.isNotEmpty) {
      throw AccountDraftInvalid(errors);
    }
    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;
    final Account account = Account(
      id: newId(),
      name: draft.name.trim(),
      type: draft.type!,
      initialBalance: draft.initialBalanceCents,
      createdAt: stamp,
      updatedAt: stamp,
    );
    _dao.insert(account);
    return account;
  }

  /// 编辑账户（名称 / 类型）。
  ///
  /// ⚠️ **期初余额以库里的原值为准**（Z-3 方案 A）—— 草稿里的
  /// `initialBalance` 被忽略。要「改期初」就新建账户 + 停用这个。
  ///
  /// [id] 不存在抛 [StateError]（同步层绕过 UI 时也不会静默造错）。
  Account update(String id, AccountDraft draft, {int? now}) {
    final Map<AccountField, String> errors = draft.validate();
    if (errors.isNotEmpty) {
      throw AccountDraftInvalid(errors);
    }
    final Account? existing = _dao.findById(id);
    if (existing == null) {
      throw StateError('账户不存在或已删除，请刷新后重试');
    }
    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;
    final Account updated = Account(
      id: existing.id,
      name: draft.name.trim(),
      type: draft.type!,
      // 原值写回 —— 编辑路径上期初余额**不可变**（历史不可篡改）
      initialBalance: existing.initialBalance,
      isActive: existing.isActive,
      createdAt: existing.createdAt,
      updatedAt: stamp,
      syncVersion: existing.syncVersion + 1,
    );
    _dao.update(updated);
    return updated;
  }

  /// 停用 / 恢复（软删：行还在，`is_active` 翻转，版本 +1）。
  Account setActive(String id, {required bool active, int? now}) {
    final Account? existing = _dao.findById(id);
    if (existing == null) {
      throw StateError('账户不存在或已删除，请刷新后重试');
    }
    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;
    final Account updated = Account(
      id: existing.id,
      name: existing.name,
      type: existing.type,
      initialBalance: existing.initialBalance,
      isActive: active,
      createdAt: existing.createdAt,
      updatedAt: stamp,
      syncVersion: existing.syncVersion + 1,
    );
    _dao.update(updated);
    return updated;
  }

  /// 列表。默认只看启用中的（[active] 传 `null` 看全部）。
  List<Account> list({bool? active = true}) => _dao.findAll(active: active);

  /// 每个账户的当前余额（含期初 + 全部流水）。
  Map<String, int> balances() {
    final QueryDao queries = QueryDao(_dao.db);
    return queries.accountBalances();
  }
}
