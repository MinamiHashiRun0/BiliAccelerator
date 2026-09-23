// BiliAccelerator.dylib — 免越狱注入 Bilibili iOS 官方客户端的加速 dylib
// 主机判定/改写规则移植自 realzza/bilibili-accelerator v0.4.1 (MIT)
//   - 拦截 playurl / PlayViewUnite / PlayView 响应，改写慢速 CDN 主机
//   - 视频流(dash.video)走本地并发代理做多连接 Range 下载
//   - 音频流(dash.audio)完全原样不动
// License: MIT

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

#pragma mark - 常量

static NSString * const kDomain = @"tv.danmaku.bilibili";

// 与参考项目 CandidatePool 一致（海外优先）
static NSArray<NSString *> *BACandidatePool(void) {
    static NSArray *pool;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pool = @[
            @"upos-sz-mirrorcosov.bilivideo.com",
            @"upos-sz-mirroraliov.bilivideo.com",
            @"upos-sz-mirrorhwov.bilivideo.com",
            @"upos-sz-mirrorali.bilivideo.com",
            @"upos-tf-all-hw.bilivideo.com",
            @"upos-sz-mirrorhw.bilivideo.com",
            @"upos-sz-mirrorcos.bilivideo.com",
            @"upos-tf-all-tx.bilivideo.com",
        ];
    });
    return pool;
}

static NSArray<NSString *> *BAKnownP2PSuffixes(void) {
    static NSArray *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = @[ @".szbdyd.com", @".mountaintoys.cn", @".nexusedgeio.com", @".ahdohpiechei.com" ];
    });
    return s;
}

static NSArray<NSString *> *BAKnownP2PHosts(void) {
    static NSArray *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = @[ @"upos-sz-mirror14b.bilivideo.com" ];
    });
    return s;
}

#pragma mark - 配置

static BOOL BAQueryBool(NSString *key, BOOL dflt) {
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return [v isKindOfClass:[NSNumber class]] ? [(NSNumber *)v boolValue] : dflt;
}

static NSString *BAQueryString(NSString *key, NSString *dflt) {
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return [v isKindOfClass:[NSString class]] ? v : dflt;
}

static NSInteger BAQueryInt(NSString *key, NSInteger dflt, NSInteger min, NSInteger max) {
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    NSInteger n = [v isKindOfClass:[NSNumber class]] ? [(NSNumber *)v integerValue] : dflt;
    return MAX(min, MIN(max, n));
}

static BOOL BAEnabled(void) {
    return BAQueryBool(@"BiliAcc_enabled", YES);
}

static NSString *BAMode(void) {          // bad-only | force | off
    return BAQueryString(@"BiliAcc_mode", @"bad-only");
}

static NSString *BATargetHost(void) {
    NSString *v = BAQueryString(@"BiliAcc_targetHost", nil);
    return v.length ? v : BACandidatePool()[0];
}

static NSInteger BAConcurrency(void) {   // 视频流并发连接数
    return BAQueryInt(@"BiliAcc_concurrency", 6, 1, 16);
}

static NSInteger BAChunkMB(void) {       // 并发分段大小(MB)
    return BAQueryInt(@"BiliAcc_chunkMB", 4, 1, 64);
}

static NSInteger BAProxyPort(void) {     // 本地代理端口
    return BAQueryInt(@"BiliAcc_proxyPort", 54321, 1024, 65535);
}

// WebSocket/HTTP 代理器（如代理软件）会把 127.0.0.1 流量直连，不会重复加速
#pragma mark - 工具函数

static NSString *BACleanHost(NSString *host) {
    if (!host) return @"";
    NSString *s = [host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"http://"])  s = [s substringFromIndex:7];
    if ([s hasPrefix:@"https://"]) s = [s substringFromIndex:8];
    NSRange slash = [s rangeOfString:@"/"];
    if (slash.location != NSNotFound) s = [s substringToIndex:slash.location];
    return s;
}

#pragma mark - 主机分类（对应参考项目 classify()）

