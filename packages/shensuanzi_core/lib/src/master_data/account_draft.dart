/// 账户建档的**表单草稿**（原文 + 纯函数校验），与 `ProductDraft` 同构。
///
/// ## 期初余额（Z-3 裁定 = 方案 A，`docs/reply_review.md` §Z）
///
/// - **新建时可填**（默认 0）—— 期初余额就是「建账那一刻手头有多少钱」
/// - **编辑时不可改**：`initial_balance` 的修改会**重算全部历史余额**
///   （`data_model.md` §2.3），等于篡改历史 —— 真填错了，
///   走「新建一个账户 + 停用老账户」，30 秒的事
/// - 只收 ≥ 0：负的期初余额对「现金 / 微信 / 支付宝」都是错的；
///   有欠款先用备注记下来（v1 不做负债账户）
library;

import '../models/account.dart';
import '../util/money.dart';

/// 主单级字段（错误定位的键 —— 界面据此知道该标红哪一栏）
enum AccountField { name, type, initialBalance }

/// 账户建档草稿。
class AccountDraft {
  const AccountDraft({
    this.name = '',
    this.type,
    this.initialBalance = '',
  });

  /// 从已有账户回填（编辑用）。
  ///
  /// ⚠️ 期初余额**不回填进可编辑字段**（Z-3 方案 A：编辑不可改）——
  /// 界面把它显示成只读文本；服务层 `update` 也以库里的原值为准，
  /// 本草稿的 [initialBalance] 在编辑路径上被忽略。
  factory AccountDraft.of(Account account) => AccountDraft(
    name: account.name,
    type: account.type,
  );

  final String name;

  /// 账户类型（界面下拉选择，不存在「敲错」的原文，直接持枚举）
  final AccountType? type;

  /// 期初余额的**原文**（元）；空 = 0
  final String initialBalance;

  AccountDraft copyWith({
    String? name,
    AccountType? type,
    bool clearType = false,
    String? initialBalance,
  }) => AccountDraft(
    name: name ?? this.name,
    type: clearType ? null : (type ?? this.type),
    initialBalance: initialBalance ?? this.initialBalance,
  );

  // ------------------------------------------------------------ 校验

  /// 主单级校验。**空 map = 通过**。
  Map<AccountField, String> validate() {
    final Map<AccountField, String> errors = <AccountField, String>{};

    final String nameText = name.trim();
    if (nameText.isEmpty) {
      errors[AccountField.name] = '请填账户名称，比如「现金」或「微信收款」';
    } else if (nameText.length > 60) {
      errors[AccountField.name] = '名称太长了，请改到 60 字以内';
    }

    if (type == null) {
      errors[AccountField.type] = '请选一个账户类型';
    }

    final String text = initialBalance.trim();
    if (text.isNotEmpty) {
      final int? cents = Money.tryParseYuan(text);
      if (cents == null) {
        errors[AccountField.initialBalance] =
            '期初余额只能填数字，最多两位小数，比如 1000';
      } else if (cents < 0) {
        errors[AccountField.initialBalance] = '期初余额不能是负数；有欠款先写在备注里';
      }
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  // ------------------------------------------------------------ 取值（校验通过后）

  /// 期初余额（分）；空 = 0
  int get initialBalanceCents {
    final String text = initialBalance.trim();
    if (text.isEmpty) return 0;
    return Money.tryParseYuan(text) ?? 0;
  }

  @override
  String toString() =>
      'AccountDraft($name, type=${type?.wire}, initial=$initialBalance)';
}
