/// 应用运行时的降级门禁（对应 `test/` 下三个测试文件）。
///
/// ⚠️ **改一边必须改另一边** —— `test/**` 是正式门禁，本脚本是
/// 「跑不了 `dart test` 时的降级门禁」，两者必须镜像（`docs/testing.md` §零）。
///
/// 运行：`dart run tool/selfcheck_app.dart`
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
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

// ================================================================ 夹具

const int _gb = 1024 * 1024 * 1024;

const DriveInfo _cDrive = DriveInfo(
  root: r'C:\',
  kind: DriveKind.fixed,
  freeBytes: 100 * _gb,
);
const DriveInfo _dDrive = DriveInfo(
  root: r'D:\',
  kind: DriveKind.fixed,
  freeBytes: 128 * _gb,
);
const DriveInfo _eUsb = DriveInfo(
  root: r'E:\',
  kind: DriveKind.removable,
  freeBytes: 16 * _gb,
);
const DriveInfo _zNet = DriveInfo(
  root: r'Z:\',
  kind: DriveKind.network,
  freeBytes: 500 * _gb,
);
const DriveInfo _fTight = DriveInfo(
  root: r'F:\',
  kind: DriveKind.fixed,
  freeBytes: 50 * 1024 * 1024,
);

AppEnvironment machine({
  String home = r'C:\Users\tester',
  List<DriveInfo>? drives,
  Map<String, String>? environment,
}) => AppEnvironment(
  isWindows: true,
  homeDirectory: home,
  drives: drives ?? <DriveInfo>[_cDrive, _dDrive],
  environment:
      environment ??
      <String, String>{
        'USERPROFILE': home,
        'LOCALAPPDATA': r'C:\Users\tester\AppData\Local',
        'APPDATA': r'C:\Users\tester\AppData\Roaming',
        'TEMP': r'C:\Users\tester\AppData\Local\Temp',
      },
);

