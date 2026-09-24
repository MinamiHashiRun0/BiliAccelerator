// BiliAccelerator.dylib — 免越狱注入 Bilibili iOS 官方客户端的加速 dylib
// 主机判定/改写规则移植自 realzza/bilibili-accelerator v0.4.1 (MIT)
//   - 拦截 playurl / PlayViewUnite / PlayView 响应，改写慢速 CDN 主机
//   - 视频流(dash.video)走本地并发代理做多连接 Range 下载
//   - 音频流(dash.audio)完全原样不动
// License: MIT

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <fcntl.h>
#import <sys/time.h>
#import <unistd.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#define BA_HAS_UI 1
#else
#define BA_HAS_UI 0
#endif

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

// 优先级：环境变量 > CFPreferences（App 内偏好）> 默认值。
// 环境变量仅用于 Mac 直跑/调试时免重签快速调参：BiliAcc_mode=force ...
static NSString *BAEnvOverride(NSString *key) {
    const char *e = getenv(key.UTF8String);
    return e ? [NSString stringWithUTF8String:e] : nil;
}

static BOOL BAQueryBool(NSString *key, BOOL dflt) {
    NSString *env = BAEnvOverride(key);
    if (env) return [env boolValue];
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return [v isKindOfClass:[NSNumber class]] ? [(NSNumber *)v boolValue] : dflt;
}

static NSString *BAQueryString(NSString *key, NSString *dflt) {
    NSString *env = BAEnvOverride(key);
    if (env) return env;
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    return [v isKindOfClass:[NSString class]] ? v : dflt;
}

static NSInteger BAQueryInt(NSString *key, NSInteger dflt, NSInteger min, NSInteger max) {
    NSString *env = BAEnvOverride(key);
    id v = env ?: CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
    NSInteger n = [v isKindOfClass:[NSNumber class]] ? [(NSNumber *)v integerValue]
                : ([v isKindOfClass:[NSString class]] ? [v integerValue] : dflt);
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

// 详细日志开关：默认关；YES 时逐条打印每次改写/代理请求
static BOOL BAVerbose(void) {
    return BAQueryBool(@"BiliAcc_verbose", NO);
}

// 新系统的 NSLog→os_log 链路对 %{public}s/@ 支持不稳定（输出 "<decode: missing data>"
// 或字面 "{public}s"）。改用普通格式符；同时并行写入文件日志（App tmp/BiliAcc.log），
// 真机上可直接用 devicectl 拉取，无需 root/Console。
static void BAApendLog(NSString *msg) {
    static NSString *path;
    static int fd = -2;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"BiliAcc.log"];
        // 超 4MB 截断，防无限增长
        NSDictionary *attr = [NSFileManager.defaultManager
            attributesOfItemAtPath:path error:nil];
        if (attr && [attr fileSize] > 5 * 1024 * 1024)
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    });
    if (fd == -2)
        fd = open(path.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd > 0) {
        // 时间戳前缀（文件日志需要定位耗时/时序）
        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct tm tmv;
        localtime_r(&tv.tv_sec, &tmv);
        char ts[40];
        snprintf(ts, sizeof(ts), "%02d:%02d:%02d.%03ld ",
                 tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (long)(tv.tv_usec / 1000));
        ssize_t i0 = write(fd, ts, strlen(ts));
        (void)i0;
        const char *s = [msg UTF8String];
        if (s) { ssize_t ignore = write(fd, s, strlen(s)); (void)ignore; }
        ssize_t ignore2 = write(fd, "\n", 1); (void)ignore2;
    }
}

// Console.app 继续受 verbose/前8条限制（避免系统日志噪音）；文件日志无条件全量，
// 真机调试直接 devicectl 拉取 tmp/BiliAcc.log。
#define BALog(...) do { if (BAVerbose()) { \
    NSString *_m = [NSString stringWithFormat:@"[BiliAcc] " __VA_ARGS__]; \
    NSLog(@"%@", _m); } } while (0)

#define BAEssentialLog(...) do { \
    NSString *_m = [NSString stringWithFormat:@"[BiliAcc] " __VA_ARGS__]; \
    BAApendLog(_m); \
    static volatile int _c_once = 0; \
    if (__sync_add_and_fetch(&_c_once, 1) <= 8 || BAVerbose()) NSLog(@"%@", _m); \
} while (0)

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

// RFC3986 unreserved：保留 . ~ - _（路径可读、断言可命中），其余照旧转义
static NSString *BAQueryParamEncode(NSString *s) {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *a = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
        [a addCharactersInString:@"-._~"];
        allowed = a;
    });
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

// 改写结果包装进本地并发代理。已指向 127.0.0.1 的输入原样返回（幂等）。
// 并发路数 >1 才包装；单路时直连改写结果即可。
static NSString *BAWrapProxy(NSString *next) {
    if (!next || [next hasPrefix:@"http://127.0.0.1"]) return next;
    if (BAConcurrency() <= 1) return next;
    return [NSString stringWithFormat:@"http://127.0.0.1:%ld/seg?u=%@",
        (long)BAProxyPort(), BAQueryParamEncode(next)];
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
                (long)BAProxyPort(), BAQueryParamEncode(url.absoluteString)];
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

// 前向声明（定义在运行时递归改写段）
static id BARewriteMediaValue(id val);

// JSON playurl 深改写（通用递归，键名含 audio/dolby/lossless 的子树剪枝）
static void BARewriteJsonDeep(NSMutableDictionary *obj, BOOL *changed, NSInteger depth) {
    if (depth > 10 || !obj) return;
    for (NSString *key in [obj copy]) {
        id val = obj[key];
        if ([val isKindOfClass:[NSMutableDictionary class]]) {
            if ([key.lowercaseString containsString:@"audio"] ||
                [key.lowercaseString containsString:@"dolby"] ||
                [key.lowercaseString containsString:@"lossless"]) {
                continue;   // 音频子树剪枝
            }
            BARewriteJsonDeep(val, changed, depth + 1);
        } else if ([val isKindOfClass:[NSMutableArray class]]) {
            BOOL audioKey = [key.lowercaseString containsString:@"audio"] ||
                            [key.lowercaseString containsString:@"dolby"] ||
                            [key.lowercaseString containsString:@"lossless"];
            if (audioKey) continue;
            for (id item in val) {
                if ([item isKindOfClass:[NSMutableDictionary class]]) {
                    BARewriteJsonDeep(item, changed, depth + 1);
                }
            }
        } else if ([val isKindOfClass:[NSString class]]) {
            NSString *next = BARewriteMediaValue(val);
            if (next) {
                obj[key] = next;
                *changed = YES;
                BALog(@"json-rewrite %@: %@", key,
                      [next substringToIndex:MIN((NSUInteger)100, next.length)]);
            }
        }
    }
}

static NSString *BARewriteJsonPayload(NSString *json, BOOL *changed) {
    *changed = NO;
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || !BAEnabled()) return json;
    id root = [NSJSONSerialization JSONObjectWithData:data
                                              options:NSJSONReadingMutableContainers
                                                error:NULL];
    if (![root isKindOfClass:[NSMutableDictionary class]]) return json;
    BARewriteJsonDeep(root, changed, 0);
    if (!*changed) return json;
    NSData *out = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
    return out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] : json;
}

// 旧版 dash 容器遍历（保留：明确 dash 结构时的确定性路径）
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
                        BALog(@"json-rewrite [%@] %@: %@", kind, reason,
                              [next substringToIndex:MIN((NSUInteger)120, next.length)]);
                        entry[key] = next;
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

#pragma mark - Protobuf 改写（gRPC 响应字节流，按官方 schema 寻址）

// 结构依据 bilibili-API-collect 反编译官方 App 的 com.bapis 定义（docs/*.proto）：
//   PlayViewUniteReply (bilibili.app.playerunite.v1)
//     1: playershared.VodInfo
//          5: repeated Stream stream_list
//               Stream { 1: StreamInfo; oneof { 2: DashVideo | 3: SegmentVideo } }
//               DashVideo { 1: base_url; 2: backup_url }   ← 视频流，改
//          6: repeated DashItem dash_audio                  ← 音频流，绝不碰
//          7: DolbyItem dolby / 9: LossLessItem             ← 杜比/Hi-Res 音频，不碰
//   PlayViewReply (bilibili.app.playurl.v1)
//     1: VideoInfo { 8: repeated ResponseUrl durl; 9: ResponseDash }
//          ResponseDash { 1: repeated DashItem video; 2: audio } ← 只碰 video
//
// 字段号是唯一的寻址方式，不再做 "http" 字符串盲扫——盲扫无法区分
// VideoInfo 里分离的 video/audio，两代 proto 字段号也不同。

