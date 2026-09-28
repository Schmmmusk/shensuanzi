// CSV 生成与「给人看」措辞的测试（§AF）。
//
// 覆盖：注入防护（遗漏 1）/ RFC 4180 转义（坑 2）/ UTF-8 BOM（坑 1）/
// CRLF 行尾 / 日期格式（遗漏 6：带时分）/ 状态与角色中文 / 对方为空的措辞。
//
// ⚠️ 这套断言是「文件打开之后会不会出错」的最后一道门 —— CSV 的 bug
// 都是**静默**的（用户打开才发现乱码 / 公式错 / 串行），只能靠断言钉。
import 'dart:convert';
import 'dart:typed_data';

import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

void main() {
  group('csvEscape（转义 + 注入防护）', () {
    test('普通字段原样，中文不动', () {
      expect(csvEscape('娃哈哈矿泉水'), '娃哈哈矿泉水');
      expect(csvEscape('P0001'), 'P0001');
      expect(csvEscape(''), '');
    });

    test('含逗号 / 引号 / 换行 → 整段加引号，内部引号双写（坑 2）', () {
      expect(csvEscape('娃哈哈,矿泉水'), '"娃哈哈,矿泉水"');
      expect(csvEscape('他说"好"'), '"他说""好"""');
      expect(csvEscape('两行\n地址'), '"两行\n地址"');
      expect(csvEscape('回车\r结尾'), '"回车\r结尾"');
    });

    test('以 = + - @ 开头 → 前面加单引号（遗漏 1：Excel 公式误伤）', () {
      expect(csvEscape('=赠品'), "'=赠品");
      expect(csvEscape('+86 138'), "'+86 138");
      expect(csvEscape('-5 折'), "'-5 折");
      expect(csvEscape('@批发'), "'@批发");
      expect(
        csvEscape('=SUM(A1:A9)'),
        "'=SUM(A1:A9)",
        reason: '真被 Excel 执行的就是这种',
      );
    });

    test('注入前缀 + 需要引号的字段：两层都生效', () {
      expect(csvEscape('=a,b'), '"\'=a,b"');
    });

    test('**纯数字放行**：负金额不能变文本，否则会计求和会漏（遗漏 1 的修正）', () {
      expect(csvEscape('-12.34'), '-12.34');
      expect(csvEscape('0.00'), '0.00');
      expect(csvEscape('-1234'), '-1234');
      expect(
        csvEscape('-2+3'),
        "'-2+3",
        reason: '不是数字字面量 → 仍然防护（Excel 真会算它）',
      );
    });
  });

  group('csvLine / csvBytes', () {
    test('行 = 逗号连接（各字段独立转义）', () {
      expect(csvLine(<String>['a', 'b,c', 'd']), 'a,"b,c",d');
    });

    test('字节以 BOM 开头 + CRLF 行尾 + UTF-8 编码（坑 1）', () {
      final Uint8List bytes = csvBytes(
        <String>['商品名称', '金额'],
        <List<String>>[
          <String>['可乐', '12.50'],
        ],
      );

      expect(bytes.sublist(0, 3), csvBom, reason: '没有 BOM，Excel 用 GBK 解码会乱码');
      expect(bytes.sublist(0, 3), <int>[0xEF, 0xBB, 0xBF]);

      final String text = utf8.decode(bytes.sublist(3));
      expect(text, '商品名称,金额\r\n可乐,12.50\r\n');
      expect(text.endsWith('\r\n'), isTrue, reason: '记事本只认 CRLF 才换行');
    });

    test('中文按 UTF-8 编码（3 字节 / 字）', () {
      final Uint8List bytes = csvBytes(<String>['名'], const <List<String>>[]);
      // BOM(3) + '名'(3) + CRLF(2)
      expect(bytes.length, 3 + 3 + 2);
    });

    test('空行集 → 只有表头', () {
      final String text = utf8.decode(
        csvBytes(<String>['a', 'b'], const <List<String>>[]).sublist(3),
      );
      expect(text, 'a,b\r\n');
    });
  });

  group('日期与措辞（给人看）', () {
    test('formatDate / formatDateTime 用本地时间，带时分（遗漏 6）', () {
      final DateTime local = DateTime(2026, 9, 28, 15, 30);
      final int millis = local.millisecondsSinceEpoch;
      expect(formatDate(millis), '2026-09-28');
      expect(formatDateTime(millis), '2026-09-28 15:30');
      expect(formatFileDate(local), '20260928');
      // 补零
      expect(formatDateTime(DateTime(2026, 1, 2, 3, 4).millisecondsSinceEpoch),
          '2026-01-02 03:04');
    });

    test('单据状态是中文，不是 confirmed（AF-9）', () {
      expect(docStatusLabel(DocStatus.draft), '草稿');
      expect(docStatusLabel(DocStatus.confirmed), '已确认');
      expect(docStatusLabel(DocStatus.inTransit), '在途');
      expect(docStatusLabel(DocStatus.delivered), '已送达');
      expect(docStatusLabel(DocStatus.settled), '已结清');
      expect(docStatusLabel(DocStatus.cancelled), '已作废');
    });

    test('角色中文；多角色用顿号连接', () {
      expect(partyRoleLabel(PartyRole.supplier), '供应商');
      expect(partyRoleLabel(PartyRole.customer), '客户');
      expect(partyRoleLabel(PartyRole.carrier), '司机');
      expect(
        partyRolesLabel(const <PartyRole>[PartyRole.customer, PartyRole.supplier]),
        '客户、供应商',
      );
    });

    test('启用 / 停用', () {
      expect(activeLabel(true), '启用');
      expect(activeLabel(false), '停用');
    });

    test('对方为空 → 「散客」/「散采」，不留空白（AF-9）', () {
      expect(documentPartyLabel('王老板', DocType.sale), '王老板');
      expect(documentPartyLabel(null, DocType.sale), '散客');
      expect(documentPartyLabel('', DocType.sale), '散客');
      expect(documentPartyLabel(null, DocType.purchase), '散采');
      expect(documentPartyLabel(null, DocType.stocktake), '散采');
    });
  });
}
