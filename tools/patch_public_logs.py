# -*- coding: utf-8 -*-
"""日志透明化：NSLog 动态值加 %{public}@；服务器 accept 层加连接探针"""
import io
import re

path = "src/Tweak.m"
src = io.open(path, encoding="utf-8").read()

# ---- 1. BAEssentialLog / BALog 宏内 NSLog 自动 public 化 ----
# NSLog 不支持宏拼接替换 %，改为在调用处处理：把所有 %@ 改为 %{public}@
# 在 BAEssentialLog / BALog 使用的具体日志语句里替换。

replacements = [
    # rt-rewrite：路径和 URL 都要可见
    (u'''BAEssentialLog(@"rt-rewrite %@: %@",
                            childPath, [ns substringToIndex:MIN((NSUInteger)90, ns.length)]);''',
     u'''BAEssentialLog(@"rt-rewrite %{public}@: %{public}@",
                            childPath, [ns substringToIndex:MIN((NSUInteger)90, ns.length)]);'''),
    (u'''BALog(@"model-rewrite %@ [%@]", k, reason ?: @"?");''',
     u'''BALog(@"model-rewrite %{public}@ [%{public}@]", k, reason ?: @"?");'''),
    (u'''BAEssentialLog(@"seg req: Range=%@ (from=%lld to=%lld)",
                rangeHeader ?: @"(none)", reqFrom, reqTo);''',
     u'''BAEssentialLog(@"seg req: Range=%{public}@ (from=%lld to=%lld)",
                rangeHeader ?: @"(none)", reqFrom, reqTo);'''),
    (u'''BAEssentialLog(@"seg: window %lld-%lld (%lldMB) → %ld slices, %lldKB each",
          reqFrom, reqTo, windowSize / 1024 / 1024, (long)nseg, slice / 1024);''',
     u'''BAEssentialLog(@"seg: window %lld-%lld (%lldMB) → %ld slices, %lldKB each",
          reqFrom, reqTo, windowSize / 1024 / 1024, (long)nseg, slice / 1024);'''),
    (u'''NSLog(@"[BiliAcc] found reply class: %@", name);''',
     u'''NSLog(@"[BiliAcc] found reply class: %{public}@", name);'''),
    (u'''NSLog(@"[BiliAcc] no known reply class found; candidates: %@", hits);''',
     u'''NSLog(@"[BiliAcc] no known reply class found; candidates: %{public}@", hits);'''),
]
for old, new in replacements:
    if old in src:
        src = src.replace(old, new, 1)
    else:
        print("WARN: not found:", old[:60])

# ---- B. server accept 探针：每个连接读请求首行无条件记录（前 8 次） ----
old_serve = u'''        NSString *path = parts[1];
        NSURL *abs = [NSURL URLWithString:[@"http://127.0.0.1" stringByAppendingString:path]];
        NSURL *inner = [BABackend innerURLFor:abs.query ?: @""];'''
assert old_serve in src
new_serve = u'''        NSString *path = parts[1];
        BAEssentialLog(@"conn: %{public}@", path);
        NSURL *abs = [NSURL URLWithString:[@"http://127.0.0.1" stringByAppendingString:path]];
        NSURL *inner = [BABackend innerURLFor:abs.query ?: @""];'''
src = src.replace(old_serve, new_serve, 1)

io.open(path, "w", encoding="utf-8", newline="\n").write(src)
print("OK: public logs + connection probe")
