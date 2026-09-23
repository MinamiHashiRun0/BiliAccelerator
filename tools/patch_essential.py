# -*- coding: utf-8 -*-
"""实质修复：
1. BARewriteDashEntry 视频条目包成本地并发代理（上一版遗漏的链路断点）
2. 关键路径无条件日志（前 5 条必打，不再依赖 verbose 开关）
3. /seg 请求到达无条件记录（播放器是否真用了改写 URL 的硬证据）"""
import io

path = "src/Tweak.m"
src = io.open(path, encoding="utf-8").read()

# ---- A. 加无条件日志宏（放在 BALog 定义后）----
anchor = '#define BALog(...) do { if (BAVerbose()) NSLog(@"[BiliAcc] " __VA_ARGS__); } while (0)'
assert anchor in src
ess = anchor + '''

// 无条件日志：关键链路前 8 条必打（验证链路不需要用户开 verbose）
static volatile int BAEssentialCount = 0;
#define BAEssentialLog(...) do { \\
    int _c = __sync_add_and_fetch(&BAEssentialCount, 1); \\
    if (_c <= 8 || BAVerbose()) NSLog(@"[BiliAcc] " __VA_ARGS__); \\
} while (0)'''
src = src.replace(anchor, ess, 1)

# ---- B. BARewriteDashEntry：加代理包装 + 无条件日志 ----
start = src.find("// 对单个 Dash 条目（DashItem/DashVideo/ResponseUrl）改写 URL 属性")
end = src.find("// 遍历 streamList（新接口 VodInfo）")
assert start != -1 and end != -1 and start < end, (start, end)

new_entry = u'''// 对单个 Dash 条目（DashItem/DashVideo/ResponseUrl）改写 URL 属性。
// 调用方保证 entry 属于视频流；音频条目永远不会走到这里。
// 改写两步：主机改写（PCDN→镜像）→ 包成本地并发代理 URL。
static void BARewriteDashEntry(id entry) {
    if (!entry || ![entry respondsToSelector:@selector(valueForKey:)]) return;
    for (NSString *k in @[ @"baseUrl", @"base_url", @"url" ]) {
        @try {
            id val = [entry valueForKey:k];
            if (![val isKindOfClass:[NSString class]]) continue;
            NSString *reason = nil;
            NSString *next = BARewriteUrlDetail(val, &reason);
            BOOL hostChanged = ![next isEqualToString:val];

            // 视频流 → 本地并发代理（并发数>1 才启用；已是代理 URL 则跳过）
            NSString *final = next;
            if (BAConcurrency() > 1 && ![next hasPrefix:@"http://127.0.0.1"]) {
                final = [NSString stringWithFormat:@"http://127.0.0.1:%ld/seg?u=%@",
                    (long)BAProxyPort(),
                    [next stringByAddingPercentEncodingWithAllowedCharacters:
                               [[NSCharacterSet alphanumericCharacterSet] invertedSet]]];
            }
            if (![final isEqualToString:val]) {
                [entry setValue:final forKey:k];
                BAEssentialLog(@"model-rewrite %@ [%@] -> %@",
                    k, reason ?: (hostChanged ? @"host" : @"proxy"),
                    [final substringToIndex:MIN((NSUInteger)100, final.length)]);
            }
        } @catch (NSException *e) { (void)e; }
    }
    for (NSString *bk in @[ @"backupUrl", @"backup_url" ]) {
        @try {
            id arr = [entry valueForKey:bk];
            if (![arr isKindOfClass:[NSArray class]]) continue;
            NSMutableArray *out = [NSMutableArray array];
            BOOL any = NO;
            for (id b in arr) {
                if ([b isKindOfClass:[NSString class]]) {
                    NSString *nb = BARewriteUrlDetail(b, NULL);
                    // backup 也包代理（主 URL 502 时播放器 fallback 仍走并发）
                    if (BAConcurrency() > 1 && ![nb hasPrefix:@"http://127.0.0.1"]) {
                        nb = [NSString stringWithFormat:@"http://127.0.0.1:%ld/seg?u=%@",
                            (long)BAProxyPort(),
                            [nb stringByAddingPercentEncodingWithAllowedCharacters:
                                       [[NSCharacterSet alphanumericCharacterSet] invertedSet]]];
                    }
                    [out addObject:nb];
                    if (![nb isEqualToString:b]) any = YES;
                } else {
                    [out addObject:b];
                }
            }
            if (any) [entry setValue:out forKey:bk];
        } @catch (NSException *e) { (void)e; }
    }
}

'''
src = src[:start] + new_entry + src[end:]

# ---- C. /seg 到达无条件日志 ----
old_seg = u'''        NSData *body = nil;
        if ([path hasPrefix:@"/seg"]) {
            body = [BABackend handleVideoSegment:inner reqFrom:reqFrom reqTo:reqTo
                                        rangeReq:rangeReq error:NULL];'''
assert old_seg in src
new_seg = u'''        NSData *body = nil;
        if ([path hasPrefix:@"/seg"]) {
            BAEssentialLog(@"seg req: Range=%@ (from=%lld to=%lld)",
                rangeHeader ?: @"(none)", reqFrom, reqTo);
            body = [BABackend handleVideoSegment:inner reqFrom:reqFrom reqTo:reqTo
                                        rangeReq:rangeReq error:NULL];'''
src = src.replace(old_seg, new_seg, 1)

io.open(path, "w", encoding="utf-8", newline="\n").write(src)
print("OK: proxy wrapping + essential logs")
