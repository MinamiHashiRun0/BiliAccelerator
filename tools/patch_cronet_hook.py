# -*- coding: utf-8 -*-
"""替换 Tweak.m 中的 Cronet hook 段：fishhook 版 → 符号表扫描 + inline hook 版"""
import io
import sys

path = "src/Tweak.m"
with io.open(path, "r", encoding="utf-8") as f:
    src = f.read()

start = src.find(u"// B 站 iOS 客户端内嵌 Chromium Cronet")
end = src.find("static NSURLSessionDataTask * (*BAOrigDataTask)")
assert start != -1 and end != -1 and start < end, (start, end)

new_block = u'''// B 站 iOS 客户端内嵌 Chromium Cronet（静态链接进主二进制）。
// gRPC 请求（PlayViewUnite 等）与媒体分片都从 Cronet 发出。
//
// hook 策略：fishhook 只能重绑间接符号引用（GOT/lazy stub），而主二进制内部
// 调用静态链接的 Cronet 函数是直接 bl 跳转，不经过 GOT —— fishhook 拦不到。
// 改用 Mach-O 符号表扫描：在主二进制 LC_SYMTAB 里找
// Cronet_UrlRequest_InitWithParams 的函数地址，入口写 ARM64 跳板指令
// （inline hook）。若符号在动态库里则回退 dlsym。
// 调真函数：入口 16 字节被覆盖，把原 16 字节拷进 RWX trampoline，
// 末尾接一条跳回 target+16 的指令（经典 trampoline）。

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/vm_map.h>
#import <mach/mach_init.h>
#import <libkern/OSCacheControl.h>

static void *BACronetTrampolineBuf = NULL;   // RWX trampoline（原指令 + 跳回）

// 我们的替换实现：改写 URL 后经 trampoline 调真函数。
// Cronet C API 签名（cronet_c_api.h，各版本稳定）：
//   Cronet_UrlRequest_InitWithParams(self, url, method, callback, params)
// ARM64 传参 x0..x4，我们只关心 x1 (url)。
static void BAHookCronetInit(void *a0, const char *url, const char *a2,
                             void *a3, void *a4) {
    NSString *u = url ? [NSString stringWithUTF8String:url] : nil;
    if (BAEnabled() && u && BAIsMediaURL([NSURL URLWithString:u]) &&
        !BAIsLiveMedia([NSURL URLWithString:u])) {
        NSString *reason = nil;
        NSString *next = BARewriteUrlDetail(u, &reason);
        if (![next isEqualToString:u]) {
            BALog(@"cronet-media [%@] → %@", reason ?: @"?",
                  [next substringToIndex:MIN((NSUInteger)120, next.length)]);
            url = [next UTF8String];
        }
    }
    if (BACronetTrampolineBuf) {
        ((void (*)(void *, const char *, const char *, void *, void *))BACronetTrampolineBuf)
            (a0, url, a2, a3, a4);
    }
}

// ARM64 跳板（写入被 hook 函数入口，12 字节有效 + 数据槽）：
//   ldr x16, [pc, #12]   ; x16 = *(entry+16)
//   br  x16
//   nop
//   .quad hookFn         ; 数据槽（占用 code[4..5]）
static void BAWriteJump(void *entry, void *hookFn) {
    uint32_t *code = (uint32_t *)entry;
    code[0] = 0x58000093;   // LDR X19, [PC, #16]  (imm 单位 4B：4*4=16 → &code[4])
    code[1] = 0xD61F0260;   // BR X19
    code[2] = 0xD503201F;   // NOP（对齐数据槽）
    uint64_t addr = (uint64_t)hookFn;
    memcpy(&code[4], &addr, 8);
    sys_icache_invalidate(entry, 32);
}

// 在主二进制符号表里按名字找函数地址（N_SECT + 已加载 slide）
static void *BAFindSymbolInMainBinary(const char *symbolName) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!mh || mh->filetype != MH_EXECUTE) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const uint8_t *base = (const uint8_t *)mh;
        const uint8_t *p = base + sizeof(struct mach_header_64);

        for (uint32_t c = 0; c < mh->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)p;
            if (lc->cmd == LC_SYMTAB) {
                const struct symtab_command *st = (const struct symtab_command *)p;
                const struct nlist_64 *syms = (const struct nlist_64 *)(base + st->symoff);
                const char *strtab = (const char *)(base + st->stroff);
                for (uint32_t s = 0; s < st->nsyms; s++) {
                    const struct nlist_64 *sym = &syms[s];
                    uint32_t strx = sym->n_un.n_strx;
                    if (strx == 0 || strx >= st->strsize) continue;
                    const char *name = strtab + strx;
                    if (name[0] == '_') name++;
                    if (strcmp(name, symbolName) == 0 && (sym->n_type & N_TYPE) == N_SECT) {
                        return (void *)(base + sym->n_value + slide);
                    }
                }
            }
            p += lc->cmdsize;
        }
        break;   // 只扫主二进制
    }
    return NULL;
}

// RWX trampoline：原 16 字节指令 + 跳回 target+16
static void *BAMakeTrampoline(void *target) {
    mach_vm_address_t addr = 0;
    kern_return_t kr = mach_vm_allocate(mach_task_self(), &addr, PAGE_SIZE, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) return NULL;
    kr = mach_vm_protect(mach_task_self(), addr, PAGE_SIZE, FALSE,
                         VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) return NULL;

    uint32_t *t = (uint32_t *)addr;
    memcpy(t, target, 16);                    // 原 4 条指令
    t[4] = 0x58000050;                        // LDR X16, [PC, #8] → &t[6]
    t[5] = 0xD61F0200;                        // BR X16
    uint64_t back = (uint64_t)target + 16;
    memcpy(&t[6], &back, 8);
    sys_icache_invalidate(t, 64);
    return t;
}

static void BAHookCronet(void) {
    void *target = BAFindSymbolInMainBinary("Cronet_UrlRequest_InitWithParams");
    if (target) {
        BALog(@"cronet symbol in main binary: %p", target);
    } else {
        target = dlsym(RTLD_DEFAULT, "Cronet_UrlRequest_InitWithParams");
        if (target) BALog(@"cronet symbol via dlsym: %p", target);
    }
    if (!target) {
        NSLog(@"[BiliAcc] Cronet_UrlRequest_InitWithParams NOT FOUND - hook skipped");
        return;
    }
    void *trampoline = BAMakeTrampoline(target);
    if (!trampoline) {
        NSLog(@"[BiliAcc] trampoline alloc FAILED");
        return;
    }
    BACronetTrampolineBuf = trampoline;

    mach_vm_address_t page = (mach_vm_address_t)target & ~(mach_vm_address_t)PAGE_MASK;
    kern_return_t kr = mach_vm_protect(mach_task_self(), page, PAGE_SIZE, FALSE,
                                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[BiliAcc] vm_protect FAILED: %d", kr);
        return;
    }
    BAWriteJump(target, (void *)BAHookCronetInit);
    NSLog(@"[BiliAcc] Cronet inline hook installed at %p (trampoline %p)", target, trampoline);
}

'''

src = src[:start] + new_block + src[end:]
with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(src)
print("OK, replaced %d chars" % (end - start))