// 返回消费的字节数；解析出的值写入 *outValue
static NSUInteger BAReadVarint(const uint8_t *b, NSUInteger len, uint64_t *outValue) {
    uint64_t v = 0;
    NSUInteger shift = 0, i = 0;
    while (i < len && shift < 63) {
        uint8_t c = b[i++];
        v |= (uint64_t)(c & 0x7f) << shift;
        if (!(c & 0x80)) break;
        shift += 7;
    }
    *outValue = v;
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

// protobuf wire type
#define BA_WT_VARINT 0
#define BA_WT_64BIT  1
#define BA_WT_LEN    2
#define BA_WT_32BIT  5

// ---- 通用 protobuf 重建器 ----
// 逐字段遍历 message 字节。对每个 wire-type-2 字段调用 classify 回调：
//   outAction: 0=原样拷贝  1=用 outReplacement 替换该字段值  2=内容是子消息，递归同一 classify
// 每层 schema 用独立 classify 函数表达，递归时由 schema 树上的位置决定用哪个。

typedef struct {
    uint8_t action;                 // 0 copy / 1 replace / 2 recurse
    NSMutableData *replacement;     // action=1 时：新的字段值（不含 tag/len）
} BAFieldAction;

typedef void (*BAFieldClassify)(uint32_t field, NSData *fieldValue,
                                BAFieldAction *action, void *ctx);

// 改写上下文：schema 层级游走
typedef struct {
    BOOL changed;
    NSInteger level;      // 当前 schema 层级（枚举 BA_S_*）
    NSInteger savedLevel; // 递归返回后恢复用
} BAWalkCtx;

// 递归序列化：把 [start,end) 的 message 按字段遍历，classify 决定每字段去向。
static void BASerializeMessage(NSData *data, NSUInteger start, NSUInteger end,
                               BAFieldClassify classify, void *ctx,
                               NSMutableData *out, NSInteger depth) {
    if (depth > 12 || end <= start) {
        [out appendBytes:(const uint8_t *)data.bytes + start length:end - start];
        return;
    }
    const uint8_t *b = (const uint8_t *)data.bytes;
    NSUInteger i = start;
    while (i < end) {
        NSUInteger tagStart = i;
        uint64_t tag = 0;
        NSUInteger tagLen = BAReadVarint(b + i, end - i, &tag);
        if (tagLen == 0 || i + tagLen > end) { [out appendBytes:b+tagStart length:end-i]; return; }
        i += tagLen;
        uint32_t fieldNum = (uint32_t)(tag >> 3);
        uint32_t wt = (uint32_t)(tag & 7);

        NSUInteger valueStart = i;
        NSUInteger fieldEnd = 0;
        switch (wt) {
            case BA_WT_VARINT: {
                uint64_t v = 0;
                NSUInteger vl = BAReadVarint(b + i, end - i, &v);
                if (vl == 0) { [out appendBytes:b+tagStart length:end-i]; return; }
                fieldEnd = i + vl;
                break;
            }
            case BA_WT_64BIT: fieldEnd = i + 8; break;
            case BA_WT_32BIT: fieldEnd = i + 4; break;
            case BA_WT_LEN: {
                uint64_t flen = 0;
                NSUInteger fl = BAReadVarint(b + i, end - i, &flen);
                if (fl == 0 || i + fl + flen > end) { [out appendBytes:b+tagStart length:end-i]; return; }
                fieldEnd = i + fl + (NSUInteger)flen;
                valueStart = i + fl;   // 值起点在长度前缀之后（此前误指长度字节，递归子树整体错位）
                break;
            }
            default:
                // 未知 wire type（3/4 group）：整体拷贝剩余，防御
                [out appendBytes:b+tagStart length:end-i];
                return;
        }
        if (fieldEnd > end) { [out appendBytes:b+tagStart length:end-i]; return; }

        BAFieldAction act = {0, nil};
        if (wt == BA_WT_LEN) {
            NSData *value = [data subdataWithRange:NSMakeRange(valueStart, fieldEnd - valueStart)];
            classify(fieldNum, value, &act, ctx);
        }

        switch (act.action) {
            case 1: {  // 字段值替换：重写 tag + varint(len) + 新值
                BAWriteVarint(out, ((uint64_t)fieldNum << 3) | BA_WT_LEN);
                BAWriteVarint(out, act.replacement.length);
                [out appendData:act.replacement];
                break;
            }
            case 2: {  // 子消息递归
                // classify 在 act 里已写入下一层 level（ctx.savedLevel 保存当前层），
                // 递归前后切换游走层级，兄弟字段层级不变
                BAWalkCtx *wctx = (BAWalkCtx *)ctx;
                NSInteger saved = wctx->savedLevel;   // classify 已把 savedLevel=当前层
                NSMutableData *sub = [NSMutableData dataWithCapacity:fieldEnd - valueStart + 64];
                BASerializeMessage(data, valueStart, fieldEnd, classify, ctx, sub, depth + 1);
                wctx->level = saved;                  // 递归返回，恢复本层
                BAWriteVarint(out, ((uint64_t)fieldNum << 3) | BA_WT_LEN);
                BAWriteVarint(out, sub.length);
                [out appendData:sub];
                break;
            }
            default:   // 原样拷贝（tag 起，到字段末尾）
                [out appendBytes:b+tagStart length:fieldEnd - tagStart];
                break;
        }
        i = fieldEnd;
    }
}

// 通用 URL 字段改写：fieldValue 是 LEN 字段的纯内容（UTF-8 字符串）
static void BARewriteUrlField(NSData *fieldValue, BAFieldAction *act, BAWalkCtx *ctx, const char *what) {
    NSString *str = [[NSString alloc] initWithData:fieldValue encoding:NSUTF8StringEncoding];
    if (!str || ![str hasPrefix:@"http"]) return;
    NSString *reason = nil;
    NSString *next = BARewriteUrlDetail(str, &reason);
    next = BAWrapProxy(next);   // 视频 URL 进本地并发代理（与运行时路径同语义）
    if ([next isEqualToString:str]) return;
    BALog(@"pb-rewrite %s [%s] → %s", what, (reason ?: @"?").UTF8String,
          [next substringToIndex:MIN((NSUInteger)100, next.length)].UTF8String);
    act->action = 1;
    act->replacement = [NSMutableData dataWithData:[next dataUsingEncoding:NSUTF8StringEncoding]];
    ctx->changed = YES;
}

// ---- schema 层 classify ----
// 一个 message 内的兄弟字段可能类型不同，但 protobuf 递归时 classify 只有一个 ——
// 所以把 schema 树编进单个 classify：用 ctx 携带当前递归路径。
// 路径枚举（与 docs/*.proto 对应）：
//   S_TOP=0   顶层 PlayViewUniteReply / PlayViewReply
//   S_VOD=1   VodInfo / VideoInfo
//   S_STREAM=2  Stream (VodInfo.5)
//   S_DASH=3    ResponseDash (VideoInfo.9)
//   S_ENTRY=4   DashVideo(Stream.2) / DashItem(dash.video) / ResponseUrl(durl/segment)
//   S_SEG=5     SegmentVideo(Stream.3) → 内部 ResponseUrl

enum {
    BA_S_TOP = 0, BA_S_VOD, BA_S_STREAM, BA_S_DASH, BA_S_ENTRY, BA_S_SEG
};

// 每层递归用子 ctx 指定下一层 level
static void BASchemaClassify(uint32_t field, NSData *value, BAFieldAction *act, void *vctx) {
    BAWalkCtx *ctx = (BAWalkCtx *)vctx;
    NSInteger childLevel = -1;   // -1 = 不递归
    switch (ctx->level) {
        case BA_S_TOP:
            // PlayViewUniteReply.1=VodInfo；PlayViewReply.1=VideoInfo
            if (field == 1) childLevel = BA_S_VOD;
            break;

        case BA_S_VOD:
            // VodInfo: 5=stream_list(Stream) 6=dash_audio 7=dolby 9=loss_less_item
            // VideoInfo: 8=durl(ResponseUrl) 9=dash(ResponseDash)
            if (field == 5)      childLevel = BA_S_STREAM;
            else if (field == 9) childLevel = BA_S_DASH;
            else if (field == 8) childLevel = BA_S_ENTRY;   // durl 的 ResponseUrl
            // 6=dash_audio / 7=dolby / 9(vod)=loss_less_item / 标量 → 原样（音频不动）
            break;

        case BA_S_STREAM:
            // Stream: 2=DashVideo 3=SegmentVideo；1=StreamInfo 原样
            if (field == 2) childLevel = BA_S_ENTRY;  // DashVideo 的 URL 字段
            else if (field == 3) childLevel = BA_S_SEG;
            break;

        case BA_S_DASH:
            // ResponseDash: 1=video(DashItem) 2=audio(DashItem)
            if (field == 1) childLevel = BA_S_ENTRY;  // 仅视频分支递归
            // field==2 (audio) → 原样，绝不递归
            break;

        case BA_S_SEG:
            // SegmentVideo: 1=repeated ResponseUrl
            if (field == 1) childLevel = BA_S_ENTRY;
            break;

        case BA_S_ENTRY:
            // DashItem: 2=base_url 3=backup_url
            // DashVideo: 1=base_url 2=backup_url
            // ResponseUrl: 4=url 5=backup_url
            if (field == 1 || field == 2 || field == 3 || field == 4 || field == 5) {
                BARewriteUrlField(value, act, ctx, "dash");
            }
            break;
    }
    if (childLevel >= 0) {
        // 关键：激活递归分支（此前遗漏 —— action 恒 0 导致 protobuf 路径整体失效）
        act->action = 2;
        // 递归前：保存当前层，切到子层。BASerializeMessage 的 action=2 分支
        // 递归返回后会用 savedLevel 恢复本层，保证兄弟字段层级正确。
        ctx->savedLevel = ctx->level;
        ctx->level = childLevel;
    }
}

// gRPC 帧内 protobuf payload → 按官方 schema 改写视频流 URL（音频路径不进入）
static NSData *BARewriteProtobufBody(NSData *payload, BOOL *changed) {
    *changed = NO;
    if (!BAEnabled() || payload.length < 4) return payload;

    BAWalkCtx ctx = {0};
    ctx.level = BA_S_TOP;

    NSMutableData *out = [NSMutableData dataWithCapacity:payload.length + 256];
    BASerializeMessage(payload, 0, payload.length, BASchemaClassify, &ctx, out, 0);

    if (!ctx.changed) return payload;
    *changed = YES;
    return out;
}

// 视频流并发下载器：对 /seg?u=<url> 请求，向真实 CDN 发起 N 路 Range 并发，
// 按字节序拼接后以 HTTP 200 响应给播放器。音频流永远不会路由到这里。
@interface BAProxy : NSObject
- (NSURL *)innerURLFor:(NSString *)query;
- (long long)totalForURL:(NSURL *)url;   // 带缓存的总大小探测（失败返回 -1）
- (NSData *)cachedPayloadForKey:(NSString *)key;
- (void)storePayload:(NSData *)d forKey:(NSString *)key;
- (NSData *)blockFor:(NSURL *)url index:(long long)idx blockBytes:(long long)B total:(long long)total;
- (NSData *)serveRange:(NSURL *)url from:(long long)from to:(long long)to total:(long long)total;
- (void)prefetchBlocks:(NSURL *)url startIndex:(long long)idx count:(NSInteger)n blockBytes:(long long)B total:(long long)total;
- (NSData *)handleVideoSegment:(NSURL *)url
                       reqFrom:(long long)reqFrom
                         reqTo:(long long)reqTo
                      rangeReq:(BOOL)rangeReq
                         error:(NSError **)err;
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
            // 关键：B 站客户端注册了全局 NSURLProtocol（P2P/自有网络层），
            // 默认配置的请求会被导进其内部状态导致永不回调 —— 必须清空。
            cfg.protocolClasses = nil;
            cfg.connectionProxyDictionary = @{};   // 防系统/App 代理把请求送回本地
            cfg.timeoutIntervalForRequest = 65;
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
#pragma mark 顺序读预取缓存
// 播放器对 dash 分段做顺序小读（实测 stride 45KB~142KB）；每次上游往返都有 RTT。
// serve 完当前窗口后在后台预取下一同尺寸窗口，下次请求直接命中内存缓存。
// 总量上限 64MB，超出淘汰最早条目。
- (NSData *)cachedPayloadForKey:(NSString *)key {
    static NSMutableDictionary *cache;
    static NSMutableArray *order;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
        order = [NSMutableArray array];
        lock = [NSLock new];
    });
    [lock lock];
    NSData *d = cache[key];
    if (d) { [order removeObject:key]; [order addObject:key]; }   // LRU touch
    [lock unlock];
    return d;
}