void main() {
  useLocalSqlite();

  final Directory box = Directory.systemTemp.createTempSync('sz_app_check_');
  final DataDirectoryPolicy policy = DataDirectoryPolicy(machine());

  AppBootstrap bootstrapIn(
    Directory sandbox, {
    AppEnvironment? environment,
  }) => AppBootstrap(
    environment: environment ?? machine(),
    configStore: AppConfigStore(File(p.join(sandbox.path, 'config.json'))),
  );

  String inBox(String name) => p.join(box.path, name);

  void fresh(String name) {
    final Directory dir = Directory(inBox(name));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  // ============================================================ 默认位置
  section('默认数据目录');
  check('有非系统盘 → 优先非系统盘',
      DataDirectoryPolicy(machine()).defaultDataDirectory() == r'D:\神算子数据',
      DataDirectoryPolicy(machine()).defaultDataDirectory());
  check('只有系统盘 → 退回用户目录',
      DataDirectoryPolicy(machine(drives: <DriveInfo>[_cDrive]))
              .defaultDataDirectory() ==
          r'C:\Users\tester\神算子数据');
  check('非系统盘只有 U 盘 → 不用它',
      DataDirectoryPolicy(machine(drives: <DriveInfo>[_cDrive, _eUsb]))
              .defaultDataDirectory() ==
          r'C:\Users\tester\神算子数据');
  check('非系统盘只有网络盘 → 不用它',
      DataDirectoryPolicy(machine(drives: <DriveInfo>[_cDrive, _zNet]))
              .defaultDataDirectory() ==
          r'C:\Users\tester\神算子数据');
  check('非系统盘空间不足 → 不用它',
      DataDirectoryPolicy(machine(drives: <DriveInfo>[_cDrive, _fTight]))
              .defaultDataDirectory() ==
          r'C:\Users\tester\神算子数据');
  check('固定盘优先于 U 盘（D 固定 + E 可移动 → 选 D）',
      DataDirectoryPolicy(machine(drives: <DriveInfo>[_cDrive, _eUsb, _dDrive]))
              .defaultDataDirectory() ==
          r'D:\神算子数据');
  check('HOME 拿不到 → 兜底系统盘',
      DataDirectoryPolicy(machine(home: '', drives: <DriveInfo>[_cDrive]))
              .defaultDataDirectory() ==
          r'C:\神算子数据');

  // ============================================================ 拒绝
  section('校验 · 拒绝');
  final DirectoryAdvice empty = policy.inspect('   ');
  check('空路径 → reject 且带 advice',
      empty.verdict == DirectoryVerdict.reject && empty.advice != null);
  check('相对路径 → reject',
      policy.inspect(r'神算子数据').verdict == DirectoryVerdict.reject);
  check('系统盘根 → reject 且提到「根目录」',
      policy.inspect(r'C:\').verdict == DirectoryVerdict.reject &&
          policy.inspect(r'C:\').reason.contains('根目录'));
  check('C:\\Windows 及其子路径 → reject',
      policy.inspect(r'C:\Windows').verdict == DirectoryVerdict.reject &&
          policy.inspect(r'C:\Windows\System32').verdict ==
              DirectoryVerdict.reject);
  check('大小写不敏感（c:\\windows）→ reject',
      policy.inspect(r'c:\windows\system32').verdict == DirectoryVerdict.reject);
  check('C:\\Program Files 及 (x86) → reject',
      policy.inspect(r'C:\Program Files\神算子').verdict ==
              DirectoryVerdict.reject &&
          policy.inspect(r'C:\Program Files (x86)\神算子').verdict ==
              DirectoryVerdict.reject);
  check('名字带 Windows 但不是系统目录 → 放行',
      policy.inspect(r'D:\Windows备份').verdict == DirectoryVerdict.ok);

  // ============================================================ 警告
  section('校验 · 警告');
  final DirectoryAdvice local =
      policy.inspect(r'C:\Users\tester\AppData\Local\神算子');
  check('%LOCALAPPDATA% → warn 但可用',
      local.verdict == DirectoryVerdict.warn &&
          local.isUsable &&
          local.reason.contains('%LOCALAPPDATA%'));
  check('%APPDATA% → warn',
      policy.inspect(r'C:\Users\tester\AppData\Roaming\神算子').verdict ==
          DirectoryVerdict.warn);
  check('%TEMP% → warn',
      policy.inspect(r'C:\Users\tester\AppData\Local\Temp\神算子').verdict ==
          DirectoryVerdict.warn);
  final DirectoryAdvice oneDrive =
      policy.inspect(r'C:\Users\tester\OneDrive\神算子');
  check('OneDrive → warn 且提到同步',
      oneDrive.verdict == DirectoryVerdict.warn &&
          oneDrive.reason.contains('同步'));
  check('坚果云 / Dropbox / 百度网盘 → warn',
      policy.inspect(r'D:\坚果云\神算子').verdict == DirectoryVerdict.warn &&
          policy.inspect(r'D:\Dropbox\神算子').verdict ==
              DirectoryVerdict.warn &&
          policy.inspect(r'D:\百度网盘\神算子').verdict ==
              DirectoryVerdict.warn);
  check('U 盘 → warn 且提到「可移动」',
      DataDirectoryPolicy(machine(drives: <DriveInfo>[_cDrive, _eUsb]))
              .inspect(r'E:\神算子数据')
              .reason
              .contains('可移动'));
  check('网络盘 → warn 且提到「网络」',
      DataDirectoryPolicy(machine(drives: <DriveInfo>[_cDrive, _zNet]))
              .inspect(r'Z:\神算子数据')
              .reason
              .contains('网络'));
  check('空间不足 → warn 且报出具体剩余量',
      DataDirectoryPolicy(machine(drives: <DriveInfo>[_cDrive, _fTight]))
              .inspect(r'F:\神算子数据')
              .reason
              .contains('50.0 MB'));
  final DirectoryAdvice rootWarn = policy.inspect(r'D:\');
  check('非系统盘根 → warn 且建议建一层',
      rootWarn.verdict == DirectoryVerdict.warn &&
          (rootWarn.advice ?? '').contains('神算子数据'));
  check('盘类型未知 → 不因此拦人',
      DataDirectoryPolicy(
        machine(drives: <DriveInfo>[_cDrive, const DriveInfo(root: r'D:\')]),
      ).inspect(r'D:\神算子数据').verdict ==
          DirectoryVerdict.ok);

  // ============================================================ 放行
  section('校验 · 放行');
  check('D:\\神算子数据 → ok 且无警告',
      policy.inspect(r'D:\神算子数据').verdict == DirectoryVerdict.ok &&
          !policy.inspect(r'D:\神算子数据').isWarning);
  check('用户自起名 → ok',
      policy.inspect(r'D:\我的账本').verdict == DirectoryVerdict.ok &&
          policy.inspect(r'D:\a\b\c\d').verdict == DirectoryVerdict.ok);

  // ============================================================ 迁移
  section('迁移校验');
  check('新在旧里面 → reject',
      policy.inspectMigration(r'D:\数据', r'D:\数据\子').reason.contains('新位置在旧位置里面'));
  check('旧在新里面 → reject',
      policy.inspectMigration(r'D:\数据\子', r'D:\数据').reason.contains('旧位置在新位置里面'));
  check('并列目录 → ok',
      policy.inspectMigration(r'D:\数据', r'D:\数据2').verdict ==
          DirectoryVerdict.ok);
  check('目标非法 → 直接返回该结论',
      policy.inspectMigration(r'D:\数据', r'C:\').verdict ==
          DirectoryVerdict.reject);
  check('盘根作容器：isNested 生效（曾经静默失效）',
      policy.isNested(r'C:\Users\x', r'C:\') == true &&
          policy.inspectMigration(r'D:\', r'D:\数据').verdict ==
              DirectoryVerdict.reject);

  // ============================================================ 备份
  section('备份目录 = 兄弟目录');
  check('D:\\神算子数据 → D:\\神算子备份',
      policy.backupDirectoryFor(r'D:\神算子数据') == r'D:\神算子备份');
  check('深层目录同样',
      policy.backupDirectoryFor(r'D:\a\b\神算子数据') == r'D:\a\b\神算子备份');
  check('数据目录自己叫「神算子备份」→ 让位',
      policy.backupDirectoryFor(r'D:\神算子备份') == r'D:\神算子备份-1');
  check('容量提示取真实值，拿不到就 null',
      policy.spaceHint(r'D:\神算子数据') == 'D 盘剩余 128.0 GB' &&
          DataDirectoryPolicy(machine(drives: <DriveInfo>[]))
                  .spaceHint(r'D:\神算子数据') ==
              null);
  check('formatBytes 未知 → 「未知」而不是 0',
      formatBytes(null) == '未知' && formatBytes(2048) == '2.0 KB');

  // ============================================================ 配置
  section('配置');
  final Directory cfgBox = Directory(inBox('cfg'))..createSync(recursive: true);
  final AppConfigStore store =
      AppConfigStore(File(p.join(cfgBox.path, 'config.json')));
  check('缺失文件 → 默认（dataDirectory = null）',
      store.load().dataDirectory == null &&
          store.load().uiScale == UiScale.standard);
  check('默认缩放 125%', UiScale.defaultScale.factor == 1.25);
  store.save(const AppConfig(
    dataDirectory: r'D:\神算子数据',
    uiScale: UiScale.large,
    shopName: '张记五金',
  ));
  final AppConfig back = store.load();
  check('往返一致',
      back.dataDirectory == r'D:\神算子数据' &&
          back.uiScale == UiScale.large &&
          back.shopName == '张记五金');
  final Map<String, Object?> cfgJson = Map<String, Object?>.from(
    jsonDecode(store.file.readAsStringSync()) as Map,
  );
  check('JSON 键名 snake_case / 缩放存数值',
      cfgJson.keys.toSet().containsAll(<String>[
        'data_directory',
        'ui_scale',
        'shop_name',
      ]) &&
          cfgJson['ui_scale'] == 1.5);
  store.file.writeAsStringSync('{ 这不是 json');
  check('语法坏了 → 默认值，不抛', store.load().dataDirectory == null);
  store.file.writeAsStringSync('[1,2,3]');
  check('顶层不是对象 → 默认值', store.load().dataDirectory == null);
  store.file.writeAsStringSync(jsonEncode(<String, Object?>{'ui_scale': 1.3}));
  check('未知缩放 → 退回 125%', store.load().uiScale == UiScale.standard);
  store.file.writeAsStringSync(jsonEncode(<String, Object?>{'data_directory': '   '}));
  check('空白路径 → 当作没配', store.load().dataDirectory == null);
  store.clear();
  check('clear 后回到默认且文件消失',
      store.load().dataDirectory == null && !store.file.existsSync());
  check('clear 不存在的文件 → 不抛', () {
    store.clear();
    return true;
  }());
  check('copyWith clearShopName 能清掉店名',
      const AppConfig(shopName: '店').copyWith(clearShopName: true).shopName ==
          null);
  check('UiScale 五档数值',
      UiScale.values.map((UiScale s) => s.factor).join(',') ==
          '1.0,1.25,1.5,1.75,2.0');
  check('配置位置 = %APPDATA%\\神算子\\config.json',
      AppConfigStore.forEnvironment(machine()).file.path ==
          p.join(r'C:\Users\tester\AppData\Roaming', '神算子', 'config.json'));
  check('%APPDATA% 拿不到 → 退回用户目录',
      AppConfigStore.forEnvironment(
            machine(environment: <String, String>{}),
          ).file.path ==
          p.join(r'C:\Users\tester', '.shensuanzi', '神算子', 'config.json'));

  // ============================================================ 标记
  section('标记文件与目录内容');
  check('不存在 → missing',
      contentsOf(inBox('nope')) == DirectoryContents.missing);
  fresh('empty');
  Directory(inBox('empty')).createSync(recursive: true);
  check('空目录 → empty',
      contentsOf(inBox('empty')) == DirectoryContents.empty);
  fresh('ours');
  DataMarker.write(inBox('ours'), schemaVersion: Schema.version, now: 111);
  check('有标记 → ours', contentsOf(inBox('ours')) == DirectoryContents.ours);
  check('标记文件名固定',
      DataMarker.fileIn(inBox('ours')).path ==
          p.join(inBox('ours'), '.shensuanzi-data'));
  fresh('foreign');
  Directory(inBox('foreign')).createSync(recursive: true);
  File(p.join(inBox('foreign'), '别人的报表.xlsx')).writeAsStringSync('x');
  check('非空且无标记 → foreign',
      contentsOf(inBox('foreign')) == DirectoryContents.foreign);
  fresh('broken');
  Directory(inBox('broken')).createSync(recursive: true);
  DataMarker.fileIn(inBox('broken')).writeAsStringSync('{ 坏的');
  check('标记损坏 → 仍 ours 但读出 null',
      contentsOf(inBox('broken')) == DirectoryContents.ours &&
          DataMarker.read(inBox('broken')) == null);
  final DataMarker? marker = DataMarker.read(inBox('ours'));
  check('标记往返一致（含 schema 版本）',
      marker != null &&
          marker.schemaVersion == Schema.version &&
          marker.createdAt == 111 &&
          marker.app == '神算子');
  check('字段类型不对 → null（不抛）', () {
    fresh('badtype');
    Directory(inBox('badtype')).createSync(recursive: true);
    DataMarker.fileIn(inBox('badtype'))
        .writeAsStringSync(jsonEncode(<String, Object?>{'schema_version': '三'}));
    return DataMarker.read(inBox('badtype')) == null;
  }());

  // ============================================================ 恢复
  section('启动恢复 resolved()');
  final AppBootstrap boot = bootstrapIn(box);
  check('没配过 → null（走向导）', boot.resolved() == null);
  final DataLocation created = boot.prepare(inBox('data'), now: 1700000000000);
  check('prepare 建目录 + 写标记 + 记配置',
      created.createdNow &&
          Directory(created.directory).existsSync() &&
          DataMarker.existsIn(created.directory) &&
          boot.loadConfig().dataDirectory == created.directory);
  check('备份目录是兄弟目录且不等于数据目录',
      created.backupDirectory == p.join(box.path, '神算子备份') &&
          created.backupDirectory != created.directory);
  final DataLocation? restored = boot.resolved();
  check('配过 + 有标记 → 直接复用（createdNow = false）',
      restored != null && !restored.createdNow && restored.directory == created.directory);
  check('数据库路径在数据目录里',
      restored != null &&
          restored.databasePath == p.join(created.directory, 'shensuanzi.db'));
  final DataLocation again = boot.prepare(inBox('data'), now: 999);
  check('再选同目录 → 复用且不重写标记',
      !again.createdNow && again.marker.createdAt == 1700000000000);
  boot.configStore.clear();
  check('配置被清 → resolved 走 null，但标记还在',
      boot.resolved() == null && DataMarker.existsIn(inBox('data')));
  final DataLocation recovered = boot.prepare(inBox('data'));
  check('重选原目录 → 数据立刻回来（createdNow = false）',
      !recovered.createdNow && recovered.marker.createdAt == 1700000000000);
  check('重选后 resolved 又能用', boot.resolved() != null);

  // ============================================================ 向导
  section('向导 prepare() 的拒绝路径');
  final AppBootstrap b2 = bootstrapIn(
    Directory(inBox('b2'))..createSync(recursive: true),
  );
  Directory(inBox('b2/other')).createSync(recursive: true);
  File(p.join(inBox('b2/other'), '别人的东西.txt')).writeAsStringSync('x');
  DataDirectoryRejected? rejected;
  try {
    b2.prepare(inBox('b2/other'));
  } on DataDirectoryRejected catch (error) {
    rejected = error;
  }
  check('非空且无标记 → 拒绝且带「怎么办」',
      rejected != null &&
          rejected.advice.verdict == DirectoryVerdict.reject &&
          rejected.howTo != null &&
          rejected.reason.contains('已经有别的东西'));
  check('拒绝后不写配置、不写标记',
      b2.loadConfig().dataDirectory == null &&
          !DataMarker.existsIn(inBox('b2/other')));
  final DataLocation accepted = b2.prepare(
    inBox('b2/other'),
    acceptForeignDirectory: true,
  );
  check('用户确认过 → 放行且不动里面的文件',
      accepted.createdNow &&
          File(p.join(inBox('b2/other'), '别人的东西.txt')).existsSync());
  int rejectedCount = 0;
  for (final String bad in <String>[
    r'C:\',
    r'C:\Windows\神算子',
    r'C:\Program Files\神算子',
    'data',
    '',
  ]) {
    try {
      b2.prepare(bad);
    } on DataDirectoryRejected {
      rejectedCount++;
    }
  }
  check('非法位置一律拒绝（5 种）', rejectedCount == 5, '$rejectedCount/5');
  final DataLocation deep = bootstrapIn(
    Directory(inBox('b3'))..createSync(recursive: true),
  ).prepare(p.join(inBox('b3'), 'a', 'b', '神算子数据'));
  check('目录不存在也会被创建', Directory(deep.directory).existsSync());

  // ============================================================ 数据库
  section('打开数据库');
  fresh('db');
  final AppBootstrap b4 = bootstrapIn(
    Directory(inBox('b4'))..createSync(recursive: true),
  );
  final DataLocation location = b4.prepare(inBox('db'));
  final Db db = b4.open(location);
  check('库文件已建', File(location.databasePath).existsSync());
  check('user_version = Schema.version',
      db.raw.select('PRAGMA user_version').first.values.first == Schema.version,
      '${db.raw.select('PRAGMA user_version').first.values.first}');
  check('主机端外键开着（与客户端镜像相反）', db.foreignKeysEnabled);
  db.close();

  // ============================================================ 收尾
  try {
    box.deleteSync(recursive: true);
  } catch (_) {
    // 临时目录删不掉不影响结论
  }

  stdout.writeln('\n${'=' * 46}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  if (_failures.isNotEmpty) {
    stdout.writeln('失败清单：');
    for (final String name in _failures) {
      stdout.writeln('  - $name');
    }
  }
  stdout.writeln('=' * 46);
  exit(_fail == 0 ? 0 : 1);
}
