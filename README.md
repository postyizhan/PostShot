# PostShot 驿站截图

> Free & open-source long-screenshot stitcher for iOS — no ads, no watermark.

**PostShot 驿站截图** 是一款开源、免费、无广告、无水印的 iOS 长截图 App，支持 **系统录屏滚动自动抽帧拼接**、**最近连续截图自动发现** 与 **相册手动多选拼接** 三种工作流。核心采用原生 `Accelerate`（vDSP）水平边缘 **NCC（归一化互相关）** 算法，**零第三方依赖，不使用 OpenCV**。

整个项目在无本地 Mac 环境下也能维护：工程文件由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成，云端 GitHub Actions 负责编译与单测，设备端可通过 SideStore 自签安装。

---

## ✨ 功能特性

- **三种长截图入口**：
  - **录制**：通过 ReplayKit 系统级屏幕录制扩展实时稀疏抽帧，在任意 App 中匀速滚动一遍即可回到 PostShot 生成长图；
  - **自动**：自动聚类相册中最近连续截取的同屏截图并恢复滚动顺序；
  - **拼图**：通过系统 `PhotosPicker` 手动多选原图并自由调整顺序。
- **稳健拼接与画质保真**：
  - 水平边缘特征 NCC 抑制聊天固定壁纸干扰，精准对齐文字与卡片边界；
  - 像素级硬拼接（无羽化重影），保持原图分辨率与 sRGB 色彩清晰度；
  - 自动识别顶部状态栏 / 导航栏与底部输入栏 / Home 指示条并给出裁剪建议；
  - 遇到跨页面过渡帧或重叠证据不足时安全停止（不静默乱拼），自动高亮断档帧并提供一键剔除重拼按钮。
- **纯本地隐私安全**：所有帧传输（仅 `127.0.0.1` 本地回环）与图像合成均在设备本地完成，不连接外部服务器、不收集任何数据。
- **开源、免费、无广告、无水印**。

---

## 📲 通过 SideStore 安装

由于使用免费 Apple ID 自签，**每个人都需要 fork 本仓库、用自己的账号自行编译和签名**，不能直接分发给陌生人。

