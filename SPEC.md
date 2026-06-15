# LongShot 长截图 App — 实施规格 (SPEC)

> 交接文档。执行者照此实现即可。本文件是唯一事实来源。

## 0. 背景与硬约束

- **目标**:开源、免费、无广告、无水印的 iOS 长截图 App。
- **开发机是 Windows,无 Mac** → 永远不手写/不碰 `.xcodeproj`,统一用 XcodeGen 从 `project.yml` 生成工程。
- **编译**:GitHub Actions 云端 macOS runner,产出**未签名 `.ipa`** 作为 artifact。CI 绝不接触任何苹果证书 / 私钥 / 描述文件。
- **安装**:最终用户在设备端用 **SideStore**(免费 Apple ID,7 天自动续签)侧载。
- **输入方式 (v1)**:`PhotosPicker` 多选——用户先用系统截图截好几张,再进 App 选中拼接。**v1 不做录屏扩展**。
- **算法**:**原生 NCC(归一化互相关)** 求垂直重叠偏移,零第三方依赖。**明确不用 OpenCV**。
- **目标系统**:iOS 16+(PhotosPicker 需要)。
- **代码规范**:多个小文件优于少数大文件;单文件 < 400 行,函数 < 50 行;算法层写成纯函数,可单测;显式错误处理,不静默吞错。

## 1. 目录结构

```
LongShot/
├── project.yml                     # XcodeGen 工程描述
├── .github/workflows/build.yml     # 云端构建未签名 ipa
├── README.md                       # fork → 构建 → SideStore 安装全流程
├── SPEC.md                         # 本文件
├── Sources/
│   ├── Info.plist
│   ├── LongShotApp.swift            # @main 入口
│   ├── Views/
│   │   ├── ContentView.swift        # 主屏:选图、缩略图条、拼接按钮、进度
│   │   ├── PreviewView.swift        # 结果预览(可缩放滚动)+ 保存/分享
│   │   └── ThumbnailStrip.swift     # 已选图横向条,支持排序/删除
│   ├── Stitching/
│   │   ├── StitchEngine.swift        # 编排:[CGImage] → 长图 CGImage,后台执行 + 进度回调
│   │   ├── OverlapDetector.swift     # NCC 核心:两张图求最佳垂直重叠像素数
│   │   ├── ImageCompositor.swift     # 按偏移羽化合并,绘制最终画布
│   │   └── PixelBuffer.swift         # CGImage → 灰度行特征缓冲 工具
│   └── Utils/
│       ├── PhotoSaver.swift          # 保存 CGImage 到相册
│       └── ImageExporter.swift       # PNG/JPEG 导出 + 分享 sheet
└── Tests/
    └── StitchTests.swift             # 合成图验证 OverlapDetector 偏移正确
```

## 2. 核心算法规格(重点)

### 2.1 OverlapDetector — 求两张图垂直重叠

输入:上图 A、下图 B(已归一化为同宽 W)。输出:重叠像素行数 `overlap`(0 = 无重叠,直接首尾相接)。

1. **降维成行特征**:宽度下采样到 `W' = 64` 个采样点,每行得到长度 64 的灰度向量。A → `aRows[hA][64]`,B → `bRows[hB][64]`。比较「行签名」,对纯垂直滚动足够且快。
2. **粗搜 (1D)**:取每行平均灰度得到一维信号,做互相关快速圈定候选重叠高度,避免 O(h²) 全量暴力。
3. **精搜 (NCC)**:对候选重叠高度 `h ∈ [minOverlap, maxOverlap]`,用 A 末 `h` 行 vs B 首 `h` 行计算**归一化互相关**得分(对亮度漂移鲁棒),取最高分对应 `h`。用 `Accelerate`(vDSP)做向量运算。
4. **静态栏处理**:状态栏 / 导航栏跨帧不变会误匹配。v1 提供**手动顶部/底部裁剪滑块**;自动检测固定栏(对比首尾图找恒定区域)列为增强项。
5. **边界条件**:得分低于阈值 → 判无重叠直接拼接;宽度不同 → 先缩放到公共宽度;两图近乎相同 → 去重跳过。

### 2.2 ImageCompositor — 羽化合并

- 总高 = `hA + (hB - overlap)`,逐对累积。
- 重叠过渡区用约 20–30px 的 alpha 羽化混合,消除接缝。
- 用 `CGContext`,sRGB 色彩空间,避免重采样模糊。输出单张 `CGImage`。

