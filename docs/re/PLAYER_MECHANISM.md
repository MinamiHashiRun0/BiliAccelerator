# Bilibili iOS 客户端播放器机制（本地逆向结论）

> 分析方法：runtime ObjC metadata dump（`SIMCTL_CHILD_BiliAcc_dump=IJKMedia,...` 注入 dylib，
> 模拟器内导出 138 个类的完整方法/属性表 → `docs/re/dump_*.txt`）+ 主二进制字符串分析。
> 全程离线，不消耗真机测试轮次。

## 1. 播放引擎拓扑

| 类 | 角色 |
|---|---|
| `IJKFFMoviePlayerControllerFFPlay` | **真正的 FFmpeg 引擎**（dash 播放的实际执行者），持有 5 个 URL-open delegate |
| `IJKFFMoviePlayerControllerAVPlayer` | AVPlayer 后备引擎（27 属性/88 方法），诊断证实 dash 播放时只开 `blank.mp4` 占位 |
| `IJKMediaAsset` | 资产聚合：`streams` 数组 + `defaultVideoStreamIdentifer` / `defaultAudioStreamIdentifer` |
| `IJKMediaAssetStream` | 单条流：`identifer`/`streamType`(音视频)/`codecType`/`segments`(NSMutableArray)/`bandwidth`/`targetQn` |
| `IJKMediaAssetStreamSegment` | 分段：`url`(NSString)/`backupUrls`(NSArray)/`size`(Q, unsigned!)/`duration` |
| `IJKMediaUrlOpenData` | **URL 打开事件的运行时对象**（见下） |
| `StreamInfo`（App 层） | `videoUrl`/`audioUrl`/codec 等媒体描述（probe/统计用） |

## 2. URL 消费通道（关键发现）

`IJKMediaUrlOpenDelegate` 协议，唯一回调方法 **`ijkUrlChange:`**，参数 `IJKMediaUrlOpenData`：

- 属性：`url`（可写！）、`urlChanged`（写回标志）、`isAudio`、`segmentIndex`、`retryCounter`、
  `filesize`、`httpError`/`httpCode`、`fd`
- 五类 delegate 挂在 FFPlay 控制器上：`fileOpenDelegate` / **`segmentOpenDelegate`** /
  `httpOpenDelegate` / `liveOpenDelegate` / `tcpOpenDelegate`
- B 站自研协议栈（`ijksegment/ijktcphook/ijkp2p/ijknetwork/ijkurlhook/...`）
  在 C 层触发这些 ObjC 回调；**delegate 改写 `url` + `urlChanged=YES` 即重定向**——
  B 站自己的 P2P 层就是这么接的

**含义**：这是播放器消费 URL 的唯一必经点。之前的 reply 树改写依赖"改写先于 resolver
拷贝"的时序（模拟器成立，真机不成立）。正确的接入层是 delegate——用 NSProxy 风格的
wrapper 包住 App 原始 delegate，在 `ijkUrlChange:` 里改写 URL 再转发。

## 3. 播放器读模式（日志实测）

- dash 分段按**分段边界**顺序读：stride 不等长（45KB / 85KB / 198KB / 685KB）
- 起始阶段会做 64KB 头部探测 + moov/index 跳读（4K 时出现 33MB/42MB/61MB 大偏移探测）
- **同尺寸固定预取必然脱靶** → 必须用**对齐块缓存**（任意 offset 顺序读可命中）

## 4. dylib 对应实现

| 层 | 实现 |
|---|---|
| URL 打开层 | wrapper `BAIJKOpenDelegateWrap`：swizzle FFPlay 控制器的 `setSegmentOpenDelegate:/setHttpOpenDelegate:/setFileOpenDelegate:`（live/tcp 跳过——直播保护），在 `ijkUrlChange:` 中改写媒体 URL（音频 `isAudio==YES` 剪枝，已代理 URL 幂等跳过） |
| 流式缓存 | 256KB 对齐块缓存（`serveRange` 跨块拼装，块内偏移校验），serve 后后台预取后 2 块；上限 192 块 ≈48MB |
| 花屏防护 | 上游每路 Range 响应校验 `Content-Range` 起始偏移 == 请求偏移；不符/缺失即丢弃换镜像重试 |
| 并发 | 窗口 ≥384KB → 6 路均分并发；小窗口走块缓存路径 |
| 失效切换 | fetchRange 每路 15s 超时，失败自动换备用镜像（签名与主机无关） |

## 5. 环境差异记录

- 模拟器（`platform 2→7` 转换）：可完整验证注入→改写→代理→流式播放；
  **播放开始渲染时崩溃**（转换版二进制的设备专用 API 缺失，与 dylib 无关——
  禁用 dylib 复现同一栈）。
- 真机：地面真值。07:02 构建（protocolClasses 清空 + Content-Range 总长）后
  播放器正常连接代理、Range 推进、音频豁免。

## 6. dump 文件索引

`docs/re/dump_IJKMediaAsset.txt`、`dump_IJKMediaAssetStream.txt`、
`dump_IJKMediaAssetStreamSegment.txt`、`dump_IJKMediaUrlOpenData.txt`、
`dump_IJKFFMoviePlayerControllerFFPlay.txt`、`dump_IJKFFMoviePlayerControllerAVPlayer.txt`、
`dump_StreamInfo.txt` 等 138 个（由 runtime dump 生成）。