1. **Fork** 本仓库到你自己的 GitHub 账号。
2. 进入 fork 后的仓库，打开 **Actions** 标签页并启用 Actions。
3. 运行名为 **Build Unsigned IPA** 的 workflow（手动触发 `workflow_dispatch` 或推送提交到 `main`）。
4. 构建完成后，在该次运行页面底部下载 artifact **`PostShot-ipa`**（内含未签名的 `PostShot.ipa`）。
5. 将 `.ipa` 传到 iPhone，使用 **[SideStore](https://sidestore.io/)** 打开并用你的 Apple ID 完成签名安装。
6. 保持设备偶尔联网，SideStore 会在 **7 天有效期内自动续签**。

### ⚠️ 免费 Apple ID 限制

- **App 有效期 7 天**，到期前需由 SideStore 自动或手动续签。
- **最多同时侧载 3 个 App / 扩展槽位**（免费开发者账号系统限制）。
- **iOS 系统限制**：iOS 不允许第三方 App 自动替用户滚动其他应用界面，录屏模式下仍需手指匀速滚动目标页面，PostShot 负责自动抽帧、去状态栏与无缝拼接。

### 💡 修改 Bundle ID（避免冲突）

所有 Target 的包名均由 `APP_BUNDLE_ID` 变量统一派生（主应用 `$(APP_BUNDLE_ID)`、录屏扩展 `$(APP_BUNDLE_ID).broadcast`、单测 `$(APP_BUNDLE_ID).tests`）：

- **Fork 后走云端 CI + SideStore 安装**：在 [Config/Base.xcconfig](Config/Base.xcconfig) 中修改 `APP_BUNDLE_ID` 为你自己的唯一包名（例如 `com.yourname.postshot`），重新触发 Actions 即可。
- **仅在本地真机编译调试**：请在被 `.gitignore` 忽略的 `Config/Local.xcconfig` 中取消注释并修改 `APP_BUNDLE_ID`（见下方「本地构建并安装到真机」），这样不会污染 Git 仓库。

`CaptureView` 会自动根据主包名匹配 `.broadcast` 扩展，无需修改源码。

---

## 🛠️ 从源码构建与测试

- **请勿直接手改 `.xcodeproj`**：工程结构唯一事实来源是 `project.yml`，由 `xcodegen generate` 生成。
- **系统要求**：iOS 16.0+。

在本地 Mac 上复现 CI 构建与测试：

```bash
brew install xcodegen
xcodegen generate

# 运行模拟器单元测试
xcodebuild test -project PostShot.xcodeproj -scheme PostShot \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# 构建未签名 Release 包
xcodebuild -project PostShot.xcodeproj -scheme PostShot \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

### 📱 本地构建并安装到真机

公开仓库默认在 [Config/Base.xcconfig](Config/Base.xcconfig) 中将 `DEVELOPMENT_TEAM` 留空，以确保云端 CI 与任意贡献者都能无证书编译；同时通过 `#include? "Local.xcconfig"` 支持本地私有配置覆盖，**不会将你的 Team ID 提交到 Git**。

真机运行前请先满足以下准备条件：

1. **登录 Apple 账号**：在 Xcode → **Settings → Accounts** 中登录你的 Apple ID（免费个人账号即可，需曾在该账号下触发过一次真机调试以生成本地开发证书）。
2. **开启开发者模式**：在 iPhone 上开启 **设置 → 隐私与安全性 → 开发者模式**，并通过数据线连接 Mac 且在手机端点击「信任此电脑」。
3. **如遇包名冲突请覆盖 `APP_BUNDLE_ID`**：若签名提示 `com.postshot.app` 已被其他团队占用，可在下方 `Config/Local.xcconfig` 中取消注释并设置 `APP_BUNDLE_ID = com.yourname.postshot`。

#### 方式一：通过 `Config/Local.xcconfig` 一次配置，永久生效（推荐）

1. 查询个人 10 位 Team ID（输出中 `OU=` 后的字符）：

```bash
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```

2. 复制模板文件并填入你的 Team ID（`Config/Local.xcconfig` 已加入 `.gitignore`，不会被提交）：

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

编辑 `Config/Local.xcconfig`：

```xcconfig
DEVELOPMENT_TEAM = <YOUR_TEAM_ID>
// 若 com.postshot.app 冲突，取消下行注释并改成你的包名：
// APP_BUNDLE_ID = com.yourname.postshot
```

3. 生成工程并运行：

```bash
xcodegen generate
```

打开 `PostShot.xcodeproj`，顶部设备栏选择已连接的 iPhone，直接按下 **`⌘R`** 即可编译签名并安装到真机。此后即使重新执行 `xcodegen generate`，你的本地签名配置依然会自动保留。

> 如习惯使用命令行直接编译安装到真机（先用 `xcrun devicectl list devices` 查询 `<YOUR_DEVICE_UDID>`）：
>
> ```bash
> DERIVED_DIR="/tmp/PostShot-DeviceBuild"
> xcodebuild -project PostShot.xcodeproj -scheme PostShot \
>   -configuration Debug -sdk iphoneos \
>   -destination "platform=iOS,id=<YOUR_DEVICE_UDID>" \
>   -derivedDataPath "$DERIVED_DIR" \
>   -allowProvisioningUpdates build
>
> xcrun devicectl device install app \
>   --device "<YOUR_DEVICE_UDID>" \
>   "$DERIVED_DIR/Build/Products/Debug-iphoneos/PostShot.app"
>
> xcrun devicectl device process launch \
>   --device "<YOUR_DEVICE_UDID>" \
>   com.postshot.app
> ```

#### 方式二：临时在 Xcode 图形界面选择 Team

如果不想创建 `Config/Local.xcconfig`，也可以：

1. 执行 `xcodegen generate` 后打开 `PostShot.xcodeproj`。
2. 分别选中 **`PostShot`** 与 **`PostShotBroadcast`** 两个 Target，在 **Signing & Capabilities** 中选择你的 **Team**（请勿提交修改后的工程文件）。
3. 顶部设备栏选择已连接的 iPhone，按下 **`⌘R`** 编译运行。

> 注意：每次重新运行 `xcodegen generate` 会重置图形界面中手动选择的 Team；如经常重新生成工程，建议使用方式一的 `Config/Local.xcconfig`。

> **首次安装提示**：若手机弹出「未受信任的开发者」或启动被拦截，请前往 iPhone 的 **设置 → 通用 → VPN 与设备管理**，找到你的开发者证书并点击 **信任** 后即可打开（免费个人账号签名有效期同样为 7 天）。

---

## 🔍 工作原理简述

1. **录屏稀疏抽帧（`FrameEncoder` + `FrameSelector`）**：在 Broadcast Extension 的 50MB 内存预算内，将视频帧在 Core Image 空间下采样为 `64×64` 灰度签名，忽略首尾固定系统栏并结合最小滚动位移门限，仅对有效推进的关键帧编码全分辨率 PNG 通过回环 TCP 发送给主应用。
2. **固定栏检测与规范化（`ImageNormalizer` + `FixedBarDetector`）**：统一 EXIF 方向与 sRGB 色彩空间，自动检测跨帧恒定的顶部/底部 UI 栏比例。
3. **两段式边缘 NCC 重叠检测（`PixelBuffer` + `OverlapDetector`）**：提取 64 列水平边缘特征，先由一维行均值粗筛候选并做非极大值抑制，再用 `vDSP` 精算二维 NCC 与竞争峰显著性裕度，覆盖常规重叠与微移高重叠区间。
4. **硬切合成（`ImageCompositor`）**：按精确重叠行数在画布上逐段硬切覆盖，消除半透明混合重影。

---

## 📄 License

本项目采用 **[GNU AGPL-3.0](LICENSE)** 许可证：

- ✅ **任何人都能免费使用、自由 fork、修改、自签与分发**。
- ⚠️ **任何分发（包括修改后的衍生版本）都必须以同样的 AGPL-3.0 许可证开放完整源码**，禁止闭源商用或套壳加广告/水印售卖。
