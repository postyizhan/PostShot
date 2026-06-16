# PostShot v2 — 全屏录制长截图 实施规格 (SPEC v2)

> v2 目标:从"拼图"(手动截 N 张再选)升级为"真·长截图"(连续滚一次,自动抓帧拼接)。
> 本文件是 v2 的事实来源,接续 SPEC.md。
>
> **进度状态(2026-06-16 更新)**:Phase 0 冒烟**真机验证通过** ✅——socket 桥在免费签名 + 扩展
> 沙盒下确认能连通。v2 最大未知数(传输路线)已消除,**不再需要回退网页方案**。
> **Phase 1(真实帧采集:协议分帧 + FrameSelector 筛选 + PNG 传输)和 Phase 2(拼接接线:采集帧
> 复用 v1 审阅/拼接/预览流程)代码已完成、CI 绿**。剩余为**真机端到端实测**:录一次滚动 → 确认
> 采集到稀疏关键帧且扩展不被 50MB 杀 → 去拼接 → 删首尾垃圾帧 → 得到一张连续长图。
> **传输路线为本地回环 socket**(原因见 §0),App Group 方案作为历史保留在 §7。

## 0. 背景与硬约束

- **核心升级**:用 **ReplayKit Broadcast Upload Extension** 做系统级全屏录制。用户在任意 App
  (微信/网页/列表)里连续滚动一遍,扩展自动抓帧 → 跨进程传给主 App → 复用 v1 拼接后端
  → 输出一张长图。
- **iOS 硬限制(务必明确)**:iOS **不允许**任何 App 自动滚动别的 App(无越狱无此 API)。
  所以滚动动作仍由用户手指完成,v2 只是把"抓帧"自动化。这是 iOS 跨 App 长截图的能力上限。
- **拼接后端完全复用**:`OverlapDetector`(NCC)、`ImageCompositor`(硬拼接)、`StitchEngine`、
  `PixelBuffer` 全部不动,已被单测证明正确。v2 = 新增"采集层",产出 `[CGImage]` 喂给现有后端。
- **v1 后处理 UI 完全复用**:采集得到的帧 → 进 v1 的缩略图条(可删除首尾垃圾帧/状态栏帧)→
  拼接 → 预览 → 保存/分享。v1 的整套 picker→strip→stitch→preview 变成 v2 的"采集后审阅"流程。
- **关键风险(已转向)**:扩展原计划用 **App Groups** 共享磁盘传帧,但实测**免费 Apple ID 侧载下
  App Group 容器不可用**(CaptureView 诊断证明 container 为 nil,见 commit `834312b`)。
  因此 v2 改用**本地回环 TCP socket**(`127.0.0.1:52890`)跨进程传帧:主 App 跑 `NWListener`
  监听,扩展作为客户端连上并流式发送。新的最大未知数变成:**socket 桥在免费签名 + 扩展沙盒下能否
  连通**——必须最先真机验证(见 Phase 0),否则全屏录制路线仍在侧载层被卡死。

## 1. 目标架构

```
PostShot (主 App)
├── [复用] 拼接后端:OverlapDetector / ImageCompositor / StitchEngine / PixelBuffer
├── [复用] 后处理 UI:ThumbnailStrip / PreviewView / PhotoSaver / ImageExporter
├── [新增] CaptureView:开始/停止录制引导(RPSystemBroadcastPickerView)、采集后跳转审阅
└── [新增] FrameBridgeServer:NWListener 监听 127.0.0.1,接收扩展流过来的帧

PostShotBroadcast (新增:Broadcast Upload Extension target)
├── SampleHandler:接收 CMSampleBuffer 全屏帧
├── FrameSelector:决定保留哪些帧(去静止重复帧、限制总数、内存安全)— 已实现 §3
└── FrameBridgeClient:连主 App 的 NWListener,保留帧即时编码后流式发送,绝不在内存累积

Shared (主 App 与扩展共享源码)
├── FrameBridge:双方约定的 host/port 常量(127.0.0.1:52890)
└── FrameSelector:粗筛纯算法 + Engine 状态机(同时供主 App 与扩展)
```

> **传输路线说明**:原设计(下方 §4 yaml 仍保留)走 App Group 共享磁盘——扩展写盘、主 App 读盘。
> 因免费签名下 App Group 容器为 nil,改为 socket 桥:扩展不写盘,保留帧直接编码后通过
> `127.0.0.1` TCP 流给主 App,主 App 在内存重组帧序列再喂拼接后端。`FrameStore` 读写组件
> 不再需要,由 `FrameBridgeServer`/`FrameBridgeClient` 取代。

## 2. 内存铁律(决定整个采集层设计)

- Broadcast Upload Extension 有 **~50MB 常驻内存硬上限**,超了系统直接杀进程。这是 v2 第一约束。
- 因此:**绝不在扩展里累积全分辨率帧,也不在扩展里拼接**。每帧流程:
  收到 CMSampleBuffer → 降采样做廉价比较(FrameSelector) → 若保留则全分辨率编码 →
  立即通过 socket 发出并释放 → 常驻内存只维持 1~2 帧。