typedef struct {
    BOOL isPcdn;
    BOOL isMcdn;
    BOOL isAkamai;
    BOOL isSlow;
    BOOL isScheduler;
    NSString *schedulerSource;
    NSString *kind;
} BAVerdict;

static BOOL BAIpLike(NSString *host) {
    struct in_addr a;
    return inet_pton(AF_INET, host.UTF8String, &a) == 1;
}

static BOOL BAXyMcdn(NSString *host) {
    return [host hasSuffix:@".mcdn.bilivideo.cn"] ||
           [host hasSuffix:@".mcdn.bilivideo.com"] ||
           [host hasSuffix:@".mcdn.bilivideo.net"];
}

static BOOL BAKnownP2pHost(NSString *host) {
    if ([BAKnownP2PHosts() containsObject:host]) return YES;
    for (NSString *suffix in BAKnownP2PSuffixes()) {
        if (host.length > suffix.length &&
            [host compare:suffix options:0 range:NSMakeRange(host.length - suffix.length, suffix.length)] == 0) {
            return YES;
        }
    }
    if ([host hasPrefix:@"upos-"]) {
        NSRange dot = [host rangeOfString:@"."];
        if (dot.location != NSNotFound) {
            NSString *first = [host substringToIndex:dot.location];
            if ([first containsString:@"302"]) return YES;
        }
    }
    return NO;
}

static BOOL BABiliCdnHost(NSString *host) {
    return [host hasSuffix:@".bilivideo.com"] ||
           [host hasSuffix:@".bilivideo.cn"]  ||
           [host hasSuffix:@".bilivideo.net"] ||
           [host hasSuffix:@".akamaized.net"];
}

static BAVerdict BAClassify(NSURL *url) {
    BAVerdict v = {0};
    if (!url || !url.host) return v;
    NSString *host = url.host.lowercaseString;

    if ([host hasSuffix:@".szbdyd.com"]) {
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"xy_usource=([^&]+)"
                                 options:0 error:NULL];
        NSTextCheckingResult *m = [re firstMatchInString:url.absoluteString
                                                 options:0
                                                   range:NSMakeRange(0, url.absoluteString.length)];
        if (m && [m numberOfRanges] > 1) {
            v.schedulerSource = BACleanHost([url.absoluteString substringWithRange:[m rangeAtIndex:1]]);
            v.isScheduler = YES;
        } else {
            v.isScheduler = YES;
        }
    }

    BOOL ipLike    = BAIpLike(host);
    BOOL portPcdn  = url.port && url.port.integerValue != 80 && url.port.integerValue != 443;
    NSString *query = url.query.lowercaseString ?: @"";
    BOOL queryMcdn = [query containsString:@"os=mcdn"];

    v.isMcdn   = BAXyMcdn(host) || [host containsString:@"mcdn.bili"];
    v.isAkamai = [host hasSuffix:@".akamaized.net"];
    v.isPcdn   = ipLike || BAXyMcdn(host) || portPcdn || queryMcdn || BAKnownP2pHost(host);
    v.isSlow   = v.isPcdn;   // rewriteAkamai 默认 false；ov 镜像不算 slow
    return v;
}

#pragma mark - 媒体 URL 判定（对应 isMediaUrl）

static BOOL BAIsMediaURL(NSURL *url) {
    if (!url) return NO;
    NSString *path = url.path.lowercaseString;
    if ([path hasPrefix:@"/upgcxcode/"]) return YES;
    if ([path hasPrefix:@"/v1/resource/"]) return YES;
    NSString *last = url.lastPathComponent.lowercaseString ?: @"";
    for (NSString *ext in @[ @".m4s", @".mp4", @".flv", @".m3u8" ]) {
        if ([last hasSuffix:ext]) return YES;
    }
    return NO;
}

static BOOL BAIsLiveMedia(NSURL *url) {
    return [url.path containsString:@"/live-bvc/"];
}

#pragma mark - 改写（对应 rewriteUrlDetail）

