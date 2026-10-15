# 安装 Coffer

运行要求：macOS 12 Monterey 或更新版本；通用安装包同时包含 Intel（x86_64）与 Apple 芯片（arm64）。macOS 12.7.6 在目标范围内，旧系统上的界面与 Touch ID 仍需在实际机器上验收。

1. 解压 `Coffer-macOS12-universal.zip`，把 `Coffer.app` 拖到“应用程序”。
2. 首次打开若提示无法验证开发者，在 Finder 中按住 Control 点按应用，选择“打开”，再确认“打开”。当前个人分发包使用本地签名，尚无 Developer ID 签名或 Apple 公证。
3. 第一次运行设置自己的主密码。支持 Touch ID 的机器下次启动自动请求一次指纹；没有 Touch ID 时用主密码解锁。
4. 默认全局快捷键是 Option + Space；若被其他软件占用，在 Coffer 设置中更换。

macOS 12 的开机启动需在“系统偏好设置 → 用户与群组 → 登录项”中手动添加 Coffer。macOS 13 及以上可用应用内开关。

只分享应用压缩包。每台电脑独立创建保险库，不需要发送原使用者的主密码、钥匙串或 `~/Library/Application Support/cc.cassette.coffer/`。升级应用不重建保险库。

钱包主网转出和恢复演练尚未全部人工验收，详见 [验收记录](superpowers/wallet-validation-2026-10-11.md)。

## 构建安装包

构建机器需要支持 Swift 6.2 的 Xcode 和 xcodegen；收件人只需要 macOS 12+，不需要 Xcode。

```sh
./scripts/package-macos.sh
```

产物位于 `.build/distribution/Coffer-macOS12-universal.zip`，并附有 SHA-256 校验文件。脚本只打包应用及本文，不读取保险库和钥匙串，也不会替换本机已安装的应用。
