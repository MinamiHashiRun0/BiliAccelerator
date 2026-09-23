# -*- coding: utf-8 -*-
"""%{public}@ 在该 iOS 组合下显示 <decode: missing data>。
换 %{public}s + UTF8String（oslog 对 C 字符串的 public 标准形式）。"""
import io

path = "src/Tweak.m"
src = io.open(path, encoding="utf-8").read()

subs = [
    # rt-rewrite
    (u'''                        NSString *ns = (NSString *)next;
                        BAEssentialLog(@"rt-rewrite %{public}@: %{public}@",
                            childPath, [ns substringToIndex:MIN((NSUInteger)90, ns.length)]);''',
     u'''                        NSString *ns = (NSString *)next;
                        NSString *pv = [ns length] > 90 ? [ns substringToIndex:90] : ns;
                        BAEssentialLog(@"rt-rewrite %{public}s: %{public}s",
                            childPath ? childPath.UTF8String : "(nil)",
                            pv.UTF8String ?: "");'''),
    # found reply class
    (u'''            NSLog(@"[BiliAcc] found reply class: %{public}@", name);''',
     u'''            NSLog(@"[BiliAcc] found reply class: %{public}s", name.UTF8String);'''),
    # candidates
    (u'''        NSLog(@"[BiliAcc] no known reply class found; candidates: %{public}@", hits);''',
     u'''        NSLog(@"[BiliAcc] no known reply class found; candidates: %{public}s", hits.description.UTF8String);'''),
    # conn probe
    (u'''        BAEssentialLog(@"conn: %{public}@", path);''',
     u'''        BAEssentialLog(@"conn: %{public}s", path.UTF8String);'''),
    # seg req Range
    (u'''            BAEssentialLog(@"seg req: Range=%{public}@ (from=%lld to=%lld)",
                rangeHeader ?: @"(none)", reqFrom, reqTo);''',
     u'''            BAEssentialLog(@"seg req: Range=%{public}s (from=%lld to=%lld)",
                (rangeHeader ?: @"(none)").UTF8String, reqFrom, reqTo);'''),
]
ok = 0
for old, new in subs:
    if old in src:
        src = src.replace(old, new, 1)
        ok += 1
    else:
        print("WARN not found:", old[:70].replace("\n", "\\n"))
io.open(path, "w", encoding="utf-8", newline="\n").write(src)
print("applied %d/%d" % (ok, len(subs)))