static NSString *BAReplaceHost(NSURL *url, NSString *newHost) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!c) return url.absoluteString;
    c.scheme  = @"https";
    c.host    = BACleanHost(newHost);
    c.port    = nil;   // 非标端口是 PCDN 特征，换主机后必须去掉
    return c.URL.absoluteString;
}

// 单个 URL 的改写决策。reason: cdn-host / pcdn-host / mcdn-proxy / szbdyd-source / live-skip / ok
static NSString *BARewriteUrlDetail(NSString *rawUrl, NSString **reason) {
    NSString *noop = rawUrl;
    if (!BAEnabled() || [BAMode() isEqualToString:@"off"]) return noop;

    NSURL *url;
    if ([noop hasPrefix:@"//"]) {
        url = [NSURL URLWithString:[@"https:" stringByAppendingString:noop]];
    } else {
        url = [NSURL URLWithString:noop];
    }
    if (!url || !url.host || !BAIsMediaURL(url)) return noop;
    if (BAIsLiveMedia(url)) { if (reason) *reason = @"live-skip"; return noop; }

    BAVerdict v = BAClassify(url);

    // 调度器带真实源站参数，换回源站
    if (v.isScheduler && v.schedulerSource.length) {
        if (reason) *reason = @"szbdyd-source";
        return BAReplaceHost(url, v.schedulerSource);
    }

    // MCDN → 本地代理透传（音频在此前已被排除）
    if (v.isMcdn) {
        if (reason) *reason = @"mcdn-proxy";
        return [NSString stringWithFormat:@"http://127.0.0.1:%ld/play?u=%@",
                (long)BAProxyPort(),
                [url.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:
                           [[NSCharacterSet alphanumericCharacterSet] invertedSet]]];
    }

    BOOL force = [BAMode() isEqualToString:@"force"];
    if (v.isSlow || (force && BABiliCdnHost(url.host.lowercaseString))) {
        if (reason) *reason = v.isPcdn ? @"pcdn-host" : @"cdn-host";
        return BAReplaceHost(url, BATargetHost());
    }

    if (reason) *reason = @"ok";
    return noop;
}

#pragma mark - Payload 遍历（JSON 路径）

// 识别 dash 容器后只处理 video / durl，audio 一律不碰
static void BARewriteDashContainer(NSDictionary *container, BOOL *changed) {
    NSDictionary *dash = nil;
    if ([container isKindOfClass:[NSDictionary class]]) {
        dash = container[@"dash"];
    }
    if ([dash isKindOfClass:[NSDictionary class]]) {
        for (NSString *kind in @[ @"video", @"durl" ]) {
            NSArray *list = dash[kind];
            if (![list isKindOfClass:[NSArray class]]) continue;
            for (NSMutableDictionary *entry in list) {
                if (![entry isKindOfClass:[NSMutableDictionary class]]) continue;
                for (NSString *key in @[ @"baseUrl", @"base_url", @"url" ]) {
                    NSString *val = entry[key];
                    if (![val isKindOfClass:[NSString class]]) continue;
                    NSString *reason = nil;
                    NSString *next = BARewriteUrlDetail(val, &reason);
                    if (![next isEqualToString:val]) {
                        entry[key] = next;
                        *changed = YES;
                    }
                    // 视频流走本地并发代理；音频(dash.audio)永远不改
                    if ([kind isEqualToString:@"video"] && BAConcurrency() > 1) {
                        entry[key] = [NSString stringWithFormat:@"http://127.0.0.1:%ld/seg?u=%@",
                            (long)BAProxyPort(),
                            [next stringByAddingPercentEncodingWithAllowedCharacters:
                                       [[NSCharacterSet alphanumericCharacterSet] invertedSet]]];
                        *changed = YES;
                    }
                }
                for (NSString *bkey in @[ @"backupUrl", @"backup_url" ]) {
                    NSArray *arr = entry[bkey];
                    if (![arr isKindOfClass:[NSArray class]]) continue;
                    NSMutableArray *out = [NSMutableArray array];
                    for (NSString *b in arr) {
                        if (![b isKindOfClass:[NSString class]]) { [out addObject:b]; continue; }
                        [out addObject:BARewriteUrlDetail(b, NULL)];
                    }
                    entry[bkey] = out;
                }
            }
        }
    }
}

