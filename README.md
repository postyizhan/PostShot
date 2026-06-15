# 长截图 LongShot

> Free & open-source long-screenshot stitcher for iOS — no ads, no watermark.

**长截图 (LongShot)** 是一款开源、免费、无广告、无水印的 iOS 长截图拼接 App。它把你手动截好的多张系统截图,自动识别垂直重叠区域后拼接成一张完整长图。核心使用原生 **NCC(归一化互相关)** 算法检测重叠,**零第三方依赖,不使用 OpenCV**。

整个项目在 Windows 上也能维护:工程文件由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成,云端 GitHub Actions 负责编译,设备端用 SideStore 自签安装。

---

## ✨ 功能特性

- 多张截图自动拼接成一张长图
- 原生 NCC 算法检测垂直重叠偏移,接缝处羽化过渡,无重影、无硬边
- 系统相册多选(`PhotosPicker`),取全分辨率原图,清晰度与原截图一致
- 结果可缩放预览,一键保存到相册或分享
- 支持手动顶部/底部裁剪,规避状态栏、导航栏跨帧误匹配
- 竖屏、纯本地处理,不联网、不收集任何数据
- 开源、免费、无广告、无水印

---

## 📲 通过 SideStore 安装(写给最终用户)

由于使用免费 Apple ID 自签,**每个人都需要 fork 本仓库、用自己的账号自行编译和签名**,不能直接分发给陌生人。

1. **Fork** 本仓库到你自己的 GitHub 账号。
2. 进入你 fork 后的仓库,打开 **Actions** 标签页,点击启用 Actions(首次需手动确认)。
3. 运行名为 **Build Unsigned IPA** 的 workflow(在 Actions 页面手动触发 `workflow_dispatch`),或直接向 `main`/`master` 推送一次提交触发构建。
4. 构建完成后,在该次 workflow run 页面底部下载 artifact **`LongShot-ipa`**(里面是未签名的 `LongShot.ipa`)。
5. 把 `.ipa` 传到你的 iPhone(隔空投送、文件 App、云盘等均可)。
6. 在 iPhone 上用 **[SideStore](https://sidestore.io/)** 打开该 `.ipa`,用**免费 Apple ID** 完成安装(SideStore 会在设备端自动签名)。
7. 保持设备偶尔联网,SideStore 会在 **7 天内自动续签**,避免过期。

### ⚠️ 免费 Apple ID 限制(请务必知悉)

使用免费 Apple ID 侧载存在以下硬性限制:

- **App 有效期 7 天**,过期后需重新签名才能继续打开。
- **最多同时侧载 3 个 App**(免费账号限制)。
- **需偶尔联网**,让 SideStore 在到期前自动刷新签名;长期离线会导致 App 失效。
- **无法分发给陌生人**:免费签名仅供自用或让朋友各自 fork 后自签。

### 💡 修改 Bundle ID(避免冲突)

如果你的设备上已经装过同 Bundle ID 的 App,或想和别人区分开,fork 之后可以编辑 `project.yml`,把 `LongShot` target 下的 `PRODUCT_BUNDLE_IDENTIFIER`(默认 `com.longshot.app`)改成你自己的标识,例如 `com.yourname.longshot`。改完重新触发构建即可。

---

## 🛠️ 从源码构建 / 开发

本项目对 **Windows 开发者友好**,无需本地 Mac:

- **永远不要手写或直接编辑 `.xcodeproj`**。工程结构统一写在 `project.yml`,由 `xcodegen generate` 生成。改工程配置只改 `project.yml`。
- **编译在云端进行**:GitHub Actions(`macos-14` runner)执行 `xcodegen generate` → `xcodebuild`,产出**未签名 `.ipa`**。
- **CI 绝不接触任何苹果证书、私钥或描述文件**,签名完全交给设备端的 SideStore。
- **系统要求:iOS 16+**(`PhotosPicker` 需要)。

本地若有 Mac,也可以手动复现 CI 流程:

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project LongShot.xcodeproj -scheme LongShot \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

---

## 🔍 工作原理简述

拼接核心是 **NCC(归一化互相关)垂直重叠检测**:

1. 把相邻两张图归一化到同宽,每行下采样成 64 维灰度行特征。
2. 先用一维平均灰度信号做粗搜,快速圈定候选重叠高度,避免逐像素暴力比对。
3. 再对候选区间用 `Accelerate`(vDSP)计算归一化互相关得分,对亮度漂移鲁棒,取最高分对应的重叠像素数。
4. 合成时按偏移累积总高,在约 20–30px 的重叠过渡区做 alpha 羽化混合,消除接缝。

得分低于阈值则判定无重叠、直接首尾相接;两图近乎相同则去重跳过。

---

## 📄 License

本项目采用 **[GNU AGPL-3.0](LICENSE)** 许可证。

这意味着:

- ✅ **任何人都能免费使用**——这正是做这个 App 的初衷:对抗 App Store 上那些付费、广告、水印的长截图工具。
- ✅ **可以自由 fork、修改、自签、分发**。
- ⚠️ **任何分发(包括修改后的版本)都必须以同样的 AGPL-3.0 开放完整源码**。

也就是说:**没有人能把它闭源、加广告、加水印拿去卖钱**——一旦分发就必须连源码一起公开,商业克隆的动机被彻底堵死。自由属于所有人,但不许有人把它变成生意。

> AGPL 的网络服务条款对当前这个纯本地 App 用不上,但为未来可能的云端/录屏功能预留了同等保护。

