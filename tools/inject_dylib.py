#!/usr/bin/env python3
"""inject_dylib.py — 向未加密 Mach-O 主程序注入 LC_LOAD_WEAK_DYLIB，
使 dylib 在 App 启动时自动加载（免越狱侧载/TrollStore 场景）。

用法:
  python inject_dylib.py -i binaries/executable -o injected_executable

来源约定: dylib 放在 IPA 的 <App>.app/Frameworks/ 下，
LC_LOAD_WEAK_DYLIB 使用 @executable_path/Frameworks/<name>.dylib。

实现说明（重要）:
  主二进制通常在 load command 表末尾之后、首个 section 数据之前有一段
  零填充区。注入时把新 LC **原位写入**这段零区（只更新 ncmds/sizeofcmds），
  绝不移动任何既有文件数据 —— 否则各 segment/section 的 fileoff 全部失效，
  codesign strict validation 直接报 "main executable failed strict validation"。
  若零区不够（罕见），报错退出而不是产生坏二进制。
"""
import struct
import sys
import argparse

LC_LOAD_WEAK_DYLIB = 0x18
MH_MAGIC_64 = 0xFEEDFACF  # 小端读取字节 cf fa ed fe


def make_load_weak_dylib(dylib_path="@executable_path/Frameworks/BiliAccelerator.dylib"):
    """构造 dylib_command (LC_LOAD_WEAK_DYLIB)。
    结构: cmd(4) cmdsize(4) name.offset(4) timestamp(4) current_version(4)
          compatibility_version(4) + name 字符串(补齐到 4 字节)
    name.offset 恒为 24（6 个 4 字节头字段之后）。"""
    path_b = dylib_path.encode() + b"\x00"
    padded = (len(path_b) + 3) & ~3
    cmdsize = 24 + padded
    lc = struct.pack("<IIIIII",
                     LC_LOAD_WEAK_DYLIB,   # cmd
                     cmdsize,              # cmdsize
                     24,                   # name.offset —— 字符串紧跟 24 字节头
                     0,                    # timestamp
                     0,                    # current_version
                     0)                    # compatibility_version
    lc += path_b + b"\x00" * (padded - len(path_b))
    assert len(lc) == cmdsize, "dylib_command size mismatch"
    return lc


def inject(data, dylib_path="@executable_path/Frameworks/BiliAccelerator.dylib"):
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        raise SystemExit("not a little-endian 64-bit Mach-O (input must be unencrypted iOS arm64 binary)")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    end_lc = 32 + sizeofcmds
    lc = make_load_weak_dylib(dylib_path)

    # 原位写入零填充区：end_lc 起必须有 >= len(lc) 的连续零
    run = 0
    while end_lc + run < len(data) and data[end_lc + run] == 0 and run < len(lc):
        run += 1
    if run < len(lc):
        raise SystemExit(
            f"load command 表后零填充不足（{run} < {len(lc)} 字节），"
            "无法原位注入 —— 请勿使用移动数据的旧方案")
    out = bytearray(data)
    out[end_lc:end_lc + len(lc)] = lc
    struct.pack_into("<I", out, 16, ncmds + 1)
    struct.pack_into("<I", out, 20, sizeofcmds + len(lc))
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--input", required=True)
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--dylib", default="@executable_path/Frameworks/BiliAccelerator.dylib")
    args = ap.parse_args()
    with open(args.input, "rb") as f:
        data = f.read()
    injected = inject(data, args.dylib)
    with open(args.output, "wb") as f:
        f.write(injected)
    print(f"OK: LC_LOAD_WEAK_DYLIB -> {args.dylib} injected into {args.output}")


if __name__ == "__main__":
    main()
