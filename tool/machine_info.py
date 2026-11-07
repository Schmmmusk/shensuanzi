# -*- coding: utf-8 -*-
"""机器配置采集（**只用标准库**，多路兜底，逐项记录来源/被挡原因）。

## 为什么单独一个文件

`perf_monitor.py` 与 `perf_bench.py` 都要报「这台机器是什么」，从前各写一份
（一个只有 `platform.node()` + `os.cpu_count()`，一个另写了内存）。两份必然漂移，
而且都**太薄** —— 2026-10-28 用户实测：报告里只能写「受设备策略限制，更精确的信息
无法获取」，事后两台机器的数据没法对照。

## 设计原则

1. **每一项都试多条路**：注册表 → ctypes → 子进程（PowerShell/wmic）→ 环境变量。
   受限机器上通常只是「某几条路被挡」，不是全挡。
2. **挡了要说话**：`blocked` 里记下「哪一项、试过什么、为什么失败」。
   静默留空最坏 —— 看报告的人会以为「这台机器没有这个字段」。
3. **不装第三方包**：`psutil` / `wmi` 在受限机器上装不上（这本身就是问题的一部分）。

## 输出

```python
{
  'host': 'L13', 'os': 'Windows-10-10.0.19045-SP0', 'os_build': '19045',
  'cpu': 'Intel(R) Core(TM) i5-11500 @ 2.70GHz', 'cores_logical': 12,
  'ram_gb': 15.9, 'disks': [{'drive': 'C:', 'type': 'fixed', 'model': 'Samsung SSD 970 EVO'}],
  'display_scale': 125, 'python': '3.8.4',
  'power_plan': 'Balanced', 'power_plan_guid': '381b4222-…', 'power_plan_name': '平衡',
  'blocked': ['antivirus: 未采集（需要 WMI，受限机器常被挡）'],
  'sources': {'cpu': 'registry', 'ram': 'ctypes', 'disk_model': 'registry'},
}
```

⚠️ **`power_plan` 对性能测试不是可选项**：「平衡」计划下 CPU 会降频，同一份库
同一份脚本能差出 2~3 倍。报告里没这一项，事后分不清「机器慢」还是「省电把
频率压下去了」。跨机器对比**认 `power_plan_guid`**（名称是本地化的）。

## 命令行

    python machine_info.py                              # JSON 打到终端
    python machine_info.py --json machine.json          # 纯 JSON 写文件，终端只给摘要
    python machine_info.py --json m.json --host-media "NVMe SSD（宿主）"

`--json` 写出的文件是**纯 JSON**（UTF-8 无 BOM，摘要与被挡项一律走终端），
这样多台测试机的档案才能被脚本直接 `json.load` 汇总。
未知参数会**报错退出（码 2）** —— 以前本文件没有参数解析，手册里的 `--json`
会被静默忽略（2026-11-07 用户审查 §一·1）。

⚠️ **`--host-media` 只能人工提供**：虚拟机里 Guest 看到的磁盘型号是虚拟化层造的，
**推不出**宿主物理介质（NVMe / SATA SSD / 机械盘）。不传就写进 `blocked`
（「未提供」）而不是留空 —— 静默留空会让人以为这项已经知道了。
没有它，首启 / 备份 / 造数这些 **I/O 数字不可跨机比较**。
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import platform
import re
import subprocess
import sys
from typing import Any, Dict, List, Optional

_WIN = sys.platform.startswith("win")

#: 子进程兜底的统一超时（秒）。受限机器上 PowerShell 可能起不来，不能无限等。
_SUBPROC_TIMEOUT = 6.0


def _reg(path: str, name: str) -> Optional[str]:
    """读注册表字符串值（HKLM）；失败返回 None（**不抛**）。"""
    if not _WIN:
        return None
    try:
        import winreg  # noqa: PLC0415  （仅 Windows 有）

        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path) as key:
            value, _kind = winreg.QueryValueEx(key, name)
            return str(value).strip() or None
    except Exception:
        return None


def _run(cmd: List[str], encoding: Optional[str] = None) -> Optional[str]:
    """跑一条子进程并返回 stdout；失败/超时返回 None（**不抛**）。

    `encoding` 默认按 UTF-8 解（`platform` / `wmic` 那几条是 UTF-8）。
    ⚠️ **`powercfg` 不是** —— 它按**系统 OEM 代码页**输出，中文系统上按 UTF-8 解
    会把电源计划名解成乱码（`高性�?`）。所以那一条显式传 `locale` 编码。
    """
    try:
        out = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=_SUBPROC_TIMEOUT,
            check=False,
        )
    except Exception:
        return None
    if encoding is None:
        text = out.stdout.decode("utf-8", "replace")
    else:
        try:
            text = out.stdout.decode(encoding, "replace")
        except LookupError:
            # 极端环境（locale 被禁用）拿不到编码名 ⇒ 退回 UTF-8，
            # 顶多计划名是乱码，不影响 GUID（GUID 是 ASCII，判读够用）。
            text = out.stdout.decode("utf-8", "replace")
    text = text.strip()
    return text or None


# --------------------------------------------------------------------------- CPU
def _cpu(info: Dict[str, Any], blocked: List[str], sources: Dict[str, str]) -> None:
    name = _reg(
        r"HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString"
    )
    if name:
        info["cpu"] = " ".join(name.split())  # 注册表里常有多余空格
        sources["cpu"] = "registry"
    else:
        fallback = platform.processor() or platform.machine()
        if fallback:
            info["cpu"] = fallback
            sources["cpu"] = "platform"
        else:
            blocked.append("cpu: 注册表与 platform 都拿不到型号")

    info["cores_logical"] = os.cpu_count()
    # 物理核：注册表里每个 CentralProcessor\N 是一个**逻辑**处理器，
    # 物理核要靠 CoreCount（Win10 才有，且部分机器没有）—— 拿不到就只报逻辑核
    cores_per_socket = _reg(
        r"HARDWARE\DESCRIPTION\System\CentralProcessor\0", "~MHz"
    )
    if cores_per_socket:
        info["cpu_mhz"] = cores_per_socket


# --------------------------------------------------------------------------- 内存
class _MEMORYSTATUSEX(ctypes.Structure):
    _fields_ = [
        ("dwLength", ctypes.c_ulong),
        ("dwMemoryLoad", ctypes.c_ulong),
        ("ullTotalPhys", ctypes.c_ulonglong),
        ("ullAvailPhys", ctypes.c_ulonglong),
        ("ullTotalPageFile", ctypes.c_ulonglong),
        ("ullAvailPageFile", ctypes.c_ulonglong),
        ("ullTotalVirtual", ctypes.c_ulonglong),
        ("ullAvailVirtual", ctypes.c_ulonglong),
        ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
    ]


def _ram(info: Dict[str, Any], blocked: List[str], sources: Dict[str, str]) -> None:
    if not _WIN:
        blocked.append("ram: 非 Windows，未实现")
        return
    try:
        stat = _MEMORYSTATUSEX()
        stat.dwLength = ctypes.sizeof(_MEMORYSTATUSEX)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
            info["ram_gb"] = round(stat.ullTotalPhys / (1024.0**3), 1)
            sources["ram"] = "ctypes"
            return
    except Exception:
        pass
    blocked.append("ram: GlobalMemoryStatusEx 失败")


# --------------------------------------------------------------------------- 磁盘
#: `GetDriveTypeW` 的返回值 → 中文（用户看得懂的类型）
_DRIVE_TYPES = {
    0: "unknown",
    1: "no_root",
    2: "removable",
    3: "fixed",
    4: "network",
    5: "cdrom",
    6: "ramdisk",
}


def _disk_models_from_registry() -> List[str]:
    """从 `Services\\disk\\Enum` 读物理磁盘型号。

    这条路的好处：**只要注册表能读就行**，不需要 WMI / PowerShell
    （受限机器上后两者最常被策略挡掉）。值是形如
    `NVMe Samsung SSD 970 EVO Plus 1TB` / `SCSI\\Disk&Ven_...` 的实例串。
    """
    models: List[str] = []
    if not _WIN:
        return models
    try:
        import winreg  # noqa: PLC0415

        with winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Services\disk\Enum"
        ) as key:
            index = 0
            while True:
                try:
                    value, _kind = winreg.EnumValue(key, index)
                except OSError:
                    break
                index += 1
                if not value.isdigit():
                    continue
                text = str(value).strip()
                if text:
                    models.append(text)
    except Exception:
        pass
    return models


def _disks(info: Dict[str, Any], blocked: List[str], sources: Dict[str, str]) -> None:
    drives: List[Dict[str, Any]] = []
    if _WIN:
        try:
            mask = ctypes.windll.kernel32.GetLogicalDrives()
            for i in range(26):
                if not (mask >> i) & 1:
                    continue
                letter = "%s:\\" % chr(ord("A") + i)
                kind = ctypes.windll.kernel32.GetDriveTypeW(ctypes.c_wchar_p(letter))
                drives.append(
                    {
                        "drive": letter[:2],
                        "type": _DRIVE_TYPES.get(kind, str(kind)),
                    }
                )
            sources["drives"] = "ctypes"
        except Exception:
            blocked.append("drives: GetLogicalDrives 失败")

    models = _disk_models_from_registry()
    if models:
        # 型号按顺序贴到固定盘上（不保证一一对应 —— 注册表里没有盘符映射；
        # 但「这台机器装了什么盘」这个信息本身就够做横向对比）
        fixed = [d for d in drives if d["type"] == "fixed"]
        for i, model in enumerate(models):
            if i < len(fixed):
                fixed[i]["model"] = model
            else:
                drives.append({"drive": None, "type": "physical", "model": model})
        sources["disk_model"] = "registry"
    else:
        # 兜底 1：PowerShell（受限机器上常被挡）
        text = _run(
            [
                "powershell",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "(Get-PhysicalDisk | Select-Object -First 4 | "
                "ForEach-Object { $_.Model }) -join ';'",
            ]
        )
        if text:
            for i, model in enumerate(text.split(";")):
                if model.strip():
                    if i < len(drives):
                        drives[i]["model"] = model.strip()
                    else:
                        drives.append(
                            {"drive": None, "type": "physical", "model": model.strip()}
                        )
            sources["disk_model"] = "powershell"
        else:
            blocked.append("disk_model: 注册表为空，PowerShell 也不可用（策略受限？）")

    info["disks"] = drives


# --------------------------------------------------------------------------- 电源计划
#: 常见电源计划的**固定 GUID** ⇒ 规范英文名。
#:
#: 为什么要这张表：`powercfg` 输出的是**本地化名称**，中文系统上是「高性能」，
#: 而且按错代码页解会成乱码。GUID 是恒定的 ⇒ 跨机器对比**认 GUID**，
#: 名称只是给人看的。
_POWER_PLAN_NAMES = {
    "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c": "High performance",
    "a1841308-3541-4fab-bc81-f71556f20b4a": "Power saver",
    "381b4222-f694-41f0-9685-ff5bb260df2e": "Balanced",
    "e9a42b02-d5df-448d-aa00-03f14749eb61": "Ultimate performance",
}

_GUID_RE = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")


def _power_plan(info: Dict[str, Any], blocked: List[str], sources: Dict[str, str]) -> None:
    """当前电源计划（GUID + 名称）。

    **为什么性能测试要记这个**：「平衡」计划下 CPU 会降频，同一份库同一份脚本，
    换计划能差出 2~3 倍。报告里没有这一项，事后根本分不清「机器慢」还是
    「省电模式把频率压下去了」—— 而这在笔记本 / VM 上极其常见。

    两条路，顺序**故意**是注册表在前：
    1. HKLM `SYSTEM\\CurrentControlSet\\Control\\Power\\User\\Default\\PowerSchemes`
       的 `ActivePowerScheme` ⇒ **只要 GUID**，不起子进程，受限策略下通常也能读到
       （键名里有 `User` 但它在 HKLM 下，是「当前用户的生效值」）；
    2. `powercfg /getactivescheme` ⇒ 多一个**本地化名称**给人看。
    """
    if not _WIN:
        blocked.append("power_plan: 非 Windows，未实现")
        return

    guid = _reg(
        r"SYSTEM\CurrentControlSet\Control\Power\User\Default\PowerSchemes",
        "ActivePowerScheme",
    )
    if guid and _GUID_RE.fullmatch(guid):
        info["power_plan_guid"] = guid.lower()
        sources["power_plan"] = "registry"
    elif guid:
        blocked.append("power_plan: 注册表里的 ActivePowerScheme 不像 GUID：%s" % guid[:60])

    text = _run(["powercfg", "/getactivescheme"], encoding="locale")
    if text:
        found = _GUID_RE.search(text)
        if found:
            got = found.group(0).lower()
            # 注册表与 powercfg 都有时以 powercfg 为准（同一台机器上两者必然一致，
            # 不一致说明读错了键 —— 那更要留下能看见的那个）
            if guid and guid.lower() != got:
                blocked.append(
                    "power_plan: 注册表(%s) 与 powercfg(%s) 不一致，采用 powercfg"
                    % (guid.lower(), got)
                )
            info["power_plan_guid"] = got
            sources["power_plan"] = "powercfg"
            # 名称：powercfg 的输出形如
            #   电源方案 GUID: 381b4222-…  (平衡)
            # ⇒ 优先取**括号里**的内容；没有括号就取 GUID 之后的整段。
            # 顺手去掉「名称:」这类前缀标签与首尾空白。
            tail = text[found.end():].strip()
            paren = re.search(r"[（(]([^（）()]+)[）)]", tail)
            if paren:
                tail = paren.group(1)
            tail = re.sub(r"^[\s:：]*(?:电源方案|方案|名称|Name)?[\s:：]*", "", tail).strip()
            if tail:
                info["power_plan_name"] = tail
        else:
            blocked.append("power_plan: powercfg 有输出但解析不出 GUID：%s" % text[:80])

    if not info.get("power_plan_guid"):
        blocked.append("power_plan: 注册表与 powercfg 都没拿到（策略挡了 powercfg？）")
        return

    canonical = _POWER_PLAN_NAMES.get(info["power_plan_guid"])
    if canonical:
        info["power_plan"] = canonical
    else:
        # 第三方 / OEM 自定义计划：没有规范名，就用本地化名（没有则只报 GUID）
        info["power_plan"] = info.get("power_plan_name") or info["power_plan_guid"]


# --------------------------------------------------------------------------- 显示
def _display(info: Dict[str, Any], blocked: List[str], sources: Dict[str, str]) -> None:
    if not _WIN:
        blocked.append("display_scale: 非 Windows，未实现")
        return
    try:
        # Win10 1607+；老系统会抛，走注册表兜底
        dpi = int(ctypes.windll.user32.GetDpiForSystem())
        info["display_scale"] = round(dpi * 100.0 / 96.0)
        sources["display_scale"] = "GetDpiForSystem"
        return
    except Exception:
        pass
    # 兜底：注册表 LogPixels（老系统 / 未重启时可能不准，但聊胜于无）
    pixels = _reg(r"Control Panel\Desktop", "LogPixels") or _reg(
        r"Control Panel\Desktop\WindowMetrics", "AppliedDPI"
    )
    try:
        if pixels:
            info["display_scale"] = round(int(pixels) * 100.0 / 96.0)
            sources["display_scale"] = "registry"
            return
    except Exception:
        pass
    blocked.append("display_scale: GetDpiForSystem 与注册表都没拿到")


# --------------------------------------------------------------------------- 入口
def collect(host_media: Optional[str] = None) -> Dict[str, Any]:
    """采一次机器配置。**任何一项失败都不抛**，失败原因进 `blocked`。

    `host_media`：宿主物理存储介质（如「NVMe SSD」）。**虚拟机里采不到** ——
    Guest 看到的固定磁盘是虚拟化层造的，推不出宿主是 NVMe / SATA SSD 还是机械盘，
    只能由人确认后传进来（`--host-media`）。不传就写进 `blocked`，
    免得看报告的人以为「这台机器的磁盘类型已经知道了」。
    """
    info: Dict[str, Any] = {
        "host": platform.node(),
        "os": platform.platform(),
        "os_build": platform.version(),
        "python": platform.python_version(),
        "arch": platform.machine(),
    }
    blocked: List[str] = []
    sources: Dict[str, str] = {}

    _cpu(info, blocked, sources)
    _ram(info, blocked, sources)
    _disks(info, blocked, sources)
    _display(info, blocked, sources)
    _power_plan(info, blocked, sources)

    if host_media:
        info["host_media"] = host_media
        sources["host_media"] = "人工提供（--host-media）"
    else:
        # 明确写出来：这项**采不到**，不是「没有」
        blocked.append(
            "host_media: 未提供 —— 虚拟机里 Guest 推不出宿主物理介质，"
            "需人工确认后加 --host-media 记录（影响首启/备份/造数等 I/O 数字的可比性）"
        )

    # 明确写出来：这项**没做**，别让看报告的人以为「这台机器没有杀软」
    blocked.append("antivirus: 未采集（需 WMI，受限机器常被策略挡）")

    info["blocked"] = blocked
    info["sources"] = sources
    return info


def summary(info: Dict[str, Any]) -> str:
    """一行摘要（报告里「本机」那行用它）。"""
    parts = [
        info.get("host", "?"),
        info.get("os", "?"),
        info.get("cpu") or "CPU 未知",
        "%s 核" % (info.get("cores_logical") or "?"),
        "%s GB" % (info.get("ram_gb") or "?"),
    ]
    scale = info.get("display_scale")
    if scale:
        parts.append("缩放 %s%%" % scale)
    plan = info.get("power_plan")
    if plan:
        parts.append("电源 %s" % plan)
    models = [
        d.get("model") for d in info.get("disks", []) if d.get("model")
    ]
    if models:
        parts.append("盘 %s" % " / ".join(models[:2]))
    # 宿主介质单独标：虚拟机里上面那个「盘」是虚拟化层的假型号，
    # 真正决定 I/O 数字可比性的是这一项（人工提供，见 --host-media）
    media = info.get("host_media")
    if media:
        parts.append("宿主介质 %s" % media)
    return " / ".join(str(p) for p in parts)


def _build_parser() -> "argparse.ArgumentParser":
    parser = argparse.ArgumentParser(
        prog="machine_info.py",
        description="采集一次机器档案（只读，只用标准库；受限机器上逐项降级）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例：\n"
            "  python machine_info.py                      # JSON 打到终端\n"
            "  python machine_info.py --json machine.json  # 纯 JSON 写文件，终端只给摘要\n"
            "\n"
            "⚠️ 为什么测试手册要求用 --json 落盘：报告里贴的是给人看的摘要，\n"
            "   而**多台测试机的数据要自动汇总**只能靠这份纯 JSON。\n"
            "   文件里只有 JSON —— 摘要与「被挡项」一律走终端，不混进文件。\n"
        ),
    )
    parser.add_argument(
        "--json",
        dest="json_out",
        default=None,
        metavar="F",
        help="把**纯 JSON** 写进文件 F（UTF-8 无 BOM）；终端只打印一行摘要",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="不打印「被挡/未做」清单（写文件配 --json 时用）",
    )
    parser.add_argument(
        "--host-media",
        dest="host_media",
        default=None,
        metavar="文本",
        help="宿主物理存储介质（如「NVMe SSD」）。**虚拟机里采不到**，"
        "只能人工确认后传进来；不传会在 blocked 里写明「未提供」",
    )
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    """返回退出码：0 正常 · 2 用法错 · 3 JSON 写不出去。

    ⚠️ 这里必须有真正的参数解析（2026-11-07 用户审查 §一·1）：以前本文件**没有
    argparse、也不读 `sys.argv`**，手册里那句 `--json machine.json` 会被**静默忽略**
    —— 既不生成文件，也不报错。测试者照着手册敲，到汇总时才发现文件不存在。
    现在未知参数由 argparse 直接报错退出（退出码 2），不再假装成功。
    """
    args = _build_parser().parse_args(argv)
    data = collect(host_media=args.host_media)

    if args.json_out:
        # 文件内容 = **纯 JSON**，一个字的杂讯都不能有（下游要 json.load 它）。
        # newline="\n" + encoding="utf-8" ⇒ 无 BOM、不被 Windows 换行污染。
        try:
            with open(args.json_out, "w", encoding="utf-8", newline="\n") as fh:
                json.dump(data, fh, ensure_ascii=False, indent=2)
                fh.write("\n")
        except OSError as exc:
            print("⛔ 写不出 %s：%s" % (args.json_out, exc), file=sys.stderr)
            return 3
        print("已写 %s（纯 JSON，%d 项）" % (args.json_out, len(data)))
        print("摘要：%s" % summary(data))
    else:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        print("")
        print("摘要：%s" % summary(data))

    if data.get("blocked") and not args.quiet:
        print("被挡/未做：")
        for item in data["blocked"]:
            print("  · %s" % item)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
