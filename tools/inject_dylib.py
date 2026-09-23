#!/usr/bin/env python3
"""inject_dylib.py — 向未加密 Mach-O 主程序注入 dylib 加载命令，
使 dylib 在 App 启动时自动加载（免越狱侧载/TrollStore/模拟器场景）。
默认强加载 LC_LOAD_DYLIB；--weak 使用 LC_LOAD_WEAK_DYLIB。

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

LC_LOAD_DYLIB = 0x0C       # 强加载（模拟器新运行时静默跳过 weak；缺库时硬报错更易定位）
LC_LOAD_WEAK_DYLIB = 0x18  # --weak 时使用
MH_MAGIC_64 = 0xFEEDFACF  # 小端读取字节 cf fa ed fe


def make_load_dylib(dylib_path, weak=False):
    """构造 dylib_command (LC_LOAD_WEAK_DYLIB)。
    结构: cmd(4) cmdsize(4) name.offset(4) timestamp(4) current_version(4)
          compatibility_version(4) + name 字符串(补齐到 4 字节)
    name.offset 恒为 24（6 个 4 字节头字段之后）。"""
    path_b = dylib_path.encode() + b"\x00"
    padded = (len(path_b) + 3) & ~3
    cmdsize = 24 + padded
    lc = struct.pack("<IIIIII",
                     LC_LOAD_WEAK_DYLIB if weak else LC_LOAD_DYLIB,  # cmd
                     cmdsize,              # cmdsize
                     24,                   # name.offset —— 字符串紧跟 24 字节头
                     0,                    # timestamp
                     0,                    # current_version
                     0)                    # compatibility_version
    lc += path_b + b"\x00" * (padded - len(path_b))
    assert len(lc) == cmdsize, "dylib_command size mismatch"
    return lc


def inject(data, dylib_path="@executable_path/Frameworks/BiliAccelerator.dylib", weak=False):
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        raise SystemExit("not a little-endian 64-bit Mach-O (input must be unencrypted iOS arm64 binary)")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    end_lc = 32 + sizeofcmds
    lc = make_load_dylib(dylib_path, weak)

    # 原位写入零填充区：end_lc 起必须有 >= len(lc) 的连续零
    run = 0
    while end_lc + run < len(data) and data[end_lc + run] == 0 and run < len(lc):
        run += 1
    if run < len(lc):
        raise SystemExit(
            f"load command 表后零填充不足（{run} < {len(lc)} 字节），"
            "无法原位注入 —— 请勿使用移动数据的旧方案")

    # 关键：LC_CODE_SIGNATURE 必须是最后一个 load command。
    # dyld 遇到 CS 后不再处理任何后续 dylib 命令（weak load 会被静默跳过）。
    # 所以：把我们的 LC 写到 CS 当前占的位置，CS 整体后移到零区末尾。
    cs_off = None
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x1D:  # LC_CODE_SIGNATURE
            cs_off = off
            break
        off += size

    out = bytearray(data)
    if cs_off is not None:
        cs_cmd = bytes(data[cs_off:cs_off + 16])
        # 新布局：[原有命令不动][我们的 LC @cs_off][CS @cs_off+len(lc)]
        # 需要从 cs_off+16 到 cs_off+len(lc)+16 全是零（旧 CS 后本来就是零区）
        zrun = 0
        while cs_off + 16 + zrun < len(data) and data[cs_off + 16 + zrun] == 0 and zrun < len(lc):
            zrun += 1
        if zrun < len(lc):
            raise SystemExit(f"零填充不足（{zrun} < {len(lc)}），无法容纳后移的 CS")
        out[cs_off:cs_off + len(lc)] = lc
        out[cs_off + len(lc):cs_off + len(lc) + 16] = cs_cmd
    else:
        out[end_lc:end_lc + len(lc)] = lc

    struct.pack_into("<I", out, 16, ncmds + 1)
    struct.pack_into("<I", out, 20, sizeofcmds + len(lc))
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--input", required=True)
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--dylib", default="@executable_path/Frameworks/BiliAccelerator.dylib")
    ap.add_argument("--weak", action="store_true", help="使用 LC_LOAD_WEAK_DYLIB（缺库静默跳过）")
    args = ap.parse_args()
    with open(args.input, "rb") as f:
        data = f.read()
    injected = inject(data, args.dylib, weak=args.weak)
    with open(args.output, "wb") as f:
        f.write(injected)
    cmd_name = "LC_LOAD_WEAK_DYLIB" if args.weak else "LC_LOAD_DYLIB"
    print(f"OK: {cmd_name} -> {args.dylib} injected into {args.output}")


if __name__ == "__main__":
    main()