### 2.3 StitchEngine — 编排

- 对 `[CGImage]` 顺序两两归约累积。
- 后台队列执行,回调报告进度(驱动 UI 进度条)。
- 内存:长图可能极大,大图分块绘制,处理完及时释放。

## 3. UI 流程 (SwiftUI)

1. **ContentView**:`PhotosPicker(matching: .images, maxSelectionCount: ~20)` → 缩略图条(可拖动排序、删除)→「拼接」按钮。
2. 点拼接:显示进度,`StitchEngine` 在主线程外执行。
3. **PreviewView**:可缩放 / 滚动查看结果 →「保存到相册」/「分享」。
4. 权限:`Info.plist` 配 `NSPhotoLibraryAddUsageDescription`(保存需要)。`PhotosPicker` 读取本身不需相册权限,但**取全分辨率原图**要正确配置加载(见风险 §8)。

## 4. project.yml 要点

- `name: LongShot`,`deploymentTarget.iOS: "16.0"`。
- 关闭签名:`CODE_SIGNING_REQUIRED: NO`、`CODE_SIGNING_ALLOWED: NO`、`DEVELOPMENT_TEAM` 留空(签名交给 SideStore)。
- `PRODUCT_BUNDLE_IDENTIFIER: com.longshot.app`(README 提示用户 fork 后可改成自己的,避免 bundle id 冲突)。
- `TARGETED_DEVICE_FAMILY: "1,2"`,竖屏。
- Info.plist 通过 `info.properties` 注入显示名「长截图」与权限描述。

## 5. GitHub Actions (.github/workflows/build.yml)

- `runs-on: macos-14`;触发:`push` + `workflow_dispatch`。
- 步骤:`checkout` → `brew install xcodegen` → `xcodegen generate` → `xcodebuild` 以 generic iOS device 构建并禁用签名 → 把产物 `.app` 放进 `Payload/` 目录,zip 后改名为 `LongShot.ipa` → `upload-artifact`。

## 6. README 安装指引(写给最终用户)

Fork 仓库 → 开启 Actions → 运行 workflow → 下载 `.ipa` artifact → 传到 iPhone → SideStore 用免费 Apple ID 安装 → 7 天内联网 SideStore 自动续签。

明确告知免费账号限制:**App 7 天过期、最多 3 个侧载 App、需偶尔联网续签**。

## 7. 实施阶段顺序

1. **脚手架**:`project.yml` + `Info.plist` + `@main` + 空 View,确保结构能被 `xcodegen generate` 成功生成。
2. **算法层**:`OverlapDetector` / `ImageCompositor` / `StitchEngine` 写成可测纯函数,用合成图(已知偏移)写单测验证偏移检测正确。
3. **UI 接线**:选图 → 拼接 → 预览 → 保存 / 分享。
4. **CI**:`build.yml` 跑通,产出可下载 ipa。
5. **README + 侧载指南**。

> 建议顺序成立的理由:算法层不依赖 UI 和 CI,可独立验证;UI 依赖算法接口已定;CI 在有可编译工程后才有意义。

## 8. 已知风险

- **免费 Apple ID 限制**:7 天过期 / 最多 3 个侧载 App。SideStore 续签缓解,但**无法分发给陌生人**,只能自用或让朋友各自 fork 自签。
- **PhotosPicker 可能返回压缩图**:必须正确请求全分辨率,否则长图清晰度受损。优先用 `loadTransferable(type: Data.self)` 拿原始数据再解码,避免 UIImage 中转降质。
- **超长图内存压力**:大画布分块绘制,避免一次性持有多份全尺寸位图。
- **静态栏误匹配**:状态栏 / 导航栏跨帧恒定,v1 用手动裁剪滑块规避,自动检测列为 v2。
- **录屏实时抓帧 (v2)**:体验更好但需 Broadcast Upload Extension + App Groups,侧载配置更复杂,v1 不做。

## 9. 算法验收标准(给执行者的明确目标)

- 用两张已知偏移的合成图(如纯色块 + 文字行),`OverlapDetector` 返回的 overlap 与真实值误差 ≤ 2px。
- 拼接结果在重叠区无可见重影或硬接缝。
- 20 张 1290×2796(iPhone 17 Pro Max 分辨率)截图拼接,在设备上数秒内完成且不崩溃(内存峰值受控)。
- 导出长图为无损或高质量 PNG/JPEG,清晰度与原截图一致。
