# PostShot v2 — 全屏录制长截图 实施规格 (SPEC v2)

> v2 目标:从"拼图"(手动截 N 张再选)升级为"真·长截图"(连续滚一次,自动抓帧拼接)。
> 本文件是 v2 的事实来源,接续 SPEC.md。

## 0. 背景与硬约束

- **核心升级**:用 **ReplayKit Broadcast Upload Extension** 做系统级全屏录制。用户在任意 App
  (微信/网页/列表)里连续滚动一遍,扩展自动抓帧 → 写入共享容器 → 主 App 读取 → 复用 v1 拼接后端
  → 输出一张长图。
- **iOS 硬限制(务必明确)**:iOS **不允许**任何 App 自动滚动别的 App(无越狱无此 API)。
  所以滚动动作仍由用户手指完成,v2 只是把"抓帧"自动化。这是 iOS 跨 App 长截图的能力上限。
- **拼接后端完全复用**:`OverlapDetector`(NCC)、`ImageCompositor`(硬拼接)、`StitchEngine`、
  `PixelBuffer` 全部不动,已被单测证明正确。v2 = 新增"采集层",产出 `[CGImage]` 喂给现有后端。
- **v1 后处理 UI 完全复用**:采集得到的帧 → 进 v1 的缩略图条(可删除首尾垃圾帧/状态栏帧)→
  拼接 → 预览 → 保存/分享。v1 的整套 picker→strip→stitch→preview 变成 v2 的"采集后审阅"流程。
- **关键风险**:扩展需要 **App Groups 权限**。免费 Apple ID + 爱思签名能否成功安装"带扩展 +
  App Group 的 App"是最大未知数。必须最先验证(见 Phase 0),否则整条全屏录制路线在侧载层被卡死。

## 1. 目标架构

```
PostShot (主 App)
├── [复用] 拼接后端:OverlapDetector / ImageCompositor / StitchEngine / PixelBuffer
├── [复用] 后处理 UI:ThumbnailStrip / PreviewView / PhotoSaver / ImageExporter
├── [新增] CaptureView:开始/停止录制引导(RPSystemBroadcastPickerView)、采集后跳转审阅
└── [新增] FrameStore(读):从 App Group 容器读取扩展写入的帧

PostShotBroadcast (新增:Broadcast Upload Extension target)
├── SampleHandler:接收 CMSampleBuffer 全屏帧
├── FrameSelector:决定保留哪些帧(去静止重复帧、限制总数、内存安全)
└── FrameStore(写):保留帧即时编码写入 App Group 磁盘,绝不在内存累积(50MB 硬上限)

Shared (新增:主 App 与扩展共享)
├── AppGroup 常量(group id、目录路径)
└── FrameStore 帧存取格式与 IO
```

## 2. 内存铁律(决定整个采集层设计)

- Broadcast Upload Extension 有 **~50MB 常驻内存硬上限**,超了系统直接杀进程。这是 v2 第一约束。
- 因此:**绝不在扩展里累积全分辨率帧,也不在扩展里拼接**。每帧流程:
  收到 CMSampleBuffer → 降采样做廉价比较 → 若保留则全分辨率编码 → 立即写盘释放 →
  常驻内存只维持 1~2 帧。
- 拼接放在**主 App**(无内存上限)在录制结束后做,读 App Group 磁盘里的帧。
- 写盘格式:全分辨率 PNG(文字清晰,无 JPEG 伪影);只对**保留帧**编码,跳过帧不编码。

## 3. FrameSelector(v2 唯一的新算法)

目标:把 30~60fps 的视频流,降成"内容推进、互有重叠、可拼接"的稀疏关键帧序列。

v2 首版采用**最简稳健策略**(精确重叠交给现有 OverlapDetector,FrameSelector 只做粗筛):

1. 每来一帧 → 降采样成小灰度签名(复用 PixelBuffer 思路,如 64 宽)。
2. 与**上一保留帧**签名比较:
   - 近乎相同(手指静止)→ 跳过,避免重复帧。
   - 内容已推进超过阈值(滚动了)且帧稳定(非快速滑动模糊)→ 保留,编码写盘,更新签名。
3. 设最小时间间隔(如 0.3s)防抖;设保留帧总数上限(如 60)兜底内存/耗时。
4. 首尾可能是 PostShot 自身/桌面/切换动画的垃圾帧 → 不在扩展里硬判,交给采集后的缩略图条
   让用户手动删(复用 v1 已有能力)。

> 进阶(v2.x,非首版):基于滚动位移精确控制保留间隔、运动模糊检测优选清晰帧、状态栏/录制红条
> 自动裁剪。首版先用"内容差异 + 手动审阅"跑通。

## 4. project.yml 改动

新增扩展 target 与 App Group 权限:

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

### Phase 0 — 侧载冒烟测试(最高优先,先验证再投入)
- project.yml 加 `PostShotBroadcast` 扩展 + App Group。
- 扩展只做最小事:收到帧 → 计数 / 写 1 张帧到 App Group;主 App 读出来显示"已收到 N 帧"。
- **唯一目标**:确认 (a) CI 能构建带扩展+App Group 的工程;(b) 爱思能在免费账号上签名安装它。
- **若失败**:全屏录制路线在侧载层被卡。届时回退到"App 内置浏览器仅网页长截图"的零风险方案。
- 这一步必须在做任何算法工作前跑通——CI+爱思+装机循环很慢,先把最大未知数消掉。

### Phase 1 — 帧采集与筛选
- 实现 SampleHandler + FrameSelector + FrameStore(写)。
- 内存安全:逐帧降采样比较,只对保留帧编码写盘,立即释放。
- 单测:用合成"滚动序列"(已知位移的帧)验证 FrameSelector 去重 + 保留逻辑正确。

### Phase 2 — 拼接接线
- 主 App:录制结束后从 App Group 读所有保留帧 → 复用 StitchEngine → 复用 PreviewView。
- 复用 PhotoSaver / ImageExporter 保存分享。

### Phase 3 — 采集 UX 与健壮性
- CaptureView:RPSystemBroadcastPickerView 从 App 内启动录制 + 引导文案("缓慢滚动")。
- 采集后跳 v1 缩略图条审阅(删垃圾帧)→ 拼接。
- 状态栏时钟/录制红条处理(复用 v1 手动裁剪;自动裁剪列为 v2.x)。
- 用真实滚动调 FrameSelector 阈值。

### Phase 4 — 文档与收尾
- README v2 段落:全屏录制使用流程、能拍什么、已知限制(不能自动滚、需手指滚一遍)。
- 更新已知风险。

## 6. 验收标准

- Phase 0:带扩展 + App Group 的 ipa 能经爱思签名安装,录制时扩展能收到帧并写入 App Group。
- 在微信聊天里开录 → 缓慢滚一屏内容 → 停止 → 自动得到一张内容连续、无重复、无可见接缝的长图。
- 扩展全程常驻内存不超 50MB,不被系统杀。
- 采集帧为全分辨率,长图清晰度与原屏一致。

## 7. 已知风险

- **App Group + 免费签名**:最大风险,Phase 0 专门验证。爱思对 App Group 重写的支持不确定。
- **50MB 扩展内存上限**:靠"只写盘不累积"规避,需实测确认不被杀。
- **录制红条/状态栏**:进入抓帧画面,首版靠手动裁剪 + 审阅删帧规避。
- **快速滑动模糊**:首版靠引导用户慢滚 + 稳定性粗筛;精细优选列为 v2.x。
- **iOS 不能自动滚动**:这是能力上限,非缺陷;README 明确告知用户需手指滚一遍。
```