- 拼接放在**主 App**(无内存上限)在录制结束后做,从 socket 收齐的帧序列里取。
- 编码格式:全分辨率 PNG(文字清晰,无 JPEG 伪影);只对**保留帧**编码,跳过帧不编码。
  socket 传输按"长度前缀 + PNG 字节流"分帧,主 App 端按前缀重组。

## 3. FrameSelector(v2 唯一的新算法)— ✅ 已实现 (`Shared/FrameSelector.swift`)

目标:把 30~60fps 的视频流,降成"内容推进、互有重叠、可拼接"的稀疏关键帧序列。

v2 首版采用**最简稳健策略**(精确重叠交给现有 OverlapDetector,FrameSelector 只做粗筛)。
**实现要点**(决策核心 `decide()` 是纯函数,签名 `[Float]` + 时间戳 → 保留/跳过,放在 `Shared/`
同时供主 App 与扩展;`Engine` 是其上的薄状态机供单线程 SampleHandler 调用):

1. 每来一帧 → 降采样成小灰度签名(复用 PixelBuffer 思路,如 64 宽)。**注**:签名提取
   (CMSampleBuffer→降采样)与图像管线耦合,留待 Phase 1 接线;`decide()` 只吃签名,不碰像素。
2. 与**上一保留帧**签名比较,用**逐样本平均绝对差(meanAbsDiff)**作变化度量:
   - `< duplicateThreshold`(默认 0.012)→ 手指静止/重复帧 → 跳过(`skipDuplicate`)。
   - `>= changeThreshold`(默认 0.05)且过了最小间隔 → 内容推进足够 → 保留(`keep`)。
   - 介于两者之间 → 抖动/微动 → 跳过(`skipMinorChange`)。
3. 设最小时间间隔(`minInterval` 默认 0.3s)防抖;超出则即便变化大也先节流(`skipThrottled`)。
4. 设保留帧总数上限(`maxFrames` 默认 60)兜底内存/耗时;触顶后丢弃(`skipCapped`)。
5. 首尾可能是 PostShot 自身/桌面/切换动画的垃圾帧 → 不在扩展里硬判,交给采集后的缩略图条
   让用户手动删(复用 v1 已有能力)。

> 已通过合成滚动序列单测(`Tests/FrameSelectorTests.swift`):静止帧坍缩成 1 帧、滚动产生稀疏
> 关键帧、节流与总数上限生效。阈值为保守首版值,需用真实滚动在 Phase 3 调优。

> 进阶(v2.x,非首版):基于滚动位移精确控制保留间隔、运动模糊检测优选清晰帧、状态栏/录制红条
> 自动裁剪。首版先用"内容差异 + 手动审阅"跑通。

## 4. project.yml 改动

> ⚠️ **以下 App Group 配置为原始设计,现已不采用**(免费签名下 App Group 不可用,见 §0)。
> 当前 `project.yml` 的扩展 target 不含 `application-groups` entitlement,改靠 `Shared/` 源码
> 共享 + 运行时 socket 通信。保留此节记录原计划与扩展 target 的基础结构(后者仍有效)。

新增扩展 target(仍需)与 App Group 权限(已弃用):

```yaml
targets:
  PostShot:
    dependencies:
      - target: PostShotBroadcast      # 主 App 内嵌扩展
    entitlements:
      path: Sources/PostShot.entitlements
      properties:
        com.apple.security.application-groups: [group.com.postshot.app]
    # 主 App 也需共享 Shared/ 源码

  PostShotBroadcast:
    type: app-extension
    platform: iOS
    sources: [BroadcastExtension, Shared]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.postshot.app.broadcast
        INFOPLIST_FILE: BroadcastExtension/Info.plist
    entitlements:
      path: BroadcastExtension/PostShotBroadcast.entitlements
      properties:
        com.apple.security.application-groups: [group.com.postshot.app]
```

扩展 Info.plist 关键键:
- `NSExtensionPointIdentifier = com.apple.broadcast-services-upload`
- `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).SampleHandler`
- `RPBroadcastProcessMode = RPBroadcastProcessModeSampleBuffer`

## 5. 实施阶段(按风险排序,先验证侧载再做算法)

### Phase 0 — 侧载冒烟测试(最高优先,先验证再投入)— ✅ 真机验证通过

- project.yml 加 `PostShotBroadcast` 扩展(App Group 原计划已弃用,见 §4)。
- **(已转向)** 原计划:扩展写 1 张帧到 App Group,主 App 读出显示"已收到 N 帧"。因 App Group
  容器为 nil 改为 **socket 文本冒烟**:扩展每 10 帧通过 `127.0.0.1:52890` 发一条文本(`frame N`),
  主 App 的 `FrameBridgeServer` 监听计数,`CaptureView` 显示"收到消息 N"。
