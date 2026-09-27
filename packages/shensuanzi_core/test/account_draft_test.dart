// 账户建档草稿与服务（§Z 三），对应 `docs/testing.md` §O。
//
// 覆盖：草稿校验（名称 / 类型 / 期初余额）/ 取值 /
// 服务（create、**update 不改期初余额**（Z-3 方案 A）、setActive、列表）。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；Windows 需要可用的 SQLite 原生库。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);
  setUp(resetClock);

  // ============================================================ 草稿校验（纯函数）
  group('AccountDraft 校验', () {
    AccountDraft goodDraft({
      String name = '现金',
      AccountType? type = AccountType.cash,
      String initialBalance = '',
    }) => AccountDraft(
      name: name,
      type: type,
      initialBalance: initialBalance,
    );

    test('合法草稿（期初余额留空 = 0）→ 无错误，取值 0 分', () {
      final AccountDraft draft = goodDraft();
      expect(draft.validate(), isEmpty);
      expect(draft.isValid, isTrue);
      expect(draft.initialBalanceCents, 0, reason: '留空 = 0，不强迫用户填');
    });

    test('名称必填：空 / 全空格都拦；超长拦', () {
      expect(
        goodDraft(name: '').validate()[AccountField.name],
        contains('请填账户名称'),
      );
      expect(
        goodDraft(name: '   ').validate()[AccountField.name],
        contains('请填账户名称'),
      );
      expect(
        goodDraft(name: '长' * 61).validate()[AccountField.name],
        contains('60 字以内'),
      );
    });

    test('类型必选（下拉没选就保存）', () {
      expect(
        goodDraft(type: null).validate()[AccountField.type],
        contains('请选一个账户类型'),
      );
    });

    test('期初余额：合法金额收；非法拦；负数拦（负期初对现金类是错的）', () {
      final AccountDraft ok = goodDraft(initialBalance: ' 1000.50 ');
      expect(ok.validate(), isEmpty);
      expect(ok.initialBalanceCents, 100050);

      expect(
        goodDraft(initialBalance: 'abc').validate()[AccountField.initialBalance],
        contains('只能填数字'),
      );
      expect(
        goodDraft(initialBalance: '1.005')
            .validate()[AccountField.initialBalance],
        contains('两位小数'),
      );
      expect(
        goodDraft(initialBalance: '-5').validate()[AccountField.initialBalance],
        contains('不能是负数'),
      );
    });

    test('一次能报多个字段（界面据此标红多栏）', () {
      const AccountDraft draft = AccountDraft();
      expect(draft.validate().keys, containsAll(<AccountField>[
        AccountField.name,
        AccountField.type,
      ]));
    });
  });

  // ============================================================ 服务（集成）
  group('AccountService', () {
    late Db db;
    late AccountService service;

    setUp(() {
      db = newMemoryDb();
      service = AccountService(AccountDao(db));
    });

    tearDown(() => db.close());

    test('create：补齐 id / 时间戳 / 版本列；期初余额落库（元 → 分）', () {
      final Account account = service.create(
        AccountDraft(
          name: ' 微信收款 ',
          type: AccountType.wechat,
          initialBalance: '500',
        ),
        now: now(),
      );

      expect(account.name, '微信收款', reason: '名称要 trim');
      expect(account.type, AccountType.wechat);
      expect(account.initialBalance, 50000);
      expect(account.isActive, isTrue);

      // 读回一致
      final Account? stored = AccountDao(db).findById(account.id);
      expect(stored?.initialBalance, 50000);
    });

    test('create：校验不过 → 抛 AccountDraftInvalid，库里一条都没有', () {
      Object? thrown;
      try {
        service.create(const AccountDraft(name: '  '), now: now());
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<AccountDraftInvalid>());
      final int count =
          db.raw.select('SELECT COUNT(*) AS n FROM accounts').first['n']! as int;
      expect(count, 0);
    });

    test('update：改名换类型，**期初余额以库里原值为准**（Z-3 方案 A）', () {
      final Account account = service.create(
        AccountDraft(
          name: '现金',
          type: AccountType.cash,
          initialBalance: '300',
        ),
        now: now(),
      );

      // 草稿里带一个**不同的**期初余额 —— 服务层必须忽略它。
      // ⚠️ 时间戳先落变量：`now()` 是**递增**助手，在参数和 expect 里各调一次
      // 会把时钟推走（首跑就在这里翻过车）。
      final int updateAt = now() + 1;
      final Account updated = service.update(
        account.id,
        AccountDraft(
          name: '门店现金',
          type: AccountType.bank,
          initialBalance: '99999',
        ),
        now: updateAt,
      );

      expect(updated.name, '门店现金');
      expect(updated.type, AccountType.bank);
      expect(
        updated.initialBalance,
        30000,
        reason: '编辑不可改期初余额 —— 修改会重算全部历史余额（data_model §2.3）',
      );
      expect(updated.updatedAt, updateAt);
    });

    test('update：校验不过 → 抛，库里原值不变；id 不存在 → StateError', () {
      final Account account = service.create(
        AccountDraft(name: '现金', type: AccountType.cash),
        now: now(),
      );

      expect(
        () => service.update(account.id, const AccountDraft(name: ''), now: now()),
        throwsA(isA<AccountDraftInvalid>()),
      );
      expect(AccountDao(db).findById(account.id)?.name, '现金');

      expect(
        () => service.update('no-such-id',
            AccountDraft(name: 'x', type: AccountType.cash), now: now()),
        throwsStateError,
      );
    });

    test('setActive：停用是软删；恢复启用；不存在抛', () {
      final Account account = service.create(
        AccountDraft(name: '现金', type: AccountType.cash),
        now: now(),
      );

      service.setActive(account.id, active: false, now: now() + 1);
      expect(AccountDao(db).findById(account.id)?.isActive, isFalse);

      service.setActive(account.id, active: true, now: now() + 2);
      expect(AccountDao(db).findById(account.id)?.isActive, isTrue);

      expect(
        () => service.setActive('no-such-id', active: false, now: now()),
        throwsStateError,
      );
    });

    test('list：默认只看启用中的；balances 含期初 + 流水', () {
      final Account cash = service.create(
        AccountDraft(name: '现金', type: AccountType.cash, initialBalance: '100'),
        now: now(),
      );
      final Account retired = service.create(
        AccountDraft(name: '旧卡', type: AccountType.bank),
        now: now(),
      );
      service.setActive(retired.id, active: false, now: now());

      expect(service.list().map((Account a) => a.name), <String>['现金']);
      expect(service.list(active: null).length, 2);

      // 余额 = 期初 100 元（没流水）
      expect(service.balances()[cash.id], 10000);
    });
  });
}
