# -*- coding: utf-8 -*-
"""解析脱壳主二进制 ObjC 元数据（v3，段布局 vmaddr@+24 fileoff@+40）
class_t: isa(8) super(8) cache(16) bits(8)  → data 指针在 +32
  bits 低 2 位是 FAST flags；若高位有 RW 标志需先解 rw→ro（本包为 shared cache style，
  chained fixups + pre-optimized：DATA_CONST 里的指针是 rebase 后值？未重签 binary 里
  指针为 0 或需要 chained fixups 解码 —— 先检查首类值判断）"""
import struct

BIN = "_ipa/Payload/bili-universal.app/bili-universal"
data = open(BIN, "rb").read()

ncmds = struct.unpack_from("<I", data, 16)[0]
off = 32
SEGS = []
SEC = {}
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, off)
    if cmd == 0x19:
        segname = data[off + 8:off + 24].rstrip(b"\0").decode()
        vm = struct.unpack_from("<Q", data, off + 24)[0]
        fo = struct.unpack_from("<Q", data, off + 40)[0]
        fsz = struct.unpack_from("<Q", data, off + 48)[0]
        SEGS.append((vm, fo, fsz))
        nsects = struct.unpack_from("<I", data, off + 64)[0]
        so = off + 72
        for s in range(nsects):
            sect = data[so:so + 80]
            sectname = sect[0:16].rstrip(b"\0").decode()
            sname = sect[16:32].rstrip(b"\0").decode()
            addr, sz = struct.unpack_from("<QQ", sect, 32)
            SEC[(segname, sectname, sname)] = (addr, sz)
            so += 80
    off += size

def to_file(addr):
    for vm, fo, fsz in SEGS:
        if vm <= addr < vm + fsz:
            return fo + (addr - vm)
    return None

def u64(addr):
    fo = to_file(addr)
    return struct.unpack_from("<Q", data, fo)[0] if fo is not None else 0

def u32(addr):
    fo = to_file(addr)
    return struct.unpack_from("<I", data, fo)[0] if fo is not None else 0

def cstr(addr):
    fo = to_file(addr)
    if fo is None: return ""
    end = data.find(b"\0", fo)
    if end == -1: return ""
    return data[fo:end].decode("utf-8", "replace")

# --- 先判定是否 LC_DYLD_CHAINED_FIXUPS（指针未 rebase，是编码链） ---
has_chained = False
off = 32
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, off)
    if cmd in (0x80000034, 0x34):  # LC_DYLD_CHAINED_FIXUPS
        has_chained = True
    off += size
print("chained fixups:", has_chained)

cla = szc = None
for (seg, sect, sname), (a, s) in SEC.items():
    if sect == "__objc_classlist":
        cla, szc = a, s
        break
print("classlist vm=0x%x size=%d" % (cla, szc))
vals = [u64(cla + i * 8) for i in range(4)]
print("first entries:", [hex(v) for v in vals])
