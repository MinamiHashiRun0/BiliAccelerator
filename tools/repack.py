#!/usr/bin/env python3
"""repack.py — 解包 IPA、注入 dylib、重打包。

用法:
  python repack.py original.ipa BiliAccelerator.dylib -o accelerated.ipa

步骤:
  1. 解包 Payload/*.app
  2. 检查主二进制是否已加密（FairPlay 染色 → 必须用脱壳版 IPA）
  3. 向主二进制注入 LC_LOAD_WEAK_DYLIB
  4. 把 dylib 放入 <App>.app/Frameworks/
  5. 重新 zip 为 IPA（TrollStore 侧载会重新签名，此处无需真签名）
"""
import argparse
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF  # 小端读取字节 cf fa ed fe
LC_ENCRYPTION_INFO = 0x2C  # LC_ENCRYPTION_INFO_64


def is_encrypted(binary: bytes) -> bool:
    magic = struct.unpack_from("<I", binary, 0)[0]
    if magic != MH_MAGIC_64:
        raise SystemExit("主二进制不是 arm64 little-endian Mach-O —— 请确认 IPA 已脱壳")
    ncmds = struct.unpack_from("<I", binary, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", binary, off)
        if cmd == LC_ENCRYPTION_INFO:
            # LC_ENCRYPTION_INFO_64: cmd(0) cmdsize(4) cryptoff(8) cryptsize(12) cryptid(16)
            cryptid = struct.unpack_from("<I", binary, off + 16)[0]
            return cryptid != 0
        off += size
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa")
    ap.add_argument("dylib")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    dylib = Path(args.dylib)
    if not dylib.exists():
        raise SystemExit(f"dylib 不存在: {dylib}")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        app_dir = tmp / "payload"
        app_dir.mkdir()
        print("[1/4] 解包 IPA ...")
        with zipfile.ZipFile(args.ipa) as z:
            z.extractall(app_dir)

        apps = list((app_dir / "Payload").glob("*.app"))
        if not apps:
            raise SystemExit("IPA 中未找到 .app")
        app = apps[0]

        # 找主二进制（Info.plist 的 CFBundleExecutable）
        plist = app / "Info.plist"
        exe_name = subprocess.run(
            ["plutil", "-extract", "CFBundleExecutable", "raw", "-o", "-", str(plist)],
            capture_output=True, text=True,
        ).stdout.strip()
        if not exe_name:
            # 回退：取 .app 目录名
            exe_name = app.stem
        exe = app / exe_name
        if not exe.exists():
            raise SystemExit(f"主二进制不存在: {exe}")

        print("[2/4] 检查 FairPlay 加密 ...")
        raw = exe.read_bytes()
        if is_encrypted(raw):
            raise SystemExit(
                "主二进制 cryptid=1（App Store 加密版）。\n"
                "必须使用脱壳后的 IPA（dumpdecrypted/破解源下载）才能注入。"
            )

        print("[3/4] 注入 LC_LOAD_WEAK_DYLIB ...")
        here = Path(__file__).parent
        injected = tmp / "injected_binary"
        subprocess.run(
            [sys.executable, str(here / "inject_dylib.py"),
             "-i", str(exe), "-o", str(injected),
             "--dylib", f"@executable_path/Frameworks/{dylib.name}"],
            check=True,
        )
        shutil.copy2(injected, exe)
        exe.chmod(0o755)

        # 放入 Frameworks/
        fw = app / "Frameworks"
        fw.mkdir(exist_ok=True)
        shutil.copy2(dylib, fw / dylib.name)

        # 删除原有签名目录（TrollStore 侧载时会重新签名）
        sig = app / "_CodeSignature"
        if sig.exists():
            shutil.rmtree(sig)

        print("[4/4] 重新打包 ...")
        out = Path(args.output)
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for f in app_dir.rglob("*"):
                z.write(f, f.relative_to(app_dir))

        print(f"完成: {out}")


if __name__ == "__main__":
    main()