- (void)storePayload:(NSData *)d forKey:(NSString *)key {
    static NSMutableDictionary *cache;
    static NSMutableArray *order;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
        order = [NSMutableArray array];
        lock = [NSLock new];
    });
    [lock lock];
    cache[key] = d;
    [order addObject:key];
    // 容量淘汰：总字节 > 64MB 或条目 > 64 时，从最早开始删
    while (order.count > 64) {
        NSString *old = order.firstObject;
        [order removeObjectAtIndex:0];
        [cache removeObjectForKey:old];
    }
    [lock unlock];
}

#define BA_BLOCK_BYTES (262144LL)        // 256KB 对齐块
#define BA_BLOCK_CACHE_MAX_BLOCKS 192     // ~48MB

static NSMutableDictionary *BABlockCache;   // key: "url|blk|<idx>"
static NSMutableArray *BABlockOrder;
static NSMutableDictionary *BABlockInflight;
static NSLock *BABlockLock;

static void BABlockInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BABlockCache = [NSMutableDictionary dictionary];
        BABlockOrder = [NSMutableArray array];
        BABlockInflight = [NSMutableDictionary dictionary];
        BABlockLock = [NSLock new];
    });
}

// 播放器读的是 DASH 分段边界（不等长 stride），固定同尺寸预取必然脱靶。
// 改用对齐块缓存：任何 offset 的顺序读都能命中，serve 后后台预取后两块。
- (NSData *)blockFor:(NSURL *)url index:(long long)idx blockBytes:(long long)B total:(long long)total {
    NSString *key = [NSString stringWithFormat:@"%@|blk|%lld", url.absoluteString, idx];
    long long a = idx * B;
    long long b = a + B - 1;
    if (total > 0) b = MIN(b, total - 1);
    if (b < a) return nil;
    long long expect = b - a + 1;

    BABlockLock;
    NSData *cached = BABlockCache[key];
    if (cached && (long long)cached.length == expect) { [BABlockLock unlock]; return cached; }
    BOOL inflight = BABlockInflight[key] != nil;
    [BABlockLock unlock];

    if (inflight) {
        // 有并发线程在拉同一块：等待其完成（信号量轮询）
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
        while ([deadline timeIntervalSinceNow] > 0) {
            usleep(20000);
            BABlockLock;
            NSData *d2 = BABlockCache[key];
            BOOL still = BABlockInflight[key] != nil;
            [BABlockLock unlock];
            if (d2 && (long long)d2.length == expect) return d2;
            if (!still) break;
        }
        return [self cachedPayloadForKey:key];
    }

    // 标记 in-flight
    BABlockLock;
    BABlockInflight[key] = @(YES);
    [BABlockLock unlock];

    NSData *d = [self fetchRange:url from:a to:b lane:0];
    BOOL ok = d && (long long)d.length == expect;
    BABlockLock;
    [BABlockInflight removeObjectForKey:key];
    [BABlockLock unlock];
    if (!ok) return nil;
    // 写缓存 + 容量淘汰
    [self storePayload:d forKey:key];
    [BABlockLock lock];
    [BABlockOrder addObject:key];
    while (BABlockOrder.count > BA_BLOCK_CACHE_MAX_BLOCKS) {
        NSString *old = BABlockOrder.firstObject;
        [BABlockOrder removeObjectAtIndex:0];
        [BABlockCache removeObjectForKey:old];
    }
    [BABlockLock unlock];
    return d;
}

// 有界 Range → 跨块拼装；成功后后台预取后两块
- (NSData *)serveRange:(NSURL *)url from:(long long)from to:(long long)to total:(long long)total {
    long long B = BA_BLOCK_BYTES;
    long long bi = from / B, be = to / B;
    NSMutableData *out = [NSMutableData dataWithCapacity:(NSUInteger)(to - from + 1)];
    for (long long i = bi; i <= be; i++) {
        NSData *blk = [self blockFor:url index:i blockBytes:B total:total];
        if (!blk) return nil;
        long long cs = MAX(i * B, from);
        long long ce = MIN(i * B + B - 1, to);
        NSUInteger off = (NSUInteger)(cs - i * B);
        NSUInteger len = (NSUInteger)(ce - cs + 1);
        if (off + len > blk.length) return nil;
        [out appendData:[blk subdataWithRange:NSMakeRange(off, len)]];
    }
    [self prefetchBlocks:url startIndex:be + 1 count:2 blockBytes:B total:total];
    return out;
}

- (void)prefetchBlocks:(NSURL *)url startIndex:(long long)idx count:(NSInteger)n blockBytes:(long long)B total:(long long)total {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSInteger k = 0; k < n; k++) {
            long long i = idx + k;
            if (total > 0 && i * B > total - 1) return;
            [self blockFor:url index:i blockBytes:B total:total];
        }
    });
}

