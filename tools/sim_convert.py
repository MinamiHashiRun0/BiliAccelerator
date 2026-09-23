#!/usr/bin/env python3
"""sim_convert.py — 把脱壳设备版 IPA 转换为 iOS 模拟器可安装的 .app。

原理:
  模拟器 dyld 只加载 platform=iOSSimulator(7) 的 Mach-O；设备版是 platform=iOS(2)。
  把主二进制 + 所有内嵌二进制(.app/.framework/.appex) 的 LC_BUILD_VERSION
  platform 字段原位改写 2 -> 7（4 字节，不移动数据），dylib 用 iphonesimulator
  SDK 重编后注入。模拟器不做代码签名校验，可整包 ad-hoc 或直接去签名。

用法:
  python3 tools/sim_convert.py <脱壳.ipa> <BiliAccelerator.dylib> -o <输出.app目录>

注意:
  - 设备专用扩展(.appex)对播放测试无意义，直接去掉，避免安装校验纠缠
  - 去掉 _CodeSignature（模拟器不校验，残留坏签名反而干扰）
"""
import argparse
import shutil
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
PLATFORM_IOS = 2
PLATFORM_IOSSIMULATOR = 7


def iter_macho_offsets(data: bytes):
    """yield (cmd_offset, cmd, size) for a thin arm64 Mach-O"""
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        return
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    for _ in range(ncmds):
        if off + 8 > len(data):
            return
        cmd, size = struct.unpack_from("<II", data, off)
        if size == 0:
            return
        yield off, cmd, size
        off += size


def patch_platform(data: bytearray, path: str) -> bool:
    """LC_BUILD_VERSION platform 2 -> 7。返回是否修改。"""
    changed = False
    for off, cmd, size in iter_macho_offsets(bytes(data)):
        if cmd == LC_BUILD_VERSION:
            plat = struct.unpack_from("<I", data, off + 8)[0]
            if plat == PLATFORM_IOS:
                struct.pack_into("<I", data, off + 8, PLATFORM_IOSSIMULATOR)
                print(f"  patched platform 2->7: {path}")
                changed = True
    return changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa")
    ap.add_argument("dylib")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    out = Path(args.output)
    if out.exists():
        shutil.rmtree(out)
    out.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        with zipfile.ZipFile(args.ipa) as z:
            z.extractall(tmp)
        app = next((tmp / "Payload").glob("*.app"))

        print("[1/4] 移除扩展与旧签名 ...")
        for extra in ("PlugIns",):
            p = app / extra
            if p.exists():
                shutil.rmtree(p)
        for sig in app.rglob("_CodeSignature"):
            shutil.rmtree(sig)

        print("[2/4] 补丁 LC_BUILD_VERSION platform 2->7 ...")
        binaries = [app / "Info.plist"]
        # 找所有 Mach-O：主二进制 + 内嵌 framework 二进制
        for f in app.rglob("*"):
            if not f.is_file():
                continue
            try:
                head = f.open("rb").read(32)
            except OSError:
                continue
            if len(head) >= 32 and struct.unpack_from("<I", head, 0)[0] == MH_MAGIC_64:
                data = bytearray(f.read_bytes())
                if patch_platform(data, str(f.relative_to(app))):
                    f.write_bytes(bytes(data))

        print("[3/4] 注入 dylib（原位，零填充区） ...")
        exe_name = subprocess.run(
            ["plutil", "-extract", "CFBundleExecutable", "raw", "-o", "-", str(app / "Info.plist")],
            capture_output=True, text=True).stdout.strip() or app.stem
        exe = app / exe_name
        subprocess.run(
            ["python3", str(Path(__file__).parent / "inject_dylib.py"),
             "-i", str(exe), "-o", str(exe) + ".inj",
             "--dylib", "@executable_path/Frameworks/" + Path(args.dylib).name],
            check=True)
        shutil.move(str(exe) + ".inj", exe)
        exe.chmod(0o755)

        print("[4/4] 放入 dylib + 校验 platform ...")
        fw = app / "Frameworks"
        fw.mkdir(exist_ok=True)
        shutil.copy2(args.dylib, fw / Path(args.dylib).name)

        shutil.copytree(app, out)
        print(f"完成: {out}")
        # 快速自检：确认主二进制 platform 已是 7
        main_data = exe.read_bytes()
        for off, cmd, size in iter_macho_offsets(main_data):
            if cmd == LC_BUILD_VERSION:
                plat = struct.unpack_from("<I", main_data, off + 8)[0]
                print(f"  主二进制 platform = {plat} (7=iOSSimulator)")
                break


if __name__ == "__main__":
    main()
