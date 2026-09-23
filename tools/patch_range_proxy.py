# -*- coding: utf-8 -*-
"""重写本地代理：/seg 尊重播放器 Range 头，只对请求窗口做并发拉取。
替换 handleVideoSegment + BAServeConnection 中的 Range/206 处理。"""
import io

path = "src/Tweak.m"
src = io.open(path, encoding="utf-8").read()

# ---- 1. 替换 handleVideoSegment ----
start = src.find("// 并发拉取整个视频文件")
end = src.find("// MCDN 透传（单连接）")
assert start != -1 and end != -1 and start < end, (start, end)

new_seg = u'''// 解析播放器发来的 Range 头："bytes=123-456" / "bytes=123-" / "bytes=-456"
// 返回 (from, to, ok)；open-ended 用 -1 表示
static BOOL BAParseRange(NSString *rangeHeader, long long *from, long long *to) {
    *from = -1; *to = -1;
    if (!rangeHeader.length) return NO;
    NSString *s = [rangeHeader lowercaseString];
    if (![s hasPrefix:@"bytes="]) return NO;
    s = [s substringFromIndex:6];
    NSRange dash = [s rangeOfString:@"-"];
    if (dash.location == NSNotFound) return NO;
    NSString *a = [s substringToIndex:dash.location];
    NSString *b = [s substringFromIndex:dash.location + 1];
    if (a.length) *from = strtoll(a.UTF8String, NULL, 10);
    if (b.length) *to = strtoll(b.UTF8String, NULL, 10);
    return a.length > 0 || b.length > 0;
}

// 并发拉取播放器请求的字节窗口 [reqFrom, reqTo]
// 核心逻辑：把窗口均分成 N 段（N = 并发路数），每段独立 Range 请求，按序拼接。
// 只拉播放器要的字节 —— 不再全文件下载。
- (NSData *)handleVideoSegment:(NSURL *)url
                       reqFrom:(long long)reqFrom
                         reqTo:(long long)reqTo
                      rangeReq:(BOOL)rangeReq
                         error:(NSError **)err {
    if (err) *err = nil;
    if (!url || !url.host) return nil;
    NSString *target = BARewriteUrlDetail(url.absoluteString, NULL);
    NSURL *real = [NSURL URLWithString:target];
    if (!real) return nil;

    // 无 Range 头（整文件请求）或 open-ended：探测总大小补全窗口
    if (reqTo < 0) {
        long long total = [self probeTotalSize:real];
        if (total <= 0) {
            // 探测失败 → 单连接直拉，不带 Range
            BALog(@"seg: probe failed, single-connection fallback");
            NSMutableURLRequest *one = [NSMutableURLRequest requestWithURL:real];
            one.timeoutInterval = 30;
            __block NSData *body = nil;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [[_sessions[0] dataTaskWithRequest:one
                completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                    body = d; if (err) *err = e;
                    dispatch_semaphore_signal(sem);
                }] resume];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 300LL * NSEC_PER_SEC));
            return body;
        }
        if (reqFrom < 0) reqFrom = 0;                  // bytes=-456 → suffix range
        reqTo = total - 1;
    }

    long long windowSize = reqTo - reqFrom + 1;
    NSInteger lanes = (NSInteger)BAConcurrency();
    // 窗口小于 1MB 时并发无意义（握手开销 > 收益），单连接直接拉
    if (windowSize < 1024 * 1024 || lanes <= 1) {
        BALog(@"seg: window %lld-%lld (%lldKB) single connection",
              reqFrom, reqTo, windowSize / 1024);
        NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:real];
        [rq setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", reqFrom, reqTo]
            forHTTPHeaderField:@"Range"];
        [rq setTimeoutInterval:60];
        __block NSData *body = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[_sessions[0] dataTaskWithRequest:rq
            completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                body = d; if (err) *err = e;
                dispatch_semaphore_signal(sem);
            }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 300LL * NSEC_PER_SEC));
        if (body && (long long)body.length == windowSize) return body;
        return body;   // 长度不符也返回（有些服务器忽略 Range 返回 200 全量）
    }

    // 把窗口均分成 lanes 段（尾段余量并入最后一段）
    long long slice = (windowSize + lanes - 1) / lanes;
    NSInteger nseg = (NSInteger)((windowSize + slice - 1) / slice);
    BALog(@"seg: window %lld-%lld (%lldMB) → %ld slices, %lldKB each",
          reqFrom, reqTo, windowSize / 1024 / 1024, (long)nseg, slice / 1024);

    NSMutableArray<NSData *> *buffers = [NSMutableArray arrayWithCapacity:(NSUInteger)nseg];
    for (NSInteger i = 0; i < nseg; i++) [buffers addObject:[NSNull null]];
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t laneQ = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    __block BOOL failed = NO;

    for (NSInteger idx = 0; idx < nseg; idx++) {
        long long from = reqFrom + (long long)idx * slice;
        long long to = MIN(from + slice, reqTo + 1) - 1;
        dispatch_group_enter(group);
        dispatch_async(laneQ, ^{
            NSData *part = [self fetchRange:real from:from to:to lane:idx];
            if (part) {
                @synchronized (buffers) { buffers[idx] = part; }
            } else {
                failed = YES;
            }
            dispatch_group_leave(group);
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if (failed) {
        BALog(@"seg: slice FAILED → 502 (player will failover)");
        return nil;
    }
    NSMutableData *all = [NSMutableData dataWithCapacity:(NSUInteger)windowSize];
    for (NSInteger i = 0; i < nseg; i++) {
        [all appendData:buffers[i]];
    }
    BALog(@"seg: window done %lld bytes", (long long)all.length);
    return all;
}

'''