- (long long)totalForURL:(NSURL *)url {
    if (!url) return -1;
    static NSMutableDictionary *cache;
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
        q = dispatch_queue_create("biliacc.totalcache", DISPATCH_QUEUE_CONCURRENT);
    });
    __block long long cached = -1;
    dispatch_sync(q, ^{ cached = [cache[url.absoluteString] longLongValue]; });
    if (cached > 0) return cached;
    long long t = [self probeTotalSize:url];
    if (t > 0) {
        dispatch_barrier_async(q, ^{ cache[url.absoluteString] = @(t); });
    }
    return t;
}

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
// 备用镜像主机（签名参数与主机无关，换主机是这类加速工具的标准手段）
- (NSArray<NSString *> *)fallbackHosts {
    static dispatch_once_t once;
    static NSArray *s;
    dispatch_once(&once, ^{
        s = @[
            @"upos-sz-mirrorali.bilivideo.com",
            @"upos-sz-mirrorhw.bilivideo.com",
            @"upos-sz-mirrorcos.bilivideo.com",
            @"upos-tf-all-tx.bilivideo.com",
            @"upos-tf-all-hw.bilivideo.com",
        ];
    });
    return s;
}

- (NSURL *)urlWithFallbackHost:(NSURL *)url attempt:(NSInteger)attempt {
    if (!url.host || attempt <= 0) return url;
    NSArray *cands = [self fallbackHosts];
    NSInteger idx = (attempt - 1) % (NSInteger)cands.count;
    // 跳过与当前主机相同的候选
    NSString *cur = url.host.lowercaseString;
    for (NSInteger k = 0; k < (NSInteger)cands.count; k++) {
        NSString *h = cands[(NSUInteger)((idx + k) % cands.count)];
        if (![h isEqualToString:cur]) {
            NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
            if (!c) return url;
            c.host = h;
            return c.URL;
        }
    }
    return url;
}

- (NSData *)fetchRange:(NSURL *)real from:(long long)from to:(long long)to lane:(NSInteger)lane {
    long long expect = to - from + 1;
    NSInteger attempts = 4;   // 原始主机 + 3 个备用镜像
    for (NSInteger attempt = 0; attempt < attempts; attempt++) {
        NSURL *u = [self urlWithFallbackHost:real attempt:attempt];
        NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u];
        [rq setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", from, to] forHTTPHeaderField:@"Range"];
        [rq setTimeoutInterval:15];
        __block NSData *d = nil;
        __block NSInteger status = 0;
        __block NSError *err = nil;
        __block NSString *contentRange = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[_sessions[lane % _sessions.count] dataTaskWithRequest:rq
            completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
                err = e;
                if ([r isKindOfClass:[NSHTTPURLResponse class]]) {
                    NSHTTPURLResponse *hr = (NSHTTPURLResponse *)r;
                    status = hr.statusCode;
                    contentRange = [hr valueForHTTPHeaderField:@"Content-Range"];
                }
                d = data;
                dispatch_semaphore_signal(sem);
            }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20LL * NSEC_PER_SEC));
        if (d && (long long)d.length == expect) {
            // 花屏防护：校验上游确实返回了请求偏移的字节（服务器忽略 Range 时会回 200
            // 全量或错误偏移），起始偏移不符的字节绝不能交给播放器
            if (status == 206 && from > 0) {
                NSString *cr = contentRange;
                if (!cr) {
                    // 206 却没有 Content-Range：无法确认偏移，保守丢弃换主机
                    BAEssentialLog(@"lane %ld attempt %ld: 206 without Content-Range — 丢弃", (long)lane, (long)attempt);
                    continue;
                } else {
                    long long start = strtoll(cr.UTF8String + strspn(cr.UTF8String, "bytes ="), NULL, 10);
                    if (start != from) {
                        BAEssentialLog(@"lane %ld attempt %ld: offset MISMATCH want %lld got %lld (%s) — 丢弃",
                            (long)lane, (long)attempt, from, start, u.host.UTF8String ?: "-");
                        continue;   // 换下一个主机重试
                    }
                }
            }
            return d;
        }
        // 服务器忽略 Range 回 200 全量：from==0 时直接截断前 expect 字节
        if (status == 200 && from == 0 && d && (long long)d.length >= expect)
            return [d subdataWithRange:NSMakeRange(0, (NSUInteger)expect)];
        BAEssentialLog(@"lane %ld attempt %ld host %@ range %lld-%lld status=%ld got %zu (expect %lld) err=%@",
              (long)lane, (long)attempt, u.host, from, to, (long)status, d ? d.length : 0, expect,
              err.localizedDescription ?: @"(none)");
    }
    return nil;
}

// 解析播放器发来的 Range 头："bytes=123-456" / "bytes=123-" / "bytes=-456"
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

    // 无 Range 头（整文件请求）或 open-ended 或 suffix range：探测总大小补全窗口
    if (reqTo < 0 || reqFrom < 0) {
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
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 70LL * NSEC_PER_SEC));
            return body;
        }
        if (reqTo < 0) {
            if (reqFrom < 0) reqFrom = 0;      // 无 Range / bytes=a- → 全量或开区间
            reqTo = total - 1;
        } else {
            reqFrom = total - reqTo;           // bytes=-N suffix → [total-N, total-1]
            reqTo = total - 1;
        }
    }

    long long windowSize = reqTo - reqFrom + 1;
    NSInteger lanes = (NSInteger)BAConcurrency();
    // 窗口小于 384KB 时并发意义有限（握手开销占比升高），单连接直接拉；
    // 384KB 起 6 路均分后每片 >= 64KB，仍显著优于单路
    if (windowSize < 384 * 1024 || lanes <= 1) {
        BAEssentialLog(@"seg: window %lld-%lld (%lldKB) single connection",
              reqFrom, reqTo, windowSize / 1024);
        NSData *body = [self fetchRange:real from:reqFrom to:reqTo lane:0];
        if (body) BAEssentialLog(@"seg: window done %lld bytes", (long long)body.length);
        return body;
    }

    // 把窗口均分成 lanes 段（尾段余量并入最后一段）
    long long slice = (windowSize + lanes - 1) / lanes;
    NSInteger nseg = (NSInteger)((windowSize + slice - 1) / slice);
    BAEssentialLog(@"seg: window %lld-%lld (%lldMB) → %ld slices, %lldKB each",
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
    BAEssentialLog(@"seg: window done %lld bytes", (long long)all.length);
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
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 70LL * NSEC_PER_SEC));
    return body;
}

@end

#pragma mark - 本地 HTTP 服务器

static int BAListenFD = -1;