static void BARewriteValueDeep(id value, BOOL *changed, NSInteger depth) {
    if (depth > 20 || !value) return;
    if ([value isKindOfClass:[NSMutableDictionary class]] || [value isKindOfClass:[NSDictionary class]]) {
        BARewriteDashContainer(value, changed);
        for (NSString *key in ((NSDictionary *)value)) {
            BARewriteValueDeep(value[key], changed, depth + 1);
        }
    } else if ([value isKindOfClass:[NSArray class]]) {
        for (id item in value) BARewriteValueDeep(item, changed, depth + 1);
    }
}

static NSString *BARewriteJsonPayload(NSString *json, BOOL *changed) {
    *changed = NO;
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return json;
    id root = [NSJSONSerialization JSONObjectWithData:data
                                              options:NSJSONReadingMutableContainers
                                                error:NULL];
    if (!root) return json;
    BARewriteValueDeep(root, changed, 0);
    if (!*changed) return json;
    NSData *out = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
    return out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] : json;
}

#pragma mark - Protobuf 改写（gRPC 响应字节流）

// gRPC 响应是 [1 byte compress flag][4 byte big-endian length][protobuf bytes]
// protobuf 里 URL 均为 length-delimited string 字段。我们扫描 "http"，
// 仅当长度前缀(varint)与 URL 字节长匹配时才替换，重建 varint 前缀。
static NSUInteger BAReadVarint(const uint8_t *b, NSUInteger len, NSUInteger *outLen) {
    NSUInteger v = 0, shift = 0, i = 0;
    while (i < len && shift < 63) {
        uint8_t c = b[i++];
        v |= (NSUInteger)(c & 0x7f) << shift;
        if (!(c & 0x80)) break;
        shift += 7;
    }
    *outLen = v;
    return i;
}

static void BAWriteVarint(NSMutableData *d, NSUInteger v) {
    while (v >= 128) {
        uint8_t c = (uint8_t)(v & 0x7f) | 0x80;
        [d appendBytes:&c length:1];
        v >>= 7;
    }
    uint8_t c = (uint8_t)v;
    [d appendBytes:&c length:1];
}

static NSData *BARewriteProtobufBody(NSData *data, BOOL *changed) {
    *changed = NO;
    if (data.length < 8 || !BAEnabled()) return data;

    NSMutableData *out = [NSMutableData dataWithCapacity:data.length + 1024];
    const uint8_t *b = data.bytes;
    NSUInteger len = data.length, i = 0;

    NSData *needle = [@"http" dataUsingEncoding:NSUTF8StringEncoding];
    while (i < len) {
        NSRange r = [data rangeOfData:needle options:0 range:NSMakeRange(i, len - i)];
        if (r.location == NSNotFound) {
            [out appendBytes:b + i length:len - i];
            break;
        }
        NSUInteger hStart = r.location;
        // 向前扫 varint 长度前缀：尝试 "http" 在字段值内出现的所有可能 varint 起点不好判定，
        // 更稳妥的做法是：向前回退最多 2 字节尝试 varint 解码，验证字段长度覆盖到 ASCII 结尾。
        BOOL matched = NO;
        for (uint8_t back = 1; back <= 2 && !matched; back++) {
            if (hStart < back) continue;
            NSUInteger lpos = hStart - back;
            NSUInteger fieldLen = 0;
            NSUInteger hdr = BAReadVarint(b + lpos, hStart - lpos + 1, &fieldLen);
            if (hdr != back) continue;             // varint 必须恰好终止于 "http" 前
            if (fieldLen < 20 || fieldLen > 4096) continue;
            NSUInteger fieldEnd = lpos + hdr + fieldLen;
            if (fieldEnd > len) continue;
            if (b[lpos + hdr] != 'h') continue;    // 长度前缀必须紧跟 "http"，防止误判命中切片中部
            NSData *s = [data subdataWithRange:NSMakeRange(lpos + hdr, fieldLen)];
            NSString *str = [[NSString alloc] initWithData:s encoding:NSUTF8StringEncoding];
            if (!str || ![str hasPrefix:@"http"]) continue;
            NSURL *u = [NSURL URLWithString:str];
            if (!u || !BAIsMediaURL(u)) continue;
            NSString *reason = nil;
            NSString *next = BARewriteUrlDetail(str, &reason);
            if ([next isEqualToString:str]) continue;

            // 保留 lpos 之前字节，重建 varint 长度前缀 + 新 URL 内容
            [out appendBytes:b + i length:lpos - i];
            BAWriteVarint(out, next.length);
            [out appendData:[next dataUsingEncoding:NSUTF8StringEncoding]];
            *changed = YES;
            i = fieldEnd;
            matched = YES;
        }
        if (!matched) {
            // 非 URL 字段，原样拷贝到下一个 http 之后（含"http"本身）
            [out appendBytes:b + i length:hStart + 4 - i];
            i = hStart + 4;
        }
    }
    return out;
}

