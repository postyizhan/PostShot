# AGENTS.md

本文件为在 PostShot 仓库中工作的开发者与 AI 编程助手提供工程约束、核心架构与验证规范。

## 项目概述

**PostShot 驿站截图** 是一款开源、免费、无广告、无水印的 iOS 长截图拼接 App（部署目标 iOS 16.0+），核心采用原生 `Accelerate`（vDSP）水平边缘 **NCC（归一化互相关）** 算法，**零第三方依赖**。

支持三大工作流入口：
- **拼图**（`ContentView`）：通过 `PhotosPicker` 手动多选截图并调整顺序拼接。
- **自动**（`AutoStitchView`）：自动聚类系统相册最近连续截图并恢复滚动顺序拼接。
- **录制**（`CaptureView`）：通过 ReplayKit Broadcast Upload Extension 实时抽帧并流式传回主 App 拼接。

## 硬性开发约束

- **禁止手改 `.xcodeproj`**：`project.yml` 是工程配置与文件组织的唯一事实来源。修改配置或增删源码目录后，必须运行 `xcodegen generate` 重新生成工程。
- **严禁将个人签名信息提交到仓库**：`project.yml` 与 `Config/Base.xcconfig` 中 `DEVELOPMENT_TEAM` 必须保持为空，绝不提交任何人的 Team ID、证书、私钥或描述文件；本地真机调试的个人 Team ID / 自定义 Bundle ID 必须写入被 `.gitignore` 忽略的 `Config/Local.xcconfig`（参考 `Config/Local.xcconfig.example`）。
- **CI 保持无签名产出**：GitHub Actions（`.github/workflows/build.yml`，`macos-26`）通过 `xcodebuild` 命令行参数（`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`）显式关闭签名，产出未签名 `.ipa`（artifact `PostShot-ipa`）供设备端 SideStore 自签，CI 绝不接触苹果证书、私钥或描述文件。
- **系统与方向约束**：部署目标保持 **iOS 16.0+**（避免使用 iOS 17+ 专属 API，如 `ContentUnavailableView`），仅支持竖屏（`UIInterfaceOrientationPortrait`）。
- **代码规范**：
  - 小文件优于大文件：单文件控制 `< 400` 行，单函数控制 `< 50` 行。
  - 算法与状态机保持纯函数、与 UI/Photos 框架解耦，便于在无真机无相册的 CI 上做单元测试。
  - 显式错误处理，禁止静默吞错。
  - 所有 Swift 源文件首行必须保留 `// SPDX-License-Identifier: AGPL-3.0-or-later`。

## 核心架构与避坑铁律

### 1. 无 App Group 架构（本地回环 TCP + 静音保活）
- 免费 Apple ID 侧载下 **App Group 容器恒为 `nil`**，切勿重新引入 App Group 共享容器或 `.entitlements` 依赖。
- 扩展与主 App 跨进程传帧统一走本地回环 TCP（`Shared/FrameBridge.swift`，`127.0.0.1:52890`）与二进制长度前缀分帧协议（`Shared/FrameProtocol.swift`）。
- 主 App 通过 `Sources/Utils/AudioKeepAlive.swift` 播放运行时生成的静音 PCM（配合 `Info.plist` 中的 `UIBackgroundModes: audio`），确保切出 App 录制时后台 socket 监听不挂起。

### 2. Broadcast Extension 内存红线（~50MB 硬上限）
- `BroadcastExtension/`（`SampleHandler`、`FrameEncoder`、`FrameBridgeClient`）常驻内存受系统 ~50MB 硬限制，**严禁在扩展内累积全分辨率帧或执行拼接**。
- 每帧仅提取低成本 64×64 灰度签名，经 `Shared/FrameSelector.swift` 粗筛后才编码流式发送并立即释放；`FrameBridgeClient` 控制在途帧数防止 TCP 背压堆积。
- 主 App 侧由 `FrameBridgeServer` 接收、经 `CaptureStartGate` 门控（过滤切屏/倒计时/前台帧），并直接落盘到 `CaptureFrameStore`（`temporaryDirectory` 帧池），仅在内存中保留轻量签名供下游按需补帧。

### 3. 拼接与画质管线（`Sources/Stitching/`）
- **规范化与校验**：`ImageNormalizer` 统一 EXIF 方向与 sRGB 像素格式；`StitchInputValidator` 做前置维度与有效性校验。
- **固定栏检测**：`FixedBarDetector` / `FixedBarScanning` 负责离群帧过滤、竖屏灵动岛状态带跳过、毛玻璃栏检测与平坦背景回缩，避免误裁聊天留白或保留重复标题栏。
- **重叠检测**：`PixelBuffer`（64 列水平边缘特征抑制固定壁纸）→ `OverlapDetector`（全图重复帧预检 + 一维粗筛 + `vDSP` 二维 NCC，覆盖高重叠微移区间）。
- **图解析与排序**：`ScreenshotSequenceOrderer` 自动恢复截屏顺序并剔除孤立离群帧；`StitchGraphResolver` 自动跳过断档离群帧并从 `CaptureFrameStore` 按需补帧。
- **合成与细节清理**：
  - `ImageCompositor` 必须采用**中点硬拼接（禁止羽化混合）**，避免高对比界面接缝出现白线/重影；拼接前需将测量重叠值按 `commonWidth` 缩放至公共宽度空间；支持眉头三档（`HeaderKeepMode`：`none` / `navBarOnly` / `full`）与底栏保留策略。
  - `ScrollIndicatorRemover` 采用双侧边距夹击判据消除右侧竖向滚动条，防止误伤右侧聊天头像或气泡。

### 4. 三大入口共享审阅层（`Sources/Views/`）
- 拼图（`ContentView`）、自动（`AutoStitchView` + `Sources/Screenshots/`）、录制（`CaptureView` + `CaptureReviewView`）共用 `StitchViewModel`、`StitchReviewView`、`PreviewView` 及 `PhotoSaver` / `ImageExporter`。

## 常用构建与验证命令

```bash
# 1. 生成 Xcode 工程（增删文件或修改 project.yml 后必跑）
xcodegen generate

# 2. 运行模拟器单元测试
xcodebuild test -project PostShot.xcodeproj -scheme PostShot \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# 3. CI 同款未签名 Release 构建（验证不破坏无签名约束）
xcodebuild -project PostShot.xcodeproj -scheme PostShot \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

- 新增算法或状态机逻辑时，优先在 `Tests/` 中使用合成图像或合成序列编写确定性单测，确保在无真机、无系统相册的 CI 环境中稳定通过。

## License

`GNU AGPL-3.0-or-later`。任何分发（含修改后的衍生版本）必须以相同许可证开放完整源码。