static void BAServeConnection(int conn) {
    @try {
        char buf[16384];
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
        BAEssentialLog(@"conn: %s", path.UTF8String);
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
            BAEssentialLog(@"seg req: Range=%s (from=%lld to=%lld)",
                (rangeHeader ?: @"(none)").UTF8String, reqFrom, reqTo);
            if (rangeReq && reqFrom >= 0) {
                long long total = [BABackend totalForURL:inner];
                body = [BABackend serveRange:inner from:reqFrom to:reqTo total:total];
            }
            if (!body) {
                body = [BABackend handleVideoSegment:inner reqFrom:reqFrom reqTo:reqTo
                                            rangeReq:rangeReq error:NULL];
            }
        } else if ([path hasPrefix:@"/play"]) {
            body = [BABackend passthrough:inner error:NULL];
        }

        if (!body) {
            const char *resp = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            send(conn, resp, strlen(resp), 0);
            close(conn);
            return;
        }

        // 有 Range 请求 → 回 206 + Content-Range；无 → 200
        // IJKPlayer 需要 Content-Range 带总长度（/* 会让 demuxer 无法确定文件大小而重启）
        NSString *hdr;
        if (rangeReq && reqFrom >= 0) {
            long long total = [BABackend totalForURL:inner];
            if (total > 0) {
                hdr = [NSString stringWithFormat:
                    @"HTTP/1.1 206 Partial Content\r\n"
                     "Content-Type: application/octet-stream\r\n"
                     "Content-Range: bytes %lld-%lld/%lld\r\n"
                     "Content-Length: %zu\r\n"
                     "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                    reqFrom, reqFrom + (long long)body.length - 1, total, body.length];
            } else {
                hdr = [NSString stringWithFormat:
                    @"HTTP/1.1 206 Partial Content\r\n"
                     "Content-Type: application/octet-stream\r\n"
                     "Content-Range: bytes %lld-%lld/*\r\n"
                     "Content-Length: %zu\r\n"
                     "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                    reqFrom, reqFrom + (long long)body.length - 1, body.length];
            }
        } else {
            hdr = [NSString stringWithFormat:
                @"HTTP/1.1 200 OK\r\n"
                 "Content-Type: application/octet-stream\r\n"
                 "Content-Length: %zu\r\n"
                 "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n", body.length];
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

static void BAStartLocalServer(NSInteger port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { BAEssentialLog(@"server: socket() failed errno=%d", errno); return; }
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // 仅本机可达
    addr.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        BAEssentialLog(@"server: bind() failed errno=%d (port %ld 被占用?)", errno, (long)port);
        close(fd); return;
    }
    if (listen(fd, 16) != 0) { BAEssentialLog(@"server: listen() failed errno=%d", errno); close(fd); return; }
    BAListenFD = fd;
    BAEssentialLog(@"server: listening on 127.0.0.1:%ld fd=%d", (long)port, fd);

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

#pragma mark - Hook：Cronet（官方客户端 gRPC/图片走内嵌 Cronet，不经过 NSURLSession）

// B 站 iOS 客户端内嵌 Chromium Cronet（静态链接进主二进制）。
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
#import <mach/mach.h>
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
    vm_address_t addr = 0;
    kern_return_t kr = vm_allocate(mach_task_self(), &addr, PAGE_SIZE, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) return NULL;
    kr = vm_protect(mach_task_self(), addr, PAGE_SIZE, FALSE,
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
        BAEssentialLog(@"Cronet_UrlRequest_InitWithParams NOT FOUND - hook skipped");
        return;
    }
    void *trampoline = BAMakeTrampoline(target);
    if (!trampoline) {
        NSLog(@"[BiliAcc] trampoline alloc FAILED");
        return;
    }
    BACronetTrampolineBuf = trampoline;

    vm_address_t page = (vm_address_t)target & ~(vm_address_t)PAGE_MASK;
    kern_return_t kr = vm_protect(mach_task_self(), page, PAGE_SIZE, FALSE,
                                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[BiliAcc] vm_protect FAILED: %d", kr);
        return;
    }
    BAWriteJump(target, (void *)BAHookCronetInit);
    NSLog(@"[BiliAcc] Cronet inline hook installed at %p (trampoline %p)", target, trampoline);
}

#pragma mark - Hook：gRPC 反序列化 ObjC model（正确的拦截点）

// 官方客户端把 gRPC 响应反序列化成 ObjC model 类（moss 框架，类名前缀
// BAPIApp...），反序列化入口是 initWithData:extensionRegistry:error:。
// 这些是 ObjC 类，objc_getClass 一定拿得到 —— 不管 Cronet 符号有没有被 strip。
// 依据：BiliBiliTweak 项目同样用此法 hook BAPIAppViewuniteV1ViewProgressReply。
//
// 改写目标（对应 docs/*.proto）：
//   PlayViewUniteReply.vodInfo.streamList[·].dashVideo.baseUrl/backupUrl ← 视频流
//   PlayViewUniteReply.vodInfo.dashAudio/dolby/lossLessItem ← 音频，不碰
//   PlayViewReply.videoInfo.durl[·].url / videoInfo.dash.video[·].baseUrl ← 视频流
//   PlayViewReply.videoInfo.dash.audio ← 音频，不碰
//
// 属性名大小写不确定（moss 生成器版本差异），运行时多候选尝试。

#pragma mark - 运行时属性树递归改写（结构感知，零属性名猜测）

// 音频豁免判定：键路径含 audio/dolby/lossless，或对象带 isAudio==YES
static BOOL BAAudioSubtree(NSString *keyPath, id obj) {
    if (keyPath) {
        NSString *lower = keyPath.lowercaseString;
        if ([lower containsString:@"audio"] || [lower containsString:@"dolby"] ||
            [lower containsString:@"lossless"]) {
            return YES;
        }
    }
    // isAudio 属性为真（NSNumber/int 包装）
    @try {
        id isAudio = [obj valueForKey:@"isAudio"];
        if ([isAudio respondsToSelector:@selector(boolValue)] && [isAudio boolValue]) {
            return YES;
        }
    } @catch (NSException *e) { (void)e; }
    return NO;
}

// 对单个叶子改写：返回新值或 nil（未变）
static id BARewriteMediaValue(id val) {
    NSString *s = nil;
    if ([val isKindOfClass:[NSString class]]) s = val;
    else if ([val isKindOfClass:[NSURL class]]) s = [val absoluteString];
    if (!s) return nil;
    NSURL *u = [NSURL URLWithString:s];
    if (!u || !BAIsMediaURL(u) || BAIsLiveMedia(u)) return nil;
    if ([s hasPrefix:@"http://127.0.0.1"]) return nil;
    NSString *reason = nil;
    NSString *next = BAWrapProxy(BARewriteUrlDetail(s, &reason));
    if ([next isEqualToString:s]) return nil;
    return next;
}

// 递归遍历对象属性树，改写所有媒体 URL。excludes 防御环形引用。
static void BADeepRewrite(id obj, NSString *keyPath, int depth, NSMutableSet *seen) {
    if (depth > 8 || !obj || [seen containsObject:obj]) return;
    [seen addObject:obj];

    if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in obj) BADeepRewrite(item, keyPath, depth + 1, seen);
        return;
    }
    if (![obj respondsToSelector:@selector(valueForKey:)]) return;
    if (BAAudioSubtree(keyPath, obj)) return;   // 音频子树剪枝

    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(object_getClass(obj), &count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *pname = [NSString stringWithUTF8String:property_getName(props[i])];
        @try {
            id val = [obj valueForKey:pname];
            if (!val) continue;
            NSString *childPath = keyPath
                ? [keyPath stringByAppendingFormat:@".%@", pname] : pname;
            if ([val isKindOfClass:[NSString class]] || [val isKindOfClass:[NSURL class]]) {
                id next = BARewriteMediaValue(val);
                if (next) {
                    @try {
                        [obj setValue:next forKey:pname];
                        NSString *ns = (NSString *)next;
                        NSString *pv = [ns length] > 90 ? [ns substringToIndex:90] : ns;
                        BAEssentialLog(@"rt-rewrite %s: %s",
                            childPath ? childPath.UTF8String : "(nil)",
                            pv.UTF8String ?: "");
                    } @catch (NSException *e) { (void)e; }
                }
            } else if ([val isKindOfClass:[NSArray class]] ||
                       [val isKindOfClass:[NSDictionary class]] ||
                       ([val isKindOfClass:[NSObject class]] &&
                        ![val isKindOfClass:[NSString class]] &&
                        ![val isKindOfClass:[NSNumber class]] &&
                        ![val isKindOfClass:[NSValue class]])) {
                BADeepRewrite(val, childPath, depth + 1, seen);
            }
        } @catch (NSException *e) { (void)e; }
    }
    free(props);
}

// 入口：整个 reply 树递归
static void BAObjectRewrite(id reply) {
    if (!BAEnabled() || !reply) return;
    @try {
        BADeepRewrite(reply, nil, 0, [NSMutableSet set]);
    } @catch (NSException *e) {
        NSLog(@"[BiliAcc] deep rewrite error: %@", e);
    }
}

// 拦截 PlayViewUniteReply 反序列化
static id (*BAOrigPVUInit)(id, SEL, id, id, id *);
static id BAHookPVUInit(id self, SEL _cmd, id data, id registry, id *error) {
    id ret = BAOrigPVUInit(self, _cmd, data, registry, error);
    if (ret) BAObjectRewrite(ret);
    return ret;
}

// 拦截 PlayViewReply（老接口）反序列化
static id (*BAOrigPVInit)(id, SEL, id, id, id *);
static id BAHookPVInit(id self, SEL _cmd, id data, id registry, id *error) {
    id ret = BAOrigPVInit(self, _cmd, data, registry, error);
    if (ret) BAObjectRewrite(ret);
    return ret;
}

// 类名变体搜索：moss 生成器前缀可能是 BAPIApp / BApi / 无前缀
static Class BAFindReplyClass(NSArray<NSString *> *candidates) {
    for (NSString *name in candidates) {
        Class c = objc_getClass(name.UTF8String);
        if (c) {
            BAEssentialLog(@"found reply class: %@", name);
            return c;
        }
    }
    return nil;
}

// 诊断：AVPlayer 后备引擎的媒体 URL（真机 VIP 流疑似走 IJKFFMoviePlayerControllerAVPlayer）
static IMP BAOrigAVURLAssetInit = NULL;
static id BAHookAVURLAssetInit(id self, SEL _cmd, NSURL *url, NSDictionary *opts) {
    if (url && BAIsMediaURL(url) && !BAIsLiveMedia(url)) {
        BAEssentialLog(@"AVURLAsset open: %@", url.absoluteString);
    }
    return ((id (*)(id, SEL, NSURL *, NSDictionary *))BAOrigAVURLAssetInit)(self, _cmd, url, opts);
}


// ============ IJK URL 打开层 hook（本地逆向结论）============
// B 站自研 IJK fork：播放器通过 IJKMediaUrlOpenDelegate.ijkUrlChange: 打开媒体，
// IJKMediaUrlOpenData.url 可被 delegate 改写（urlChanged 标志）——这是官方认可的
// URL 重定向通道（B 站 P2P 层即此方式）。在此层改写不依赖 reply 拷贝时机。
// FFPlay 控制器（IJKFFMoviePlayerControllerFFPlay）持有 5 个 delegate：
//   file/segment/http（媒体相关，需包装）、live（直播，跳过）、tcp（连接级，跳过）。
@protocol BAIJKOpenDataProxy <NSObject>
@property(nonatomic, copy) NSString *url;
@property(nonatomic, assign) BOOL urlChanged;
@property(nonatomic, assign) int isAudio;
@property(nonatomic, assign) int segmentIndex;
@property(nonatomic, assign) int retryCounter;
@end

@interface BAIJKOpenDelegateWrap : NSObject
@property(nonatomic, strong) id orig;
+ (instancetype)wrap:(id)orig;
- (void)ijkUrlChange:(id<BAIJKOpenDataProxy>)data;
@end

@implementation BAIJKOpenDelegateWrap
+ (instancetype)wrap:(id)orig {
    if (!orig) return nil;
    // 已是 wrapper 的不二次包装
    if ([orig isKindOfClass:self]) return orig;
    BAIJKOpenDelegateWrap *w = [[self alloc] init];
    w.orig = orig;
    return w;
}
- (BOOL)respondsToSelector:(SEL)sel {
    if (sel == @selector(ijkUrlChange:)) return YES;
    return [_orig respondsToSelector:sel] || [super respondsToSelector:sel];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *s = [(id)_orig methodSignatureForSelector:sel];
    return s ?: [super methodSignatureForSelector:sel];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    id o = _orig;
    if (o && [o respondsToSelector:inv.selector]) [inv invokeWithTarget:o];
}
- (void)ijkUrlChange:(id<BAIJKOpenDataProxy>)data {
    @try {
        NSString *u = data.url;
        if (u && BAEnabled() && ![u hasPrefix:@"http://127.0.0.1"]) {
            NSURL *uu = [NSURL URLWithString:u];
            if (uu && BAIsMediaURL(uu) && !BAIsLiveMedia(uu)) {
                BOOL audio = NO;
                if ([data respondsToSelector:@selector(isAudio)]) audio = data.isAudio != 0;
                if (!audio) {
                    NSString *reason = nil;
                    NSString *next = BAWrapProxy(BARewriteUrlDetail(u, &reason));
                    if (next && ![next isEqualToString:u]) {
                        data.url = next;
                        data.urlChanged = YES;
                        BAEssentialLog(@"open-rewrite seg=%d [%@] → %s",
                            data.segmentIndex, reason ?: @"?", next.UTF8String);
                    }
                }
            }
        }
    } @catch (NSException *e) { (void)e; }
    id o = _orig;
    if (o && [o respondsToSelector:@selector(ijkUrlChange:)]) {
        [(id)o ijkUrlChange:data];
    }
}
@end

// delegate setter 三连 swizzle（segment/http/file；live/tcp 跳过）
static IMP BAOrigSetSegDelegate = NULL;
static IMP BAOrigSetHttpDelegate = NULL;
static IMP BAOrigSetFileDelegate = NULL;

static void BAWrapSetSegDelegate(id self, SEL _cmd, id d) {
    ((void (*)(id, SEL, id))BAOrigSetSegDelegate)(self, _cmd, [BAIJKOpenDelegateWrap wrap:d]);
}
static void BAWrapSetHttpDelegate(id self, SEL _cmd, id d) {
    ((void (*)(id, SEL, id))BAOrigSetHttpDelegate)(self, _cmd, [BAIJKOpenDelegateWrap wrap:d]);
}
static void BAWrapSetFileDelegate(id self, SEL _cmd, id d) {
    ((void (*)(id, SEL, id))BAOrigSetFileDelegate)(self, _cmd, [BAIJKOpenDelegateWrap wrap:d]);
}

static void BAWrapOpenDelegates(void) {
    // FFPlay 与 AVPlayer 两个控制器类都可能有这些 setter
    NSArray *clsNames = @[ @"IJKFFMoviePlayerControllerFFPlay",
                           @"IJKFFMoviePlayerController" ];
    for (NSString *cn in clsNames) {
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;
        struct { const char *sel; IMP *orig; void *newfn; } specs[] = {
            { "setSegmentOpenDelegate:", &BAOrigSetSegDelegate,   (void *)&BAWrapSetSegDelegate },
            { "setHttpOpenDelegate:",    &BAOrigSetHttpDelegate,  (void *)&BAWrapSetHttpDelegate },
            { "setFileOpenDelegate:",    &BAOrigSetFileDelegate,  (void *)&BAWrapSetFileDelegate },
        };
        for (NSUInteger i = 0; i < sizeof(specs)/sizeof(specs[0]); i++) {
            SEL s = sel_registerName(specs[i].sel);
            Method m = class_getInstanceMethod(c, s);
            if (!m || *specs[i].orig) continue;
            *specs[i].orig = method_getImplementation(m);
            method_setImplementation(m, (IMP)specs[i].newfn);
            BAEssentialLog(@"open-delegate wrap: %s on %s", specs[i].sel, cn.UTF8String);
        }
    }
}

// ============ 最终模型层改写（根治）============
// IJKMediaAssetStreamSegment 是播放器消费 URL 的最终模型——无论 playurl 从哪条
// API 路径来（PlayViewUnite / PlayView / pgc / 预取缓存），URL 都在这里实例化。
// hook initWithUrl: 保证任何拷贝时机下的改写都能落地（reply 层是竞速，这层是必经）。
static IMP BAOrigSegmentInit = NULL;
static id BAHookSegmentInit(id self, SEL _cmd, NSString *url) {
    NSString *u = url;
    if (u && BAEnabled() && ![u hasPrefix:@"http://127.0.0.1"]) {
        NSURL *nu = [NSURL URLWithString:u];
        if (nu && BAIsMediaURL(nu) && !BAIsLiveMedia(nu)) {
            NSString *reason = nil;
            NSString *next = BAWrapProxy(BARewriteUrlDetail(u, &reason));
            if (next && ![next isEqualToString:u]) {
                BAEssentialLog(@"segment-init rewrite → %s", next.UTF8String);
                u = next;
            }
        }
    }
    return ((id (*)(id, SEL, NSString *))BAOrigSegmentInit)(self, _cmd, u);
}

static IMP BAOrigSegSetBackups = NULL;
static void BAHookSegSetBackups(id self, SEL _cmd, NSArray *urls) {
    if (urls && BAEnabled()) {
        NSMutableArray *rewritten = nil;
        for (id obj in urls) {
            NSString *u = [obj isKindOfClass:[NSString class]] ? obj :
                          ([obj isKindOfClass:[NSURL class]] ? [obj absoluteString] : nil);
            if (!u || [u hasPrefix:@"http://127.0.0.1"]) continue;
            NSURL *nu = [NSURL URLWithString:u];
            if (!nu || !BAIsMediaURL(nu) || BAIsLiveMedia(nu)) continue;
            // backup 是播放器的逃生通道：只包本地代理、不换主机
            // （换镜像可能导致 backup 不可达——AV1 冷门文件镜像缺缓存 → 卡死）
            NSString *next = BAWrapProxy(u);
            if (![next isEqualToString:u]) {
                if (!rewritten) {
                    rewritten = [NSMutableArray arrayWithArray:urls];
                }
                NSUInteger idx = [rewritten indexOfObject:obj];
                if (idx != NSNotFound) [rewritten replaceObjectAtIndex:idx withObject:next];
            }
        }
        if (rewritten) {
            ((void (*)(id, SEL, NSArray *))BAOrigSegSetBackups)(self, _cmd, rewritten);
            return;
        }
    }
    if (BAOrigSegSetBackups)
        ((void (*)(id, SEL, NSArray *))BAOrigSegSetBackups)(self, _cmd, urls);
}

static void BAWrapSegmentModel(void) {
    Class c = objc_getClass("IJKMediaAssetStreamSegment");
    if (!c) { BAEssentialLog(@"segment-model: class not found"); return; }
    Method m1 = class_getInstanceMethod(c, @selector(initWithUrl:));
    if (m1 && !BAOrigSegmentInit) {
        BAOrigSegmentInit = method_getImplementation(m1);
        method_setImplementation(m1, (IMP)BAHookSegmentInit);
        BAEssentialLog(@"segment-model: initWithUrl: hooked");
    }
    Method m2 = class_getInstanceMethod(c, @selector(setBackupUrls:));
    if (m2 && !BAOrigSegSetBackups) {
        BAOrigSegSetBackups = method_getImplementation(m2);
        method_setImplementation(m2, (IMP)BAHookSegSetBackups);
        BAEssentialLog(@"segment-model: setBackupUrls: hooked");
    }
}

static void BAHookGrpcModels(void) {
    // AVURLAsset（AVPlayer 引擎）诊断 hook
    if (!BAOrigAVURLAssetInit) {
        Class avCls = objc_getClass("AVURLAsset");
        Method avm = avCls ? class_getInstanceMethod(avCls, @selector(initWithURL:options:)) : NULL;
        if (avm) {
            BAOrigAVURLAssetInit = method_getImplementation(avm);
            method_setImplementation(avm, (IMP)BAHookAVURLAssetInit);
            BAEssentialLog(@"AVURLAsset hook installed");
        } else {
            BAEssentialLog(@"AVURLAsset initWithURL:options: not found");
        }
    }
    SEL sel = NSSelectorFromString(@"initWithData:extensionRegistry:error:");

    // 新统一播放器：PlayViewUnite
    Class pvu = BAFindReplyClass(@[
        @"BAPIAppPlayeruniteV1PlayViewUniteReply",
        @"BApiAppPlayeruniteV1PlayViewUniteReply",
        @"BAPIPlayeruniteV1PlayViewUniteReply",
        @"PlayViewUniteReply",
    ]);
    if (pvu) {
        Method m = class_getInstanceMethod(pvu, sel);
        if (m) {
            BAOrigPVUInit = (id (*)(id, SEL, id, id, id *))method_getImplementation(m);
            method_setImplementation(m, (IMP)BAHookPVUInit);
            BAEssentialLog(@"hooked PlayViewUniteReply initWithData");
        }
    }

    // 老接口：PlayURL/PlayView
    Class pv = BAFindReplyClass(@[
        @"BAPIAppPlayurlV1PlayViewReply",
        @"BApiAppPlayurlV1PlayViewReply",
        @"BAPIPlayurlV1PlayViewReply",
        @"PlayViewReply",
    ]);
    if (pv) {
        Method m = class_getInstanceMethod(pv, sel);
        if (m) {
            BAOrigPVInit = (id (*)(id, SEL, id, id, id *))method_getImplementation(m);
            method_setImplementation(m, (IMP)BAHookPVInit);
            BAEssentialLog(@"hooked PlayViewReply initWithData");
        }
    }

    if (!pvu && !pv) {
        unsigned int n = 0;
        Class *classes = objc_copyClassList(&n);
        NSMutableArray *hits = [NSMutableArray array];
        for (unsigned int i = 0; i < n; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            if ([name containsString:@"PlayViewUnite"] && [name hasSuffix:@"Reply"]) {
                [hits addObject:name];
            }
        }
        free(classes);
        NSLog(@"[BiliAcc] no known reply class found; candidates: %{public}s", hits.description.UTF8String);
    }
}

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

#pragma mark - 运行时类 dump（本地逆向：SIMCTL_CHILD_BiliAcc_dump=IJK,BBPlayer,...）

// 把匹配前缀的 ObjC 类的方法/属性表 dump 到 tmp/dump_<类名>.txt，
// 供本地静态分析播放器 URL 流转（模拟器 loop 免真机迭代）
static void BARuntimeDump(void) {
    NSString *spec = BAEnvOverride(@"BiliAcc_dump");
    if (!spec.length) return;
    NSArray *prefixes = [spec componentsSeparatedByString:@","];
    unsigned int n = 0;
    Class *classes = objc_copyClassList(&n);
    if (!classes) return;
    @autoreleasepool {
        for (unsigned int i = 0; i < n; i++) {
            Class c = classes[i];
            NSString *name = NSStringFromClass(c);
            BOOL hit = NO;
            for (NSString *p in prefixes) if ([name hasPrefix:p]) { hit = YES; break; }
            if (!hit) continue;
            NSMutableString *out = [NSMutableString stringWithFormat:@"== %@ ==\n\n[properties]\n", name];
            unsigned int pc = 0;
            objc_property_t *props = class_copyPropertyList(c, &pc);
            for (unsigned int j = 0; j < pc; j++) {
                const char *pn = property_getName(props[j]);
                const char *pa = property_getAttributes(props[j]);
                [out appendFormat:@"%s  (%s)\n", pn, pa];
            }
            free(props);
            [out appendString:@"\n[instance methods]\n"];
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            for (unsigned int j = 0; j < mc; j++) {
                [out appendFormat:@"%@ %s\n",
                    NSStringFromSelector(method_getName(ms[j])),
                    method_getTypeEncoding(ms[j])];
            }
            free(ms);
            [out appendString:@"\n[class methods]\n"];
            Class meta = object_getClass(c);
            unsigned int mc2 = 0;
            Method *ms2 = class_copyMethodList(meta, &mc2);
            for (unsigned int j = 0; j < mc2; j++) {
                [out appendFormat:@"+ %@ %s\n",
                    NSStringFromSelector(method_getName(ms2[j])),
                    method_getTypeEncoding(ms2[j])];
            }
            free(ms2);
            NSString *path = [NSTemporaryDirectory()
                stringByAppendingFormat:@"dump_%@.txt", name];
            [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"[BiliAcc] dumped %s (%u props, %u im, %u cm) -> %s",
                  name.UTF8String, pc, mc, mc2, path.lastPathComponent.UTF8String);
        }
    }
    free(classes);
}


#if BA_HAS_UI
#pragma mark - 悬浮调试窗（日志尾随 + 功能开关，全部写 CFPreferences 即时生效）

static void BAPrefSet(NSString *key, id v) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)v,
                             (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
}