#pragma mark - 本地并发下载代理

// 视频流并发下载器：对 /seg?u=<url> 请求，向真实 CDN 发起 N 路 Range 并发，
// 按字节序拼接后以 HTTP 200 响应给播放器。音频流永远不会路由到这里。
@interface BAProxy : NSObject
- (NSURL *)innerURLFor:(NSString *)query;
- (NSData *)handleVideoSegment:(NSURL *)url error:(NSError **)err;
- (NSData *)passthrough:(NSURL *)url error:(NSError **)err;
@end

static BAProxy *BABackend = nil;

@implementation BAProxy {
    NSMutableArray<NSURLSession *> *_sessions;   // 每路独立 session → 物理独立 TCP 连接
}

- (instancetype)init {
    if (self = [super init]) {
        _sessions = [NSMutableArray array];
        for (NSInteger i = 0; i < BAConcurrency(); i++) {
            NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
            cfg.HTTPShouldUsePipelining = YES;
            cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
            NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg delegate:nil delegateQueue:nil];
            [_sessions addObject:s];
        }
    }
    return self;
}

// 从 ?u=<enc> 取内层 URL
- (NSURL *)innerURLFor:(NSString *)query {
    if (!query) return nil;
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        if ([pair hasPrefix:@"u="]) {
            NSString *enc = [pair substringFromIndex:2];
            NSString *dec = [enc stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            return dec ? [NSURL URLWithString:dec] : nil;
        }
    }
    return nil;
}

// HEAD/Range-0 探测总大小；失败返回 -1
- (long long)probeTotalSize:(NSURL *)real {
    NSMutableURLRequest *probe = [NSMutableURLRequest requestWithURL:real];
    probe.HTTPMethod = @"HEAD";
    probe.timeoutInterval = 15;
    __block long long total = -1;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[_sessions[0] dataTaskWithRequest:probe
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            (void)d; (void)e;
            if ([r isKindOfClass:[NSHTTPURLResponse class]]) {
                NSDictionary *h = ((NSHTTPURLResponse *)r).allHeaderFields;
                NSString *cr = h[@"Content-Range"];
                NSString *cl = h[@"Content-Length"];
                if (cr.length) {
                    NSRange slash = [cr rangeOfString:@"/"];
                    if (slash.location != NSNotFound && slash.location + 1 < cr.length) {
                        total = strtoll([cr substringFromIndex:slash.location + 1].UTF8String, NULL, 10);
                    }
                } else if (cl.length) {
                    total = strtoll(cl.UTF8String, NULL, 10);
                }
            }
            dispatch_semaphore_signal(sem);
        }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15LL * NSEC_PER_SEC));
    return total;
}

// 单次 Range 拉取（带一次重试），成功返回精确 expect 字节，否则 nil
- (NSData *)fetchRange:(NSURL *)real from:(long long)from to:(long long)to lane:(NSInteger)lane {
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:real];
        [rq setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", from, to] forHTTPHeaderField:@"Range"];
        [rq setTimeoutInterval:60];
        __block NSData *d = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[_sessions[lane % _sessions.count] dataTaskWithRequest:rq
            completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
                (void)r; (void)e;
                d = data;
                dispatch_semaphore_signal(sem);
            }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 300LL * NSEC_PER_SEC));
        long long expect = to - from + 1;
        if (d && (long long)d.length == expect) return d;
    }
    return nil;
}

