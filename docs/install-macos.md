# 安装 Coffer

运行要求：macOS 12 Monterey 或更新版本；通用安装包同时包含 Intel（x86_64）与 Apple 芯片（arm64）。macOS 12.7.6 在目标范围内，旧系统上的界面与 Touch ID 仍需在实际机器上验收。

1. 打开 `Coffer-macOS12-universal.dmg`，把 `Coffer.app` 拖到旁边的 `Applications`（应用程序）文件夹。已有用户先完全退出 Coffer，覆盖时选择“替换”。ZIP 版本也可解压后拖入“应用程序”。
2. 首次打开若提示无法验证开发者，在 Finder 中按住 Control 点按应用，选择“打开”，再确认“打开”。当前个人分发包使用本地签名，尚无 Developer ID 签名或 Apple 公证。
3. 已有用户升级后继续用原来的主密码解锁，不需要重新创建保险库；若 Touch ID 暂时不可用，先用主密码。首次安装的用户设置自己的主密码。
4. 默认全局快捷键是 Option + Space；若被其他软件占用，在 Coffer 设置中更换。

macOS 12 的开机启动需在“系统偏好设置 → 用户与群组 → 登录项”中手动添加 Coffer。macOS 13 及以上可用应用内开关。

已有重要数据时，先完全退出 Coffer，再备份 `~/Library/Application Support/cc.cassette.coffer/` 整个目录，其中保险库文件保持加密。在 Finder 按 Command + Shift + G 可打开这个路径。升级仅替换 `/Applications/Coffer.app`，数据目录与钥匙串独立保存；本次转账崩溃修复没有改动保险库格式。若升级后意外显示“创建保险库”，先退出并核对原数据目录，避免误建新库。

只分享 DMG 或 ZIP 安装包。每台电脑独立创建保险库，不需要发送原使用者的主密码、钥匙串或数据目录。

钱包主网转出和恢复演练尚未全部人工验收，详见 [验收记录](superpowers/wallet-validation-2026-10-11.md)。

## 构建安装包

构建机器需要支持 Swift 6.2 的 Xcode、xcodegen、Python 3.9+ 和 OpenSSL（macOS 自带 LibreSSL 可用）；收件人只需要 macOS 12+，不需要这些构建工具。打包前自动运行 Core 与本地钱包环境集成测试，失败时停止打包。

```sh
./scripts/package-macos.sh
```

产物位于 `.build/distribution/Coffer-macOS12-universal.dmg` 和 `.build/distribution/Coffer-macOS12-universal.zip`，各附有 SHA-256 校验文件。DMG 内含应用、Applications 快捷方式及升级说明。脚本只打包应用和说明，不读取保险库和钥匙串，也不会替换本机已安装的应用。

GitHub Actions 的 `macOS installers` 流程也运行同一脚本，先测试再构建通用 DMG / ZIP。PR 和 main 更新时自动运行，流程合并至默认分支后也可在 Actions 页面手动运行。成功后下载 `Coffer-macOS12-universal` artifact，解压得到 DMG、ZIP 和校验文件；这不会自动发布 GitHub Release。