- **唯一目标**:确认 (a) CI 能构建带扩展的工程 ✅;(b) 爱思能在免费账号上签名安装它(待验);
  (c) **扩展→主 App 的 socket 通道在免费签名 + 扩展沙盒下能否连通(最大未知数,真机待验)**。
- **测试协议**:录制时保持 PostShot 在前台「录制」tab(别切走),隔离 socket 桥本身,
  把背景存活当作另一个独立问题。
- **若 socket 也不通**:全屏录制路线在侧载层被卡。回退到"App 内置浏览器仅网页长截图"零风险方案。
- 这一步必须在做任何采集集成前跑通——CI+爱思+装机循环很慢,先把最大未知数消掉。

### Phase 1 — 帧采集与筛选 — ✅ 代码完成/CI 绿 / 🟡 真机实测待做

- ✅ `FrameSelector` + `Engine`(粗筛纯算法,§3)已实现并通过单测。
- ✅ `FrameProtocol`(类型+长度前缀二进制分帧)+ 流式 Decoder,带完整单测(往返/逐字节分块/
  单块多消息/半截/空载荷/错误)。socket 桥从发文本升级为发真实帧。
- ✅ `FrameEncoder`:CVPixelBuffer → 64×64 灰度签名(廉价,每帧)/ → 全分辨率 PNG(仅保留帧)。
- ✅ `SampleHandler`:每帧提签名 → FrameSelector 筛选 → 仅保留帧编码 PNG → socket 发出 →
  立即释放。常驻 ~1 帧,遵守 50MB 内存铁律。
- 🟡 待真机实测:滚一屏看到的应是「几张稀疏关键帧」而非几百张,且扩展不被系统杀。
- ✅ 单测:合成"滚动序列"验证 FrameSelector;FrameProtocol 分帧往返/分块。

### Phase 2 — 拼接接线 — ✅ 代码完成/CI 绿 / 🟡 真机端到端待做
- ✅ 主 App:录制结束后从 socket 收齐保留帧(PNG)→ `StitchViewModel.load(pngFrames:)`
  复用 `ImageDecoder.decode` 解码 → 复用 `StitchEngine` → 复用 `PreviewView`。
- ✅ 复用 v1 审阅流程:抽出共享 `StitchReviewView`(缩略图条删垃圾帧 + 裁剪 + 拼接 + 预览),
  ContentView(PhotosPicker)与 CaptureReviewView(采集)共用,消除重复。
- ✅ 复用 PhotoSaver / ImageExporter 保存分享(PreviewView 内已接)。
- 🟡 待真机端到端:录一次 → 去拼接 → 删首尾垃圾帧 → 得到一张连续长图。

### Phase 3 — 采集 UX 与健壮性
- CaptureView:RPSystemBroadcastPickerView 从 App 内启动录制 + 引导文案("缓慢滚动")。
- 采集后跳 v1 缩略图条审阅(删垃圾帧)→ 拼接。
- 状态栏时钟/录制红条处理(复用 v1 手动裁剪;自动裁剪列为 v2.x)。
- 用真实滚动调 FrameSelector 阈值。

### Phase 4 — 文档与收尾
- README v2 段落:全屏录制使用流程、能拍什么、已知限制(不能自动滚、需手指滚一遍)。
- 更新已知风险。

## 6. 验收标准

- Phase 0:带扩展的 ipa 能经爱思签名安装,录制时扩展能通过 socket 把消息送达主 App
  (`CaptureView` 的"收到消息"计数随录制增长)。
- 在微信聊天里开录 → 缓慢滚一屏内容 → 停止 → 自动得到一张内容连续、无重复、无可见接缝的长图。
- 扩展全程常驻内存不超 50MB,不被系统杀。
- 采集帧为全分辨率,长图清晰度与原屏一致。

## 7. 已知风险

- **socket 桥 + 免费签名 + 扩展沙盒(当前最大风险)**:扩展进程能否在免费签名下连上主 App 的
  loopback NWListener,Phase 0 真机专门验证。`local-networking` 权限、扩展沙盒对 loopback 的
  限制都是未知数。**若不通则回退网页长截图方案**。
- **App Group + 免费签名(已踩坑,转向原因)**:免费签名下容器为 nil,已弃用,改 socket。
- **背景存活**:socket 桥要求主 App 监听存活。Phase 0 先要求主 App 前台隔离桥本身;扩展在
  主 App 切后台时能否维持连接是独立的后续问题。
- **50MB 扩展内存上限**:靠"只编码发送不累积"规避,需实测确认不被杀。
- **录制红条/状态栏**:进入抓帧画面,首版靠手动裁剪 + 审阅删帧规避。
- **快速滑动模糊**:首版靠引导用户慢滚 + 稳定性粗筛;精细优选列为 v2.x。
- **iOS 不能自动滚动**:这是能力上限,非缺陷;README 明确告知用户需手指滚一遍。