// 并发拉取整个视频文件
- (NSData *)handleVideoSegment:(NSURL *)url error:(NSError **)err {
    if (err) *err = nil;
    if (!url || !url.host) return nil;
    NSString *target = BARewriteUrlDetail(url.absoluteString, NULL);
    NSURL *real = [NSURL URLWithString:target];
    if (!real) return nil;

    long long total = [self probeTotalSize:real];
    if (total <= 0) {
        // CDN 不支持 Range/HEAD → 单连接全量下载兜底
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

    long long chunk = (long long)BAChunkMB() * 1024 * 1024;
    NSInteger nseg = (NSInteger)((total + chunk - 1) / chunk);
    // ARC 下不能用 calloc 裸指针放 ObjC 对象，改用 NSMutableArray（占位 NSNull）
    NSMutableArray<NSData *> *buffers = [NSMutableArray arrayWithCapacity:(NSUInteger)nseg];
    for (NSInteger i = 0; i < nseg; i++) [buffers addObject:[NSNull null]];
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t laneQ = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    __block BOOL failed = NO;

    for (NSInteger idx = 0; idx < nseg; idx++) {
        long long from = (long long)idx * chunk;
        long long to = MIN(from + chunk, total) - 1;
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
        return nil;   // 任一分段失败 → 502，播放器自动 failover 到 backupUrl
    }
    NSMutableData *all = [NSMutableData dataWithCapacity:(NSUInteger)total];
    for (NSInteger i = 0; i < nseg; i++) {
        [all appendData:buffers[i]];
    }
    return all;
}

// MCDN 透传（单连接）
- (NSData *)passthrough:(NSURL *)url error:(NSError **)err {
    if (err) *err = nil;
    if (!url) return nil;
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:url];
    rq.timeoutInterval = 30;
    __block NSData *body = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[_sessions[0] dataTaskWithRequest:rq
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            body = d; if (err) *err = e;
            dispatch_semaphore_signal(sem);
        }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 300LL * NSEC_PER_SEC));
    return body;
}

@end

#pragma mark - 本地 HTTP 服务器

static int BAListenFD = -1;

static void BAServeConnection(int conn) {
    @try {
        char buf[8192];
        size_t got = 0;
        while (got < sizeof(buf) - 4) {
            ssize_t n = recv(conn, buf + got, 1, 0);
            if (n <= 0) { close(conn); return; }
            got += (size_t)n;
            if (got >= 4 && memcmp(buf + got - 4, "\r\n\r\n", 4) == 0) break;
        }
        buf[got] = 0;
        NSString *req = [[NSString alloc] initWithBytes:buf length:got encoding:NSUTF8StringEncoding];
        if (!req) { close(conn); return; }
        NSArray *lines = [req componentsSeparatedByString:@"\r\n"];
        if (!lines.count) { close(conn); return; }
        NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
        if (parts.count < 2) { close(conn); return; }

        NSString *path = parts[1];
        NSURL *abs = [NSURL URLWithString:[@"http://127.0.0.1" stringByAppendingString:path]];
        NSURL *inner = [BABackend innerURLFor:abs.query ?: @""];

        NSData *body = nil;
        if ([path hasPrefix:@"/seg"]) {
            body = [BABackend handleVideoSegment:inner error:NULL];
        } else if ([path hasPrefix:@"/play"]) {
            body = [BABackend passthrough:inner error:NULL];
        }

        if (!body) {
            const char *resp = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            send(conn, resp, strlen(resp), 0);
            close(conn);
            return;
        }
        NSString *hdr = [NSString stringWithFormat:
            @"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
             "Content-Length: %zu\r\nConnection: close\r\n\r\n", body.length];
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

static void BAStartLocalServer(NSInteger port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // 仅本机可达
    addr.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return; }
    if (listen(fd, 16) != 0) { close(fd); return; }
    BAListenFD = fd;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (BAListenFD >= 0) {
            struct sockaddr_in peer;
            socklen_t plen = sizeof(peer);
            int conn = accept(BAListenFD, (struct sockaddr *)&peer, &plen);
            if (conn < 0) continue;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                BAServeConnection(conn);
            });
        }
    });
}