@interface BADebugPanel : NSObject <UITextFieldDelegate>
+ (instancetype)shared;
- (void)show;
- (void)hide;
@end

static UIWindow *BAFloatWin = nil;   // 悬浮小球窗（36x36）
static UIWindow *BAPanelWin = nil;   // 面板窗（点开时创建）
static BADebugPanel *BADebugShared = nil;

@implementation BADebugPanel {
    UIView *_panel;
    UITextView *_logView;
    UISwitch *_swEnabled, *_swOverlay;
    UISegmentedControl *_segMode;
    UILabel *_lblLanes;
    NSTimer *_tailTimer;
}

+ (instancetype)shared {
    if (!BADebugShared) BADebugShared = [[self alloc] init];
    return BADebugShared;
}

// 面板视图直接挂到悬浮窗（BAPassthroughWindow 同窗），居中显示
- (UIView *)buildPanel {
    if (_panel) return _panel;
    UIWindow *appWin = [UIApplication sharedApplication].windows.firstObject;
    CGFloat aw = appWin ? appWin.bounds.size.width : 390;
    CGFloat ah = appWin ? appWin.bounds.size.height : 844;
    CGFloat pw = aw - 24, ph = MIN(460, ah - 160);
    _panel = [[UIView alloc] initWithFrame:CGRectMake((aw - pw) / 2, (ah - ph) / 2 - 40, pw, ph)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.97];
    _panel.layer.cornerRadius = 14;
    _panel.layer.masksToBounds = YES;
    _panel.hidden = YES;
    return _panel;
}

