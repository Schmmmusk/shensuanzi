// 6 位短码配对的状态机（提案 58 · A4 乙，2026-11-01 用户裁定）。
//
// 用户裁定原文：「6 位数字短码不是普通验证码，它实际上是一个临时配对凭据」，
// 并给了六条安全约束。这份测试**逐条对应**那六条，外加一条用户特别点出的
// 「电脑确认时要显示设备信息 / 请求来源」。
//
// | # | 约束 | 用例 |
// |---|---|---|
// | 1 | 密码学随机，不能是时间戳 / 递增 | 6 位数字 + 200 次不重复不递增 |
// | 2 | 5 分钟过期、一次性、成功后立即失效 | 过期边界 / 用掉即作废 |
// | 3 | 限次防暴力猜测 | 同码 5 次作废 + 同 IP 10 次/分钟 |
// | 4 | 电脑端显示待配对设备、用户主动确认 | 未确认拿不到结果 / 设备名与来源 IP |
// | 5 | 短码不进普通日志 | 对象里没有码、toString 不含码 |
// | 6 | 并发请求不互相覆盖 / 串号 | 同码第二台被拒 + 两条并存按 id 各自独立 |
import 'dart:math';

import 'package:shensuanzi_host/shensuanzi_host.dart';
import 'package:test/test.dart';

/// 可编排的随机源：让「前导零」这种靠真随机一辈子碰不到的输入能被钉住。
class _ScriptedRandom implements Random {
  _ScriptedRandom(this.values);

  final List<int> values;
  int _cursor = 0;

  @override
  int nextInt(int max) {
    final int value = values[_cursor % values.length];
    _cursor++;
    return value % max;
  }

  @override
  double nextDouble() => 0.5;

  @override
  bool nextBool() => false;
}

