/// 账户建档的降级门禁（对应 `test/account_draft_test.dart`）。
///
/// ⚠️ **改一边必须改另一边** —— `test/**` 是正式门禁，本脚本是
/// 「跑不了 `dart test` 时的降级门禁」（`docs/testing.md` §零）。
///
/// ⚠️ **服务段每用例独立内存库** —— 前面的用例建过的账户会污染
/// `count` / `list` 断言（§零 的跨段复用坑）。
///
/// 运行：`dart run tool/selfcheck_account.dart`
library;

import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $name');
  } else {
    _fail++;
    _failures.add(name);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  →  $detail'}');
  }
}

void section(String title) => stdout.writeln('\n── $title ──');

void main() {
  useLocalSqlite();

  int clock = 1700000000000;
  int now() => clock++;

  // ============================================================ 草稿校验
  section('AccountDraft 校验');
  {
    AccountDraft goodDraft({
      String name = '现金',
      AccountType? type = AccountType.cash,
      String initialBalance = '',
    }) => AccountDraft(name: name, type: type, initialBalance: initialBalance);

    check('合法草稿（期初余额留空 = 0）', () {
      final AccountDraft d = goodDraft();
      return d.validate().isEmpty && d.initialBalanceCents == 0;
    }());

    check('名称必填：空 / 全空格 / 超长都拦', () {
      return (goodDraft(name: '').validate()[AccountField.name] ?? '')
              .contains('请填账户名称') &&
          (goodDraft(name: '   ').validate()[AccountField.name] ?? '')
              .contains('请填账户名称') &&
          (goodDraft(name: '长' * 61).validate()[AccountField.name] ?? '')
              .contains('60 字以内');
    }());

    check(
      '类型必选',
      (goodDraft(type: null).validate()[AccountField.type] ?? '')
          .contains('请选一个账户类型'),
    );

    check('期初余额：合法收 / 非法拦 / 负数拦', () {
      final AccountDraft ok = goodDraft(initialBalance: ' 1000.50 ');
      return ok.validate().isEmpty &&
          ok.initialBalanceCents == 100050 &&
          (goodDraft(initialBalance: 'abc')
                  .validate()[AccountField.initialBalance] ?? '')
              .contains('只能填数字') &&
          (goodDraft(initialBalance: '1.005')
                  .validate()[AccountField.initialBalance] ?? '')
              .contains('两位小数') &&
          (goodDraft(initialBalance: '-5')
                  .validate()[AccountField.initialBalance] ?? '')
              .contains('不能是负数');
    }());

    check('一次能报多个字段', () {
      const AccountDraft d = AccountDraft();
      return d.validate().containsKey(AccountField.name) &&
          d.validate().containsKey(AccountField.type);
    }());
  }

  // ============================================================ 服务
  section('AccountService');
  {
    /// 一套全新的环境（独立 Db）
    (Db, AccountService) newEnv() {
      final Db db = Db.openInMemory();
      return (db, AccountService(AccountDao(db)));
    }

    check('create：补齐列；期初余额元 → 分；名称 trim', () {
      final (Db db, AccountService service) = newEnv();
      final Account a = service.create(
        AccountDraft(
          name: ' 微信收款 ',
          type: AccountType.wechat,
          initialBalance: '500',
        ),
        now: now(),
      );
      final bool ok = a.name == '微信收款' &&
          a.type == AccountType.wechat &&
          a.initialBalance == 50000 &&
          AccountDao(db).findById(a.id)?.initialBalance == 50000;
      db.close();
      return ok;
    }());

    check('create：校验不过 → 抛 AccountDraftInvalid，库里 0 条', () {
      final (Db db, AccountService service) = newEnv();
      Object? thrown;
      try {
        service.create(const AccountDraft(name: '  '), now: now());
      } catch (error) {
        thrown = error;
      }
      final int count =
          db.raw.select('SELECT COUNT(*) AS n FROM accounts').first['n']! as int;
      final bool ok = thrown is AccountDraftInvalid && count == 0;
      db.close();
      return ok;
    }());

    check('update：改名换类型，期初余额以库里原值为准（Z-3 方案 A）', () {
      final (Db _, AccountService service) = newEnv();
      final Account a = service.create(
        AccountDraft(name: '现金', type: AccountType.cash, initialBalance: '300'),
        now: now(),
      );
      final Account updated = service.update(
        a.id,
        AccountDraft(name: '门店现金', type: AccountType.bank, initialBalance: '99999'),
        now: now(),
      );
      return updated.name == '门店现金' &&
          updated.type == AccountType.bank &&
          updated.initialBalance == 30000;
    }());

    check('update：校验不过抛且原值不变；id 不存在抛 StateError', () {
      final (Db db, AccountService service) = newEnv();
      final Account a = service.create(
        AccountDraft(name: '现金', type: AccountType.cash),
        now: now(),
      );
      bool invalidThrows = false;
      try {
        service.update(a.id, const AccountDraft(name: ''), now: now());
      } on AccountDraftInvalid {
        invalidThrows = true;
      }
      bool missingThrows = false;
      try {
        service.update(
          'no-such-id',
          AccountDraft(name: 'x', type: AccountType.cash),
          now: now(),
        );
      } on StateError {
        missingThrows = true;
      }
      return invalidThrows &&
          missingThrows &&
          AccountDao(db).findById(a.id)?.name == '现金';
    }());

    check('setActive：停用软删 / 恢复 / 不存在抛', () {
      final (Db db, AccountService service) = newEnv();
      final Account a = service.create(
        AccountDraft(name: '现金', type: AccountType.cash),
        now: now(),
      );
      service.setActive(a.id, active: false, now: now());
      final bool off = AccountDao(db).findById(a.id)!.isActive == false;
      service.setActive(a.id, active: true, now: now());
      final bool on = AccountDao(db).findById(a.id)!.isActive == true;
      bool missingThrows = false;
      try {
        service.setActive('no-such-id', active: false, now: now());
      } on StateError {
        missingThrows = true;
      }
      return off && on && missingThrows;
    }());

    check('list：默认只看启用中的；balances 含期初', () {
      final (Db _, AccountService service) = newEnv();
      final Account cash = service.create(
        AccountDraft(name: '现金', type: AccountType.cash, initialBalance: '100'),
        now: now(),
      );
      final Account retired = service.create(
        AccountDraft(name: '旧卡', type: AccountType.bank),
        now: now(),
      );
      service.setActive(retired.id, active: false, now: now());
      return service.list().length == 1 &&
          service.list(active: null).length == 2 &&
          service.balances()[cash.id] == 10000;
    }());
  }

  // ============================================================ 收尾
  stdout.writeln('\n==============================================');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  stdout.writeln('==============================================');
  if (_failures.isNotEmpty) {
    for (final String name in _failures) {
      stdout.writeln('  失败：$name');
    }
    exit(1);
  }
}