src = src[:start] + new_seg + src[end:]

# ---- 2. 重写 BAServeConnection：解析 Range、回 206/Content-Range ----
start2 = src.find("static void BAServeConnection(int conn) {")
end2 = src.find("static void BAStartLocalServer(NSInteger port)")
assert start2 != -1 and end2 != -1 and start2 < end2, (start2, end2)

new_serve = u'''static void BAServeConnection(int conn) {
    @try {
        char buf[16384];
        size_t got = 0;
        while (got < sizeof(buf) - 4) {
            ssize_t n = recv(conn, buf + got, 1, 0);
            if (n <= 0) { close(conn); return; }
            got += (size_t)n;
            if (got >= 4 && memcmp(buf + got - 4, "\\r\\n\\r\\n", 4) == 0) break;
        }
        buf[got] = 0;
        NSString *req = [[NSString alloc] initWithBytes:buf length:got encoding:NSUTF8StringEncoding];
        if (!req) { close(conn); return; }
        NSArray *lines = [req componentsSeparatedByString:@"\\r\\n"];
        if (!lines.count) { close(conn); return; }
        NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
        if (parts.count < 2) { close(conn); return; }

        NSString *path = parts[1];
        NSURL *abs = [NSURL URLWithString:[@"http://127.0.0.1" stringByAppendingString:path]];
        NSURL *inner = [BABackend innerURLFor:abs.query ?: @""];

        // 解析播放器的 Range 头
        NSString *rangeHeader = nil;
        for (NSString *line in lines) {
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSString *key = [[line substringToIndex:colon.location]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([key caseInsensitiveCompare:@"Range"] == 0) {
                rangeHeader = [[line substringFromIndex:colon.location + 1]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                break;
            }
        }
        long long reqFrom = -1, reqTo = -1;
        BOOL rangeReq = BAParseRange(rangeHeader, &reqFrom, &reqTo);

        NSData *body = nil;
        if ([path hasPrefix:@"/seg"]) {
            body = [BABackend handleVideoSegment:inner reqFrom:reqFrom reqTo:reqTo
                                        rangeReq:rangeReq error:NULL];
        } else if ([path hasPrefix:@"/play"]) {
            body = [BABackend passthrough:inner error:NULL];
        }

        if (!body) {
            const char *resp = "HTTP/1.1 502 Bad Gateway\\r\\nContent-Length: 0\\r\\nConnection: close\\r\\n\\r\\n";
            send(conn, resp, strlen(resp), 0);
            close(conn);
            return;
        }

        // 有 Range 请求 → 回 206 + Content-Range；无 → 200
        NSString *hdr;
        if (rangeReq && reqFrom >= 0) {
            hdr = [NSString stringWithFormat:
                @"HTTP/1.1 206 Partial Content\\r\\n"
                 "Content-Type: application/octet-stream\\r\\n"
                 "Content-Range: bytes %lld-%lld/*\\r\\n"
                 "Content-Length: %zu\\r\\n"
                 "Accept-Ranges: bytes\\r\\nConnection: close\\r\\n\\r\\n",
                reqFrom, reqFrom + (long long)body.length - 1, body.length];
        } else {
            hdr = [NSString stringWithFormat:
                @"HTTP/1.1 200 OK\\r\\n"
                 "Content-Type: application/octet-stream\\r\\n"
                 "Content-Length: %zu\\r\\n"
                 "Accept-Ranges: bytes\\r\\nConnection: close\\r\\n\\r\\n", body.length];
        }
        NSData *hdrData = [hdr dataUsingEncoding:NSUTF8StringEncoding];
        send(conn, hdrData.bytes, hdrData.length, 0);
        NSUInteger offset = 0;
        while (offset < body.length) {
            NSUInteger n = MIN((NSUInteger)262144, body.length - offset);
            ssize_t sent = send(conn, (const char *)body.bytes + offset, n, 0);
            if (sent <= 0) break;
            offset += (NSUInteger)sent;
        }
    } @catch (NSException *e) { (void)e; }
    close(conn);
}

'''

src = src[:start2] + new_serve + src[end2:]
io.open(path, "w", encoding="utf-8", newline="\n").write(src)
print("OK: proxy now Range-aware")
