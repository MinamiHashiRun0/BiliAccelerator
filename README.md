# BiliAccelerator.dylib — Bilibili iOS 官方客户端免越狱加速

移植自 [realzza/bilibili-accelerator](https://github.com/realzza/bilibili-accelerator) v0.4.1（MIT）的
CDN 主机判定/改写规则，做成注入 Bilibili iOS 官方客户端的 dylib：

- **视频流（dash.video）**：慢速 PCDN/MCDN 主机 → UPOS 镜像主机改写 + 本地多连接 Range 并发下载
- **音频流（dash.audio）**：**完全原样不动**（按你的要求）
- 直播（`/live-bvc/`）一律跳过，防止播放中断

## 原理

### 1. 主机改写（移植参考项目 `classify()` / `rewriteUrlDetail()`）

判定规则与参考项目逐条对应：

| 信号 | 来源 | 处理 |
|---|---|---|
| IP 直连主机 | `classify()` ipLike | → 改写到目标 UPOS 镜像 |
| `xy..xy.mcdn.bilivideo.cn/com/net` | XY_MCDN_RE | → 本地代理透传 |
| 非标端口（非 80/443） | port heuristic | → 改写 |
| query 含 `os=mcdn` | hasMcdnQuery | → 改写 |
| `.szbdyd.com` / `.mountaintoys.cn` / `.nexusedgeio.com` / `.ahdohpiechei.com` | KNOWN_P2P | → 改写 |
| `upos-*-302*` 首段含 302 | 302 落点 P2P | → 改写 |
| `upos-sz-mirror14b.bilivideo.com` | KNOWN_P2P_HOSTS | → 改写 |
| `.szbdyd.com` 带参数 `xy_usource=` | schedulerSource | → 换回真实源站 |

默认目标主机 `upos-sz-mirrorcosov.bilivideo.com`（海外镜像，与参考项目默认一致）。
候选池同参考项目 `CANDIDATE_POOL` 全量 8 主机，可通过 __偏好__ 换目标。

**注意**：与参考项目一样，港澳台/海外 ov 镜像（`mirrorcosov` 等）不算 slow——它们本来就是地理上最快的，
改写它们反而变慢。`force` 模式强制改写所有 B 站 CDN 主机，但多数情况 `bad-only` 即可。

### 并发下载（相较于参考项目新增的部分）

播放器请求视频分片时改写为 `http://127.0.0.1:<port>/seg?u=<真实URL>`，
本地 HTTP 服务器在进程内完成：

```
播放器 ─┐
        ├─ /seg 应用层 ─┬─ Range #1 (lane1)
        │              ├─ Range #2 (lane2)  →  N 路并发，每路独立 NSURLSession
        │              └─ Range ...
        └─ 拼接后按序返回 200
```

- 并发路数默认 6（1–16 可调）
- 每段默认 4MB（1–64 可调），任一段失败 → HTTP 502 → 播放器自动 fallback 到 backupUrl
- AUDIO 永远不进入这个代理（JSON 遍历只碰 `dash.video`/`durl`）
- 服务器只监听 `127.0.0.1`，无对外暴露

### Hook 点

- `NSURLSession dataTaskWithRequest:completionHandler:` —— 官方客户端的 gRPC
  （`PlayViewUnite` / `PlayView`）/ `playurl` 响应在这里改写 protobuf。
  protobuf string 字段是 `varint 长度 + 字节`，改写后同步重建长度前缀。

## 构建（无需本地 Mac）

推到 GitHub 之后 Actions 会自动产出 `BiliAccelerator.dylib`（arm64 iOS，ios13+）：

### 本地 Mac 一键构建（推荐）

有 Xcode 的 Mac 上一条命令完成：编译 dylib → 注入 IPA → 产出 Mac 直跑 App：

```bash
./tools/mac_repack.sh            # 默认 ../哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa
./tools/mac_repack.sh <ipa路径>   # 指定脱壳 IPA
```

产物：
- `build/bili-universal-accelerated.ipa` — 设备侧载用（侧载工具负责重签）
- `build/mac-run/<App>.app` — Apple Silicon Mac 直接运行用（ad-hoc 重签 + lldb 权限）

**Mac 直跑调试闭环**（比模拟器快得多——模拟器无法加载设备版 IPA）：

```bash
# 直接从终端启动主二进制，环境变量即时调参（无需重签/重装）
BiliAcc_verbose=1 BiliAcc_mode=force \
  /Applications/bili-universal.app/bili-universal
```

配置优先级：**环境变量 > CFPreferences > 默认值**（环境变量仅用于调试）。

### CI 云端编译（无 Mac 时）

1. 推送本仓库，或手动触发 `build-dylib` workflow
2. 从 Actions artifact 下载 `BiliAccelerator.dylib`

或在任何 Mac / CI 环境（macos-14 runner）手动编译：

```bash
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=13.0 \
  -shared -fobjc-arc -O2 -framework Foundation \
  -o BiliAccelerator.dylib src/Tweak.m
ldid -S BiliAccelerator.dylib        # 假签名，免越狱侧载必需
```

## 打包 IPA（需要一份"脱壳"的 Bilibili IPA）

> App Store 下载的 IPA 加密（cryptid=1），无法注入。需要通过
> dumpdecrypted / frida-ios-dump / 破解源等方式拿到脱壳 IPA。

```bash
python tools/repack.py bilibili.decrypted.ipa BiliAccelerator.dylib -o bilibili.accelerated.ipa
```

`repack.py` 内部做三件事：
1. 校验 Mach-O 未加密
2. `inject_dylib.py` 注入 `LC_LOAD_WEAK_DYLIB`（`@rpath/BiliAccelerator.dylib`）
3. dylib 拷贝进 `<App>.app/Frameworks/` 并重新 zip

## 侧载

### TrollStore（推荐，最省事）

1. TrollStore 安装 `bilibili.accelerated.ipa`（TrollStore 会自动假签，包括 dylib）
2. 直接启动

### AltStore / Sideloadly（7 天证书）

1. 先用 Sideloadly 装入
2. 若启动闪退，通常是证书没有 `get-task-allow` 以外的权限缺口 ——
   在 entitlements 中确保 `application-identifier` 与主 App 一致即可

### 偏好配置（可选）

`CFPreferences`（domain `tv.danmaku.bilibili`）可覆盖默认值。越狱改
`/var/mobile/Library/Preferences/tv.danmaku.bilibili.plist`；TrollStore 场景可用
`defaults` 域写入或先用默认值跑起来再说：

| 键 | 默认 | 含义 |
|---|---|---|
| `BiliAcc_enabled` | `YES` | 总开关 |
| `BiliAcc_mode` | `bad-only` | `bad-only` / `force` / `off` |
| `BiliAcc_targetHost` | `upos-sz-mirrorcosov.bilivideo.com` | 重写目标镜像 |
| `BiliAcc_concurrency` | `6` | 视频流并发连接数 (1–16) |
| `BiliAcc_chunkMB` | `4` | 并发分段大小 MB (1–64) |
| `BiliAcc_proxyPort` | `54321` | 本地代理端口 |

## 已知限制 / 排查

- **官方客户端升级后失效**：gRPC 字段布局/URL 位置变了的话，protobuf 扫描可能匹配不上。
  老 `playurl` JSON 接口走的是 `BARewriteJsonPayload`，同样有兜底，但当前版本没把它接进 XHR 拦截
  （官方客户端几乎全走 gRPC）。
- **启动闪退**：LC_LOAD_WEAK_DYLIB 若 dylib 路径错误会静默不加载而不是闪退；
  若闪退检查是否把 dylib 放进了 `<App>.app/Frameworks/`。
- **日志**：Console.app 过滤 `[BiliAcc]` 可看启动配置与改写日志。
- **内存占用**：并发全量分段（4MB × N 段累积）峰值内存约等于视频文件大小，官方客户端
  播放器按需增量请求，实际一次 `/seg` 只拉一个 4MB 分段，占用可控。

## License

MIT（与参考项目一致）。源码中的主机判定/改写规则移植自
[realzza/bilibili-accelerator](https://github.com/realzza/bilibili-accelerator) v0.4.1。
