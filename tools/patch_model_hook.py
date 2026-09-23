# -*- coding: utf-8 -*-
"""在 Tweak.m 中插入 gRPC model hook 段（initWithData:extensionRegistry:error:）"""
import io

path = "src/Tweak.m"
src = io.open(path, encoding="utf-8").read()

marker = "static NSURLSessionDataTask * (*BAOrigDataTask)"
idx = src.find(marker)
assert idx != -1

hook_block = u'''#pragma mark - Hook：gRPC 反序列化 ObjC model（正确的拦截点）

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

// KVC 安全读：依次尝试多个键名
static id BAValueForKeys(id obj, NSArray<NSString *> *keys) {
    for (NSString *k in keys) {
        @try {
            id v = [obj valueForKey:k];
            if (v) return v;
        } @catch (NSException *e) { (void)e; }
    }
    return nil;
}

// 对单个 Dash 条目（DashItem/DashVideo/ResponseUrl）改写 URL 属性
static void BARewriteDashEntry(id entry) {
    if (!entry || ![entry respondsToSelector:@selector(valueForKey:)]) return;
    for (NSString *k in @[ @"baseUrl", @"base_url", @"url" ]) {
        @try {
            id val = [entry valueForKey:k];
            if (![val isKindOfClass:[NSString class]]) continue;
            NSString *reason = nil;
            NSString *next = BARewriteUrlDetail(val, &reason);
            if (![next isEqualToString:val]) {
                [entry setValue:next forKey:k];
                BALog(@"model-rewrite %@ [%@]", k, reason ?: @"?");
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

// 遍历 streamList（新接口 VodInfo）：只碰 dashVideo/segmentVideo，不碰 dashAudio/dolby
static void BARewriteVodInfo(id vodInfo) {
    if (!vodInfo) return;
    id streams = BAValueForKeys(vodInfo, @[ @"streamList", @"stream_list" ]);
    if (![streams isKindOfClass:[NSArray class]]) return;
    for (id stream in streams) {
        if (![stream respondsToSelector:@selector(valueForKey:)]) continue;
        // Stream: dashVideo 或 segmentVideo（oneof）—— 视频，改
        id dashVideo = BAValueForKeys(stream, @[ @"dashVideo", @"dash_video" ]);
        if (dashVideo) BARewriteDashEntry(dashVideo);
        id seg = BAValueForKeys(stream, @[ @"segmentVideo", @"segment_video" ]);
        if ([seg respondsToSelector:@selector(valueForKey:)]) {
            id items = BAValueForKeys(seg, @[ @"segment", @"segments" ]);
            if ([items isKindOfClass:[NSArray class]]) {
                for (id item in items) BARewriteDashEntry(item);
            }
        }
        // streamInfo/stream_info 不含 URL，跳过
    }
    // dashAudio / dolby / lossLessItem —— 音频流，绝不碰（故意不写代码）
}

// 遍历 VideoInfo（老接口）：durl + dash.video，不碰 dash.audio
static void BARewriteVideoInfo(id videoInfo) {
    if (!videoInfo) return;
    id durl = BAValueForKeys(videoInfo, @[ @"durl" ]);
    if ([durl isKindOfClass:[NSArray class]]) {
        for (id item in durl) BARewriteDashEntry(item);
    }
    id dash = BAValueForKeys(videoInfo, @[ @"dash" ]);
    if (dash) {
        id videos = BAValueForKeys(dash, @[ @"video" ]);
        if ([videos isKindOfClass:[NSArray class]]) {
            for (id item in videos) BARewriteDashEntry(item);
        }
        // dash.audio 绝不碰
    }
}

// 拦截 PlayViewUniteReply 反序列化
static void (*BAOrigPVUInit)(id, SEL, id, id, id *);
static id BAHookPVUInit(id self, SEL _cmd, id data, id registry, id *error) {
    id ret = BAOrigPVUInit(self, _cmd, data, registry, error);
    if (BAEnabled() && ret) {
        @try {
            id vod = BAValueForKeys(ret, @[ @"vodInfo", @"vod_info" ]);
            if (vod) BARewriteVodInfo(vod);
        } @catch (NSException *e) {
            NSLog(@"[BiliAcc] PVU rewrite error: %@", e);
        }
    }
    return ret;
}

// 拦截 PlayViewReply（老接口）反序列化
static void (*BAOrigPVInit)(id, SEL, id, id, id *);
static id BAHookPVInit(id self, SEL _cmd, id data, id registry, id *error) {
    id ret = BAOrigPVInit(self, _cmd, data, registry, error);
    if (BAEnabled() && ret) {
        @try {
            id vi = BAValueForKeys(ret, @[ @"videoInfo", @"video_info" ]);
            if (vi) BARewriteVideoInfo(vi);
        } @catch (NSException *e) {
            NSLog(@"[BiliAcc] PV rewrite error: %@", e);
        }
    }
    return ret;
}

// 类名变体搜索：moss 生成器前缀可能是 BAPIApp / BApi / 无前缀
static Class BAFindReplyClass(NSArray<NSString *> *candidates) {
    for (NSString *name in candidates) {
        Class c = objc_getClass(name.UTF8String);
        if (c) {
            NSLog(@"[BiliAcc] found reply class: %@", name);
            return c;
        }
    }
    return nil;
}

static void BAHookGrpcModels(void) {
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
            BAOrigPVUInit = (void (*)(id, SEL, id, id, id *))method_getImplementation(m);
            method_setImplementation(m, (IMP)BAHookPVUInit);
            NSLog(@"[BiliAcc] hooked PlayViewUniteReply initWithData");
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
            BAOrigPVInit = (void (*)(id, SEL, id, id, id *))method_getImplementation(m);
            method_setImplementation(m, (IMP)BAHookPVInit);
            NSLog(@"[BiliAcc] hooked PlayViewReply initWithData");
        }
    }

    if (!pvu && !pv) {
        // 都没找到：枚举所有类名含 PlayViewUnite 的类帮助诊断
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
        NSLog(@"[BiliAcc] no known reply class found; candidates: %@", hits);
    }
}

'''

src = src[:idx] + hook_block + src[idx:]
io.open(path, "w", encoding="utf-8", newline="\n").write(src)
print("OK")