#pragma mark - gRPC 响应改写

// gRPC 帧格式：[1B compress flag][4B big-endian length][protobuf bytes]
static NSData *BARewriteGrpcResponse(NSData *raw, BOOL *changed) {
    *changed = NO;
    if (raw.length < 6) return raw;
    const uint8_t *b = raw.bytes;
    if (b[0] != 0) return raw;   // 压缩响应不处理
    uint32_t plen = ((uint32_t)b[1] << 24) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 8) | (uint32_t)b[4];
    if (plen != (uint32_t)(raw.length - 5)) return raw;   // 不完整帧不处理（官方客户端一次性收完）

    NSData *payload = [raw subdataWithRange:NSMakeRange(5, plen)];
    BOOL innerChanged = NO;
    NSData *newPayload = BARewriteProtobufBody(payload, &innerChanged);
    if (!innerChanged) return raw;

    NSMutableData *out = [NSMutableData dataWithCapacity:newPayload.length + 5];
    uint8_t header[5] = {0};
    uint32_t n = (uint32_t)newPayload.length;
    header[1] = (uint8_t)(n >> 24); header[2] = (uint8_t)(n >> 16);
    header[3] = (uint8_t)(n >> 8);  header[4] = (uint8_t)n;
    [out appendBytes:header length:5];
    [out appendData:newPayload];
    *changed = YES;
    return out;
}

static BOOL BAIsPlayviewURL(NSString *u) {
    if (!u) return NO;
    return [u containsString:@"PlayViewUnite"] ||
           [u containsString:@"PlayView"] ||
           [u containsString:@"playurl"] ||
           [u containsString:@"pgc/player"] ||
           [u containsString:@"x/player"];
}

#pragma mark - Hook：NSURLSession dataTaskWithRequest:completionHandler:

static NSURLSessionDataTask * (*BAOrigDataTask)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));

static NSURLSessionDataTask *BAHookDataTask(id self, SEL _cmd, NSURLRequest *req,
                                            void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    (void)_cmd;
    NSString *url = req.URL.absoluteString;
    BOOL isPlayview = BAIsPlayviewURL(url);
    if (!isPlayview || !BAEnabled()) {
        return BAOrigDataTask(self, @selector(dataTaskWithRequest:completionHandler:), req, handler);
    }
    // 包一层 completionHandler，改写 gRPC 响应字节
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *resp, NSError *error) {
            NSData *out = data;
            if (data && data.length > 6) {
                BOOL changed = NO;
                out = BARewriteGrpcResponse(data, &changed);
            }
            handler(out, resp, error);
        };
    return BAOrigDataTask(self, @selector(dataTaskWithRequest:completionHandler:), req, wrapped);
}

#pragma mark - 入口

__attribute__((constructor))
static void BiliAccInit(void) {
    @autoreleasepool {
        if (!BAEnabled()) return;
        BABackend = [BAProxy new];
        BAStartLocalServer(BAProxyPort());

        // swizzle NSURLSession dataTaskWithRequest:completionHandler:
        Method m = class_getInstanceMethod([NSURLSession class],
                                           @selector(dataTaskWithRequest:completionHandler:));
        if (m) {
            BAOrigDataTask = (NSURLSessionDataTask * (*)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)))
                method_getImplementation(m);
            method_setImplementation(m, (IMP)BAHookDataTask);
        }
        NSLog(@"[BiliAcc] loaded, proxy on 127.0.0.1:%ld, mode=%@, target=%@, lanes=%ld",
              (long)BAProxyPort(), BAMode(), BATargetHost(), (long)BAConcurrency());
    }
}

