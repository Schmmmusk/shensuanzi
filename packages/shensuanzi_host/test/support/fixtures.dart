// 测试夹具（host 版）：固定时钟 + 内存库。
//
// ⚠️ **跨包不能共享 `test/` 目录**（`test/` 不属于包的公开面，无法 `package:` 导入），
// 所以这里是与 `shensuanzi_core/test/support/fixtures.dart` 的**精简镜像** ——
// 只含 host 测试实际用到的三项。
//
// 这是本仓库第二处「镜像必须同步」的地方（第一处是 `test/` ↔ `tool/selfcheck*.dart`）：
// **改夹具语义时，两个包的 fixtures 都要看。**
import 'package:shensuanzi_core/shensuanzi_core.dart';

int _clock = 1700000000000;

/// 单调递增的毫秒时间戳 —— 避免同毫秒导致的排序不确定性
int now() => _clock++;

void resetClock() => _clock = 1700000000000;

Db newMemoryDb({bool foreignKeys = true}) =>
    Db.openInMemory(foreignKeys: foreignKeys);