- (void)buildUI {
    UIView *w = [self buildPanel];
    if (_swEnabled) return;   // 只构建一次
    CGFloat wpx = w.bounds.size.width, x = 12, cw = wpx - 24;
    CGFloat y = 8;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(x, y, cw - 30, 22)];
    title.text = @"BiliAccelerator";
    title.textColor = [UIColor systemPinkColor];
    title.font = [UIFont boldSystemFontOfSize:15];
    [_panel addSubview:title];

    UIButton *close = [[UIButton alloc] initWithFrame:CGRectMake(wpx - 34, y, 28, 22)];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:14];
    close.tintColor = UIColor.whiteColor;
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [close addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:close];

    y += 30;
    _swEnabled = [[UISwitch alloc] initWithFrame:CGRectMake(wpx - 60, y, 51, 31)];
    _swEnabled.on = BAEnabled();
    [_swEnabled addTarget:self action:@selector(toggleEnabled:)
         forControlEvents:UIControlEventValueChanged];
    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(x, y + 3, 120, 24)];
    l1.text = @"启用加速"; l1.textColor = UIColor.whiteColor;
    l1.font = [UIFont systemFontOfSize:13];
    [_panel addSubview:l1]; [_panel addSubview:_swEnabled];

    y += 44;
    _segMode = [[UISegmentedControl alloc] initWithItems:@[@"bad-only", @"force", @"off"]];
    _segMode.frame = CGRectMake(x, y, cw, 30);
    NSString *m = BAMode();
    _segMode.selectedSegmentIndex = [m isEqualToString:@"force"] ? 1 : ([m isEqualToString:@"off"] ? 2 : 0);
    [_segMode addTarget:self action:@selector(changeMode:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:_segMode];

    y += 44;
    UIStepper *st = [[UIStepper alloc] initWithFrame:CGRectMake(wpx - 110, y, 94, 29)];
    st.minimumValue = 1; st.maximumValue = 16; st.stepValue = 1;
    st.value = BAConcurrency();
    [st addTarget:self action:@selector(changeLanes:) forControlEvents:UIControlEventValueChanged];
    _lblLanes = [[UILabel alloc] initWithFrame:CGRectMake(x, y + 3, 140, 24)];
    _lblLanes.text = [NSString stringWithFormat:@"并发路数: %ld", (long)BAConcurrency()];
    _lblLanes.textColor = UIColor.whiteColor; _lblLanes.font = [UIFont systemFontOfSize:13];
    _lblLanes.tag = 99;
    [_panel addSubview:_lblLanes]; [_panel addSubview:st];

    y += 44;
    _swOverlay = [[UISwitch alloc] initWithFrame:CGRectMake(wpx - 60, y, 51, 31)];
    _swOverlay.on = YES;
    [_swOverlay addTarget:self action:@selector(toggleOverlay:) forControlEvents:UIControlEventValueChanged];
    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(x, y + 3, 160, 24)];
    l2.text = @"显示悬浮按钮"; l2.textColor = UIColor.whiteColor;
    l2.font = [UIFont systemFontOfSize:13];
    [_panel addSubview:l2]; [_panel addSubview:_swOverlay];

    y += 42;
    _logView = [[UITextView alloc] initWithFrame:CGRectMake(x, y, cw, w.bounds.size.height - y - 12)];
    _logView.editable = NO;
    _logView.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.55 alpha:1];
    _logView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.9];
    _logView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    [_panel addSubview:_logView];

    // 日志尾随定时器
    __weak typeof(self) ws = self;
    _tailTimer = [NSTimer timerWithTimeInterval:1.0
        target:self selector:@selector(refreshLog) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_tailTimer forMode:NSRunLoopCommonModes];
    (void)ws;
}