void main() {
  late int now;

  /// 注入的假时钟：用例自己推进时间（「5 分钟过期」不能靠真等）
  int tick(int ms) => now += ms;

  PairRequests make({Random? random}) =>
      PairRequests(random: random ?? Random(7), clock: () => now);

  setUp(() => now = 1700000000000);

  // ---------------------------------------------------------------- 约束 1
  group('约束 1：密码学随机', () {
    test('6 位数字，前导零也补齐', () {
      final PairRequests store = make(random: _ScriptedRandom(<int>[123]));
      expect(store.issueCode(), '000123');
      expect(store.issueCode().length, PairRequests.codeDigits);
    });

    test('200 次生成：都是 6 位数字、彼此不同、不是递增序列', () {
      // ⚠️ 这条盯的是「不许用时间戳 / 自增」。时间戳连发两次会撞号，
      // 自增序列会单调递增 —— 两种错法都会被这里抓住。
      final PairRequests store = PairRequests(clock: () => now);
      final List<String> codes = <String>[];
      for (int i = 0; i < 200; i++) {
        codes.add(store.issueCode());
      }
      for (final String code in codes) {
        expect(RegExp(r'^\d{6}$').hasMatch(code), isTrue, reason: code);
      }
      expect(codes.toSet().length, greaterThan(180), reason: '撞号太多 ⇒ 随机源有问题');
      final List<String> sorted = List<String>.of(codes)..sort();
      expect(sorted, isNot(equals(codes)), reason: '严格递增 ⇒ 是自增不是随机');
    });
  });

  // ---------------------------------------------------------------- 约束 2
  group('约束 2：5 分钟、一次性', () {
    test('换新码 ⇒ 旧码立刻作废', () {
      final PairRequests store = make();
      final String old = store.issueCode();
      final String fresh = store.issueCode();
      expect(fresh, isNot(old));
      expect(
        store.request(code: old, deviceName: 'x', ip: '10.0.0.1').rejection,
        PairRejection.badCode,
        reason: '旧码不再是「有效的那个」，按错码处理',
      );
    });

    test('4 分 59 秒还能用，满 5 分钟就过期', () {
      final PairRequests store = make();
      final String code = store.issueCode();
      tick(PairRequests.codeTtl.inMilliseconds - 1);
      expect(
        store.request(code: code, deviceName: 'x', ip: '10.0.0.1').ok,
        isTrue,
      );

      final PairRequests store2 = make();
      final String code2 = store2.issueCode();
      tick(PairRequests.codeTtl.inMilliseconds);
      expect(
        store2.request(code: code2, deviceName: 'x', ip: '10.0.0.2').rejection,
        PairRejection.codeExpired,
      );
    });

    test('过期之后说「过期」，不是「没有码」（真机联调抓到的读序 bug）', () {
      // 现场（2026-11-01，用户手动测第 3 项）：码放了 5 分钟，电脑上显示的是
      // 「现在没有可用的配对码」—— 而事实是「这个码过期了」。
      // 根因：界面先读 `code`（返回 null 时顺手把状态降级成 none），
      // 再读 `codeProblem` 就只看得见 none ⇒ 报「没有码」。
      final PairRequests store = make();
      store.issueCode();
      tick(PairRequests.codeTtl.inMilliseconds);

      expect(store.code, isNull);
      expect(
        store.codeProblem,
        PairRejection.codeExpired,
        reason: '先读 code 不能把「过期」抹成「没生成」',
      );
      expect(
        store
            .request(code: '000000', deviceName: 'x', ip: '10.7.0.1')
            .rejection,
        PairRejection.codeExpired,
        reason: '手机拿着旧码来请求，也要说「过期」',
      );
    });

    test('成功后立即失效：同一个码第二台手机用不了', () {
      final PairRequests store = make();
      final String code = store.issueCode();
      expect(
        store.request(code: code, deviceName: '第一台', ip: '10.0.0.1').ok,
        isTrue,
      );
      expect(store.code, isNull, reason: '码被消耗掉，屏幕上不该还挂着');
      final PairRequestResult second = store.request(
        code: code,
        deviceName: '第二台',
        ip: '10.0.0.2',
      );
      expect(second.rejection, PairRejection.codeConsumed);
      expect(second.ok, isFalse);
      expect(store.pendingAwaiting().length, 1, reason: '第二台不能凭空多一条');
    });
  });

  // ---------------------------------------------------------------- 约束 3
  group('约束 3：限次防爆破', () {
    test('同一个码错 5 次 ⇒ 作废，之后输对也不认', () {
      final PairRequests store = make();
      final String code = store.issueCode();
      final String wrong = code == '000000' ? '111111' : '000000';
      for (int i = 1; i <= PairRequests.maxAttemptsPerCode - 1; i++) {
        final PairRequestResult r = store.request(
          code: wrong,
          deviceName: 'x',
          ip: '10.0.0.1',
        );
        expect(r.rejection, PairRejection.badCode, reason: '第 $i 次');
        expect(r.remaining, PairRequests.maxAttemptsPerCode - i);
      }
      expect(
        store.request(code: wrong, deviceName: 'x', ip: '10.0.0.1').rejection,
        PairRejection.codeExhausted,
      );
      expect(
        store.request(code: code, deviceName: 'x', ip: '10.0.0.1').rejection,
        PairRejection.codeExhausted,
        reason: '作废之后连正确码也不能再用 —— 否则等于无限次猜测',
      );
    });

    test('同一 IP 一分钟超过 10 次 ⇒ 限流；换 IP 与过窗口都恢复', () {
      final PairRequests store = make();
      store.issueCode();
      for (int i = 0; i < PairRequests.maxRequestsPerIp; i++) {
        store.request(code: '999999', deviceName: 'x', ip: '10.9.9.9');
      }
      expect(
        store
            .request(code: '999999', deviceName: 'x', ip: '10.9.9.9')
            .rejection,
        PairRejection.rateLimited,
      );
      expect(
        store
            .request(code: '999999', deviceName: 'x', ip: '10.9.9.10')
            .rejection,
        isNot(PairRejection.rateLimited),
        reason: '限流是按来源 IP 的，不能一台上头就全店都连不上',
      );
      tick(PairRequests.ipWindow.inMilliseconds);
      expect(
        store
            .request(code: '999999', deviceName: 'x', ip: '10.9.9.9')
            .rejection,
        isNot(PairRejection.rateLimited),
      );
    });
  });

  // ---------------------------------------------------------------- 约束 4
  group('约束 4：电脑端显示设备、用户主动确认', () {
    test('未确认前只有 awaiting，拿不到任何凭据', () {
      final PairRequests store = make();
      final String code = store.issueCode();
      final PairPending pending = store
          .request(
            code: code,
            deviceName: '安卓手机（Android 14）',
            ip: '192.168.1.23',
          )
          .request!;
      expect(store.statusOf(pending.id), PairRequestStatus.awaiting);
    });

    test('待确认列表带设备名与来源 IP（用户要知道自己在批准哪台）', () {
      final PairRequests store = make();
      final String code = store.issueCode();
      store.request(
        code: code,
        deviceName: '安卓手机（Android 14）',
        ip: '192.168.1.23',
      );
      final PairPending pending = store.pendingAwaiting().single;
      expect(pending.deviceName, contains('Android'));
      expect(pending.ip, '192.168.1.23');
      expect(pending.label, contains('192.168.1.23'));
    });

    test('设备名被清理：控制字符去掉、空名给兜底、超长截断', () {
      final PairRequests store = make();
      store.request(
        code: store.issueCode(),
        deviceName: '坏\n设备\r',
        ip: '10.0.0.1',
      );
      expect(store.pendingAwaiting().single.deviceName, '坏设备');

      final PairRequests store2 = make();
      store2.request(
        code: store2.issueCode(),
        deviceName: '   ',
        ip: '10.0.0.1',
      );
      expect(store2.pendingAwaiting().single.deviceName, '一台手机');

      final PairRequests store3 = make();
      store3.request(
        code: store3.issueCode(),
        deviceName: 'A' * 200,
        ip: '10.0.0.1',
      );
      expect(
        store3.pendingAwaiting().single.deviceName.length,
        lessThanOrEqualTo(40),
      );
    });

    test('批准 / 拒绝都只对 awaiting 有效，不能重复决定', () {
      final PairRequests store = make();
      final String code = store.issueCode();
      final PairPending pending = store
          .request(code: code, deviceName: 'x', ip: '10.0.0.1')
          .request!;
      expect(store.approve(pending.id), isTrue);
      expect(store.statusOf(pending.id), PairRequestStatus.approved);
      expect(store.approve(pending.id), isFalse, reason: '不能重复批准');
      expect(store.deny(pending.id), isFalse, reason: '批准过的不能再拒');

      final String code2 = store.issueCode();
      final PairPending other = store
          .request(code: code2, deviceName: 'y', ip: '10.0.0.2')
          .request!;
      expect(store.deny(other.id), isTrue);
      expect(store.statusOf(other.id), PairRequestStatus.denied);
    });

    test('5 分钟没人处理 ⇒ 自动过期，不再出现在待确认里', () {
      final PairRequests store = make();
      final PairPending pending = store
          .request(code: store.issueCode(), deviceName: 'x', ip: '10.0.0.1')
          .request!;
      tick(PairRequests.requestTtl.inMilliseconds);
      expect(store.statusOf(pending.id), PairRequestStatus.expired);
      expect(store.pendingAwaiting(), isEmpty);
      expect(store.approve(pending.id), isFalse, reason: '过期的不许再批准');
    });
  });

  // ---------------------------------------------------------------- 约束 5
  group('约束 5：短码不进日志', () {
    test('待确认对象里没有码，toString 也不含码', () {
      final PairRequests store = make();
      final String code = store.issueCode();
      final PairPending pending = store
          .request(code: code, deviceName: 'x', ip: '10.0.0.1')
          .request!;
      expect(pending.toString(), isNot(contains(code)));
      expect(store.pendingAwaiting().single.toString(), isNot(contains(code)));
      expect(pending.label, isNot(contains(code)));
    });

    test('全角数字与空格被掰回半角（服务端兜底，不算「码不对」）', () {
      final PairRequests store = make();
      final String code = store.issueCode();
      final String fullWidth = code
          .split('')
          .map(
            (String c) => String.fromCharCode(c.codeUnitAt(0) - 0x30 + 0xFF10),
          )
          .join();
      expect(PairRequests.normalizeCode(' $fullWidth '), code);
      expect(
        store
            .request(
              code: ' ${fullWidth.substring(0, 3)} ${fullWidth.substring(3)} ',
              deviceName: 'x',
              ip: '10.0.0.1',
            )
            .ok,
        isTrue,
        reason: '输入法打出来的全角数字不该被判成「码不对」',
      );
    });
  });

  // ---------------------------------------------------------------- 约束 6
  group('约束 6：并发不覆盖、不串号', () {
    test('两条待确认并存，批准第二条不影响第一条', () {
      final PairRequests store = make();
      final PairPending first = store
          .request(code: store.issueCode(), deviceName: '第一台', ip: '10.0.0.1')
          .request!;
      final PairPending second = store
          .request(code: store.issueCode(), deviceName: '第二台', ip: '10.0.0.2')
          .request!;
      expect(first.id, isNot(second.id), reason: '两条请求必须有各自的 id');
      expect(store.pendingAwaiting().length, 2);

      expect(store.approve(second.id), isTrue);
      expect(store.statusOf(first.id), PairRequestStatus.awaiting);
      expect(store.statusOf(second.id), PairRequestStatus.approved);
    });

    test('待确认最多 5 条，第 6 条被挡；处理掉一条后同一个码还能用', () {
      final PairRequests store = make();
      for (int i = 0; i < PairRequests.maxPending; i++) {
        expect(
          store
              .request(
                code: store.issueCode(),
                deviceName: '设备 $i',
                ip: '10.0.1.$i',
              )
              .ok,
          isTrue,
        );
      }
      final String code = store.issueCode();
      expect(
        store.request(code: code, deviceName: '第六台', ip: '10.0.1.9').rejection,
        PairRejection.tooManyPending,
      );
      store.approve(store.pendingAwaiting().first.id);
      expect(
        store.request(code: code, deviceName: '第六台', ip: '10.0.1.9').ok,
        isTrue,
        reason: '被队列上限挡住时不该把码一起消耗掉',
      );
    });

    test('不认识的 id ⇒ null（绝不按「最新一条」兜底）', () {
      final PairRequests store = make();
      store.request(code: store.issueCode(), deviceName: 'x', ip: '10.0.0.1');
      expect(store.statusOf('0123456789abcdef'), isNull);
      expect(store.statusOf(''), isNull);
    });

    test('clear() 把码与待确认全部作废（服务停了就不能再用）', () {
      final PairRequests store = make();
      final String code = store.issueCode();
      final PairPending pending = store
          .request(code: code, deviceName: 'x', ip: '10.0.0.1')
          .request!;
      store.clear();
      expect(store.code, isNull);
      expect(store.pendingAwaiting(), isEmpty);
      expect(store.statusOf(pending.id), isNull);
      expect(
        store.request(code: code, deviceName: 'x', ip: '10.0.0.1').rejection,
        PairRejection.noCode,
      );
    });
  });
}
