# -*- coding: utf-8 -*-
"""运行时属性树递归改写（替代手写死属性路径）。
依据反编译事实（9.12.0 脱壳包）：
- 播放链路 gRPC→GPB reply→BBResolver→IJKMediaAsset（FFmpeg/IJK 内核）
- URL 属性名证据：baseUrl/backupUrl/backupUrls/backUrl/playURL/playUrl/videoUrl/segments
- 音频标志：isAudio；音频属性名族：*audio*/*dolby*/*lossless*
- resolver 有 onAssetUpdate URL 回送机制，改 URL 是官方认可的失效恢复路径"""
import io

path = "src/Tweak.m"
src = io.open(path, encoding="utf-8").read()

# 在 BAHookPVUInit 之前插入通用运行时改写器，并替换 PVU/PV hook 的改写调用
start = src.find("// 拦截 PlayViewUniteReply 反序列化")
assert start != -1

new_block = u'''#pragma mark - 运行时属性树递归改写（结构感知，零属性名猜测）

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
    NSString *next = BARewriteUrlDetail(s, &reason);
    // 并发代理包装
    if (BAConcurrency() > 1 && ![next hasPrefix:@"http://127.0.0.1"]) {
        next = [NSString stringWithFormat:@"http://127.0.0.1:%ld/seg?u=%@",
            (long)BAProxyPort(),
            [next stringByAddingPercentEncodingWithAllowedCharacters:
                       [[NSCharacterSet alphanumericCharacterSet] invertedSet]]];
    }
    if ([next isEqualToString:s]) return nil;
    return next;
}

// 递归遍历对象属性树，改写所有媒体 URL。excludes 防御环形引用。
static void BADeepRewrite(id obj, NSString *keyPath, int depth, NSMutableSet *seen) {
    if (depth > 8 || !obj || seen.contains(obj)) return;
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
                        BAEssentialLog(@"rt-rewrite %@: %@",
                            childPath, [next substringToIndex:MIN((NSUInteger)90, next.length)]);
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
            BAOrigPVUInit = (id (*)(id, SEL, id, id, id *))method_getImplementation(m);
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
            BAOrigPVInit = (id (*)(id, SEL, id, id, id *))method_getImplementation(m);
            method_setImplementation(m, (IMP)BAHookPVInit);
            NSLog(@"[BiliAcc] hooked PlayViewReply initWithData");
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
        NSLog(@"[BiliAcc] no known reply class found; candidates: %@", hits);
    }
}

'''

src = src[:start] + new_block + src[start:].split("// 类名变体搜索", 1)[0] if False else src
# 上面一行无操作；真正替换：找到旧 PVU hook 起点到 BAHookGrpcModels 结束，整体换新块
start_old = src.find("// 拦截 PlayViewUniteReply 反序列化")
end_old = src.find("static NSURLSessionDataTask * (*BAOrigDataTask)")
assert start_old != -1 and end_old != -1 and start_old < end_old
src = src[:start_old] + new_block + src[end_old:]

io.open(path, "w", encoding="utf-8", newline="\n").write(src)
print("OK: runtime deep rewrite installed")