- (void)toggleEnabled:(UISwitch *)s { BAPrefSet(@"BiliAcc_enabled", @(s.on)); }
- (void)changeMode:(UISegmentedControl *)seg {
    BAPrefSet(@"BiliAcc_mode", @[@"bad-only", @"force", @"off"][(NSUInteger)seg.selectedSegmentIndex]);
}
- (void)changeLanes:(UIStepper *)st {
    BAPrefSet(@"BiliAcc_concurrency", @(st.value));
    _lblLanes.text = [NSString stringWithFormat:@"并发 %ld", (long)(NSInteger)st.value];
}

- (void)refreshLog {
    if (!_logView || _panel.hidden) return;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"BiliAcc.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return;
    NSDictionary *attr = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = attr ? attr.fileSize : 0;
    unsigned long long off = size > 6000 ? size - 6000 : 0;
    [fh seekToFileOffset:off];
    NSData *d = [fh readDataToEndOfFile]; [fh closeFile];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL atBottom = _logView.contentOffset.y + _logView.bounds.size.height >= _logView.contentSize.height - 40;
        [_logView setText:s];
        if (atBottom) {
            NSRange r = NSMakeRange(_logView.text.length, 0);
            [_logView scrollRangeToVisible:r];
        }
    });
}

- (void)show {
    UIView *p = [self buildPanel];
    if (!p.superview) {
        // 面板窗口独立创建（不覆盖按钮窗），尺寸=面板大小
        UIWindow *pw = [[UIWindow alloc] initWithFrame:p.frame];
        pw.windowLevel = UIWindowLevelAlert + 100;
        pw.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.97];
        pw.layer.cornerRadius = 14;
        pw.layer.masksToBounds = YES;
        pw.hidden = NO;
        [pw addSubview:p];
        p.frame = pw.bounds;
        // 不 makeKeyAndVisible：成为 key window 会拦截 B 站全部触摸
        BAPanelWin = pw;
    }
    [self buildUI];
    BAPanelWin.hidden = NO;
    [self refreshLog];
}

- (void)hide {
    if (_panel) _panel.hidden = YES;
    if (BAPanelWin) BAPanelWin.hidden = YES;   // 整窗隐藏，触摸还给 B 站
}
- (BOOL)isPanelVisible { return _panel && !_panel.hidden; }

@end

@class BAFloatingButton;
@interface BAPassthroughWindow : UIWindow @end
@implementation BAPassthroughWindow {
    NSDate *_lastHitLog;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 空白区域时 super 返回窗口自身 → 穿透给 App；落在子视图（按钮）上 → 正常接收
    if (hit == self || hit == nil) return nil;
    if ([NSStringFromClass([hit class]) isEqualToString:@"BAFloatingButton"]
        && (!_lastHitLog || -[_lastHitLog timeIntervalSinceNow] > 2)) {
        _lastHitLog = [NSDate date];
        BAEssentialLog(@"passthrough hit: floating button (window %@)",
            self.hidden ? @"hidden" : @"visible");
    }
    return hit;
}
@end

// 悬浮小圆钮（可拖动，点击开关面板）
@interface BAFloatingButton : UIButton
@property(nonatomic, strong) BADebugPanel *panel;
@end
@implementation BAFloatingButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.75];
        self.layer.cornerRadius = 16;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor systemPinkColor].CGColor;
        [self setTitle:@"B" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        // 无任何手势（用户要求）：按钮固定位置，仅支持点击开合面板
        [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
// 拖动手势已移除（双击点赞时与系统手势冲突导致崩溃）——按钮位置固定

- (void)tapped {
    BAEssentialLog(@"floating button TAPPED (visible=%d)", (int)[BADebugPanel shared].isPanelVisible);
    BADebugPanel *p = [BADebugPanel shared];
    if ([p isPanelVisible]) {
        [p hide];
        BAPanelWin.hidden = YES;
    } else {
        [p show];
    }
}
@end

static void BAShowOverlay(void) {
    if (!BAEnabled()) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (BAFloatWin) return;
            UIWindow *win = [UIApplication sharedApplication].windows.firstObject;
            CGRect fb = win ? win.bounds : CGRectMake(0, 0, 390, 844);
            // 关键：窗口就是按钮大小（36x36）—— 全屏大小的透明窗即使 hitTest 穿透，
            // 也会截获/延迟 B 站全屏按钮的触摸事件（触摸必须先穿过更高层的窗口）
            CGRect btnFrame = CGRectMake(fb.size.width - 52, 160, 36, 36);
            BAFloatWin = [[UIWindow alloc] initWithFrame:btnFrame];
            BAFloatWin.windowLevel = UIWindowLevelAlert + 99;
            BAFloatWin.backgroundColor = [UIColor clearColor];
            BAFloatWin.hidden = NO;
            BAFloatingButton *btn = [[BAFloatingButton alloc] initWithFrame:BAFloatWin.bounds];
            [BAFloatWin addSubview:btn];
            BAEssentialLog(@"overlay floating button shown (compact window)");
        });
}
#endif  // BA_HAS_UI

#pragma mark - 入口

// constructor 里不能用 BAQuery*（它们依赖 ObjC runtime 完全就绪的时序没问题，
// 但为了诊断加载失败，先用 C 接口直接读一次 enabled）
#ifdef BA_NO_CONSTRUCTOR
static void BiliAccInitUnused(void) { (void)0; }
#else
__attribute__((constructor))
static void BiliAccInit(void) {
    @autoreleasepool {
        BAEssentialLog(@"dylib constructor entered (build %s)", __DATE__ " " __TIME__);
        if (!BAEnabled()) {
            BAEssentialLog(@"disabled via BiliAcc_enabled, exiting");
            return;
        }
        BABackend = [BAProxy new];
        BAStartLocalServer(BAProxyPort());

        // swizzle NSURLSession dataTaskWithRequest:completionHandler:
        // （兜底路径：部分旧版本/特定接口仍走 NSURLSession）
        Method m = class_getInstanceMethod([NSURLSession class],
                                           @selector(dataTaskWithRequest:completionHandler:));
        if (m) {
            BAOrigDataTask = (NSURLSessionDataTask * (*)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)))
                method_getImplementation(m);
            method_setImplementation(m, (IMP)BAHookDataTask);
        }

        // 拦截 Cronet —— 媒体分片出站改写（若符号被 strip 会打 NOT FOUND 跳过）
        BAHookCronet();

        // 拦截 gRPC 反序列化 model —— 主拦截点（ObjC 类永不 strip）
        // 延迟到 +load 之后的下一个 runloop：让 App 把所有 framework 类加载完
        dispatch_async(dispatch_get_main_queue(), ^{
            BAHookGrpcModels();
            BARuntimeDump();
        });
        // delegate 包装 swizzle：FFPlay 类静态链接于主二进制，构造期即可用
        BAWrapOpenDelegates();
        // 最终模型层改写（IJKMediaAssetStreamSegment）——URL 消费的必经点
        BAWrapSegmentModel();
#if BA_HAS_UI
        BAShowOverlay();
#ifdef BA_AUTO_PANEL
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{ [[BADebugPanel shared] show]; });
#endif
#endif

        BAEssentialLog(@"loaded, proxy on 127.0.0.1:%ld, mode=%@, target=%@, lanes=%ld, verbose=%d",
              (long)BAProxyPort(), BAMode(), BATargetHost(), (long)BAConcurrency(), BAVerbose());
#ifdef BA_AUTO_VIDEO
        // 测试模式：启动后自动跳进指定视频（真机无 openurl，进程内自唤起）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12LL * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
                NSURL *u = [NSURL URLWithString:@"bilibili://video/41963095721"];
                [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:^(BOOL ok) {
                    BAEssentialLog(@"auto-video openURL ok=%d", ok);
                }];
            });
#endif
    }
}
#endif

