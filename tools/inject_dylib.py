#!/usr/bin/env python3
"""inject_dylib.py — 向未加密 Mach-O 主程序注入 LC_LOAD_WEAK_DYLIB，
使 dylib 在 App 启动时自动加载（免越狱侧载/TrollStore 场景）。

用法:
  python inject_dylib.py < binaries/executable > injected_executable
  python inject_dylib.py -i binaries/executable -o injected_executable

来源约定: dylib 放在 IPA 的 Applications/<App>.app/Frameworks/ 下，
LC_LOAD_WEAK_DYLIB 使用 @rpath/BiliAccelerator.dylib，
主程序 Info.plist 或主程序本身需要有合适的 LC_RPATH（@executable_path/Frameworks 一般已存在）。
"""
import struct
import sys
import argparse

LC_LOAD_WEAK_DYLIB = 0x18
LC_RPATH = 0x1C | 0x80000000  # LC_RPATH with支撑位，实际值 0x1c800000
MH_MAGIC_64 = 0xFeedFacf
MH_CIGAM_64 = 0xCFaFEDFe

def read_u32(data, off):
    return struct.unpack_from("<I", data, off)[0]

def find_inject_point(data):
    """在第一个 load command 结束之后注入（把所有 LC 后移）"""
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_CIGAM_64:
        raise SystemExit("not a little-endian 64-bit Mach-O (input must be unencrypted iOS arm64 binary)")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    sizeofcmds = struct.unpack_from("<I", data, 20)[0]
    header_size = 32
    return header_size + sizeofcmds, ncmds

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

def inject(data, dylib_path="@rpath/BiliAccelerator.dylib"):
    inject_off, _ = find_inject_point(data)
    lc = make_load_weak_dylib(dylib_path)
    # 重写 ncmds 和 sizeofcmds
    ncmds = struct.unpack_from("<I", data, 16)[0] + 1
    sizeofcmds = struct.unpack_from("<I", data, 20)[0] + len(lc)
    out = bytearray(data)
    struct.pack_into("<I", out, 16, ncmds)
    struct.pack_into("<I", out, 20, sizeofcmds)
    return bytes(out[:inject_off]) + lc + bytes(out[inject_off:])

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
