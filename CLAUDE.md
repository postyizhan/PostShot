# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

PostShot 驿站截图是一款开源、免费、无广告、无水印的 iOS 长截图 App。核心算法是原生 **NCC(归一化互相关)** 垂直重叠检测。

项目有两条产品线:
- **v1(已完成)**:用户先用系统截图截好多张,再进 App 多选(`PhotosPicker`),自动识别重叠后拼成一张长图。
- **v2(进行中)**:用 ReplayKit Broadcast Upload Extension 做系统级全屏录制,用户连续滚一次,扩展自动抓帧 → 喂给 v1 的拼接后端。

事实来源:`SPEC.md`(v1)与 `SPEC_v2.md`(v2)。改动前先读对应 SPEC。

## 关键开发约束(必读)

- **开发机是 Windows,无 Mac**。**永远不要手写或直接编辑 `.xcodeproj`**——它由 `xcodegen generate` 从 `project.yml` 生成。改工程配置只改 `project.yml`。
- **编译在云端**:GitHub Actions(`macos-26` runner)跑 `xcodegen generate` + `xcodebuild`,产出**未签名 `.ipa`**。**CI 绝不接触任何苹果证书 / 私钥 / 描述文件**——签名完全交给设备端 SideStore。
- 因此 `project.yml` 里签名被刻意全部关闭(`CODE_SIGNING_REQUIRED/ALLOWED=NO`)。不要为了本地能跑而打开签名。
- 部署目标 **iOS 16+**(`PhotosPicker` 需要);构建工具链用最新(Xcode 26 / iOS 26 SDK)。用新 SDK 构建低部署目标是有意为之。
- 代码规范:多个小文件优于少数大文件;单文件 < 400 行,函数 < 50 行;算法层写成可单测纯函数;显式错误处理,不静默吞错。所有源码头部带 `SPDX-License-Identifier: AGPL-3.0-or-later`。

## 常用命令

本地若有 Mac 才能复现完整构建;Windows 上只能编辑源码 + 推 CI。

```bash
# 生成 Xcode 工程(改完 project.yml 后必跑)
brew install xcodegen && xcodegen generate

# 构建未签名 App(CI 的核心步骤)
xcodebuild -project PostShot.xcodeproj -scheme PostShot \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

# 跑单元测试(模拟器)
xcodebuild test -project PostShot.xcodeproj -scheme PostShot \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

触发 CI:推送到 `main`/`master`,或在 Actions 页手动跑 **Build Unsigned IPA** workflow。产物 artifact 名为 `PostShot-ipa`。

## 架构

### 拼接后端(v1 核心,v2 完全复用,已被单测证明正确)

数据流:`[CGImage]` → `StitchEngine` 编排 → 逐对 `OverlapDetector.detect` → `ImageCompositor.composite` → 单张长图 `CGImage`。

- **`PixelBuffer`**(`Sources/Stitching/`):`CGImage` → 宽度下采样到 64 维的灰度行特征缓冲。所有比较都在这个空间做,快且对纯垂直滚动够用。
- **`OverlapDetector`**:纯函数 `enum`。两图求最佳垂直重叠行数。三段式:① 重复帧预检(在 **full height** 比较,因为重复信号被截断搜索故意排除了,必须单独测);② 一维平均灰度粗搜圈定候选;③ 候选区间用 `Accelerate`(vDSP)算 NCC 得分。`Config` 控阈值(`acceptThreshold`、`duplicateThreshold` 等)。
- **`ImageCompositor`**:按 `Segment(image, overlap)` 累积总高,重叠过渡区做硬拼接(见 git 历史:接缝曾从羽化改为硬拼接以消重影)。`CGContext` + sRGB。
- **`StitchEngine`**:后台队列编排 + 进度回调。`stitchSync` 是供测试用的同步纯版本。注意**重叠值的坐标空间转换**:`OverlapDetector` 在源像素高度上测量,合成时要按 `commonWidth/bottom.width` 缩放到公共宽度空间(见 `StitchEngine.swift:77`)。`commonWidth` 取所有输入最小宽度(只缩小不放大避免模糊)。手动裁剪(`topCropFraction`/`bottomCropFraction`)在检测/合成前应用,用来切掉状态栏/导航栏等跨帧恒定区(否则会误匹配)。

### UI 层(SwiftUI,`Sources/Views/`)

v1 流程:`ContentView`(选图)→ `ThumbnailStrip`(排序/删除)→ `StitchViewModel` 驱动 `StitchEngine` → `PreviewView` + `ZoomableScrollView`(缩放预览)→ `PhotoSaver`/`ImageExporter`/`ShareSheet` 保存分享。`SelectedImage` 是选中图的模型。

v2 采集 UI:`CaptureView` + `BroadcastPickerButton`(`RPSystemBroadcastPickerView` 启动录制)。

### v2 采集层与帧桥(进行中,关键背景)

**核心坑**:免费 Apple ID 侧载下 **App Group 容器不可用**(CaptureView 诊断证明 container 为 nil)。这是 v2 最大风险,直接决定了架构。

因此当前 v2 不走 App Group 共享磁盘,改用 **本地回环 TCP socket** 跨进程传帧:
- `Shared/FrameBridge.swift`:双方约定的常量(`127.0.0.1:52890`)。`Shared/` 同时被主 App 和扩展 target 引用。
- `Sources/Views/FrameBridgeServer.swift`:主 App 端,`NWListener` 监听。
- `BroadcastExtension/FrameBridgeClient.swift` + `SampleHandler.swift`:扩展端,`RPBroadcastSampleHandler` 收 `CMSampleBuffer`,通过 socket 流给主 App。

**当前状态是 Phase 0 冒烟测试**:扩展只发文本消息(`"frame N"`),验证 extension→app 通道在免费签名下能不能通。还没接真实帧编码和拼接。测试协议:录制时保持 PostShot 在前台「录制」tab,隔离 socket 桥本身(背景存活是另一个独立问题)。

**v2 内存铁律**:Broadcast Extension 有 ~50MB 常驻内存硬上限,超了系统直接杀。所以**绝不在扩展里累积全分辨率帧、绝不在扩展里拼接**。每帧:降采样廉价比较 → 保留帧才全分辨率编码写出 → 立即释放。拼接放主 App(无内存上限)在录制结束后做。`FrameSelector`(SPEC_v2 §3,尚未实现)是 v2 唯一新算法:把 30~60fps 流降成稀疏关键帧,精确重叠仍交给现有 `OverlapDetector`。

## 测试

`Tests/StitchTests.swift` 用合成图(已知偏移)验证 `OverlapDetector`。验收标准:返回 overlap 与真实值误差 ≤ 2px(SPEC §9)。新增算法逻辑优先用合成序列做单测。

## License

AGPL-3.0-or-later。任何分发(含修改版)必须同样开源。新文件保留 SPDX 头。
