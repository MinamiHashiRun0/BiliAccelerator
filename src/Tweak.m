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

// 详细日志开关：默认关；YES 时逐条打印每次改写/代理请求
static BOOL BAVerbose(void) {
    return BAQueryBool(@"BiliAcc_verbose", NO);
}

#define BALog(...) do { if (BAVerbose()) NSLog(@"[BiliAcc] " __VA_ARGS__); } while (0)

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
    if ([next isEqualToString:str]) return;
    BALog(@"pb-rewrite %s [%@] → %@", what, reason ?: @"?",
          [next substringToIndex:MIN((NSUInteger)100, next.length)]);
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
    if (childLevel >= 0 && act->action == 2) {
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
        BALog(@"lane %ld attempt %ld range %lld-%lld got %zu bytes (expect %lld)",
              (long)lane, (long)attempt, from, to, d ? d.length : 0, expect);
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
    BALog(@"seg proxy: total=%lld host=%@", total, real.host);
    if (total <= 0) {
        // CDN 不支持 Range/HEAD → 单连接全量下载兜底
        BALog(@"Range probe failed, falling back to single connection");
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
    BALog(@"fan-out: %ld segments × %ldMB, lanes=%ld",
          (long)nseg, (long)BAChunkMB(), (long)BAConcurrency());
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

// constructor 里不能用 BAQuery*（它们依赖 ObjC runtime 完全就绪的时序没问题，
// 但为了诊断加载失败，先用 C 接口直接读一次 enabled）
__attribute__((constructor))
static void BiliAccInit(void) {
    @autoreleasepool {
        NSLog(@"[BiliAcc] dylib constructor entered (build %s)", __DATE__ " " __TIME__);
        if (!BAEnabled()) {
            NSLog(@"[BiliAcc] disabled via BiliAcc_enabled, exiting");
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

        // 拦截 Cronet —— 官方客户端 gRPC/媒体主路径
        BAHookCronet();
        NSLog(@"[BiliAcc] loaded, proxy on 127.0.0.1:%ld, mode=%@, target=%@, lanes=%ld, verbose=%d",
              (long)BAProxyPort(), BAMode(), BATargetHost(), (long)BAConcurrency(), BAVerbose());
    }
}

