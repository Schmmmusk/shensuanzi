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
  'blocked': ['antivirus: 未实现（需要 WMI，受限机器常被挡）'],
  'sources': {'cpu': 'registry', 'ram': 'ctypes', 'disk_model': 'registry'},
}
```
"""

from __future__ import annotations

import ctypes
import os
import platform
import subprocess
import sys
from typing import Any, Dict, List, Optional

_WIN = sys.platform.startswith("win")

#: 子进程兜底的统一超时（秒）。受限机器上 PowerShell 可能起不来，不能无限等。
_SUBPROC_TIMEOUT = 6.0


def _reg(path: str, name: str) -> Optional[str]:
    """读注册表字符串值；失败返回 None（**不抛**）。"""
    if not _WIN:
        return None
    try:
        import winreg  # noqa: PLC0415  （仅 Windows 有）

        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path) as key:
            value, _kind = winreg.QueryValueEx(key, name)
            return str(value).strip() or None
    except Exception:
        return None


def _run(cmd: List[str]) -> Optional[str]:
    """跑一条子进程并返回 stdout；失败/超时返回 None（**不抛**）。"""
    try:
        out = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=_SUBPROC_TIMEOUT,
            check=False,
        )
        text = out.stdout.decode("utf-8", "replace").strip()
        return text or None
    except Exception:
        return None


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
def collect() -> Dict[str, Any]:
    """采一次机器配置。**任何一项失败都不抛**，失败原因进 `blocked`。"""
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
    models = [
        d.get("model") for d in info.get("disks", []) if d.get("model")
    ]
    if models:
        parts.append("盘 %s" % " / ".join(models[:2]))
    return " / ".join(str(p) for p in parts)


if __name__ == "__main__":
    import json

    data = collect()
    print(json.dumps(data, ensure_ascii=False, indent=2))
    print("")
    print("摘要：%s" % summary(data))
    if data.get("blocked"):
        print("被挡/未做：")
        for item in data["blocked"]:
            print("  · %s" % item)
