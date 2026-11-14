# 安装 Coffer

运行要求：macOS 12 Monterey 或更新版本；通用安装包同时包含 Intel（x86_64）与 Apple 芯片（arm64）。macOS 12.7.6 在目标范围内，旧系统上的界面与 Touch ID 仍需在实际机器上验收。

1. 打开 `Coffer-macOS12-universal.dmg`，把 `Coffer.app` 拖到旁边的 `Applications`（应用程序）文件夹。已有用户先完全退出 Coffer，覆盖时选择“替换”。ZIP 版本也可解压后拖入“应用程序”。
2. 首次打开若提示无法验证开发者，在 Finder 中按住 Control 点按应用，选择“打开”，再确认“打开”。当前个人分发包使用本地签名，尚无 Developer ID 签名或 Apple 公证。
3. 已有用户升级后继续用原来的主密码解锁，不需要重新创建保险库；若 Touch ID 暂时不可用，先用主密码。首次安装的用户设置自己的主密码。
4. 默认全局快捷键是 Option + Space；若被其他软件占用，在 Coffer 设置中更换。

macOS 12 的开机启动需在“系统偏好设置 → 用户与群组 → 登录项”中手动添加 Coffer。macOS 13 及以上可用应用内开关。

已有重要数据时，先完全退出 Coffer，再备份 `~/Library/Application Support/cc.cassette.coffer/` 整个目录，其中保险库文件保持加密。在 Finder 按 Command + Shift + G 可打开这个路径。升级仅替换 `/Applications/Coffer.app`，数据目录与钥匙串独立保存；本次转账崩溃修复没有改动保险库格式。若升级后意外显示“创建保险库”，先退出并核对原数据目录，避免误建新库。

## 恢复备份

设置里的“从本机自动备份恢复”按 `vault.bak1` → `vault.bak2` → `vault.bak3` 的顺序，回滚到最近一份可读取的自动备份。它不是你在 Documents 或外置磁盘保存的冷备份；旧冷备份可能没有后来添加的钱包、条目或修改。

恢复外部冷备份前，先完全退出 Coffer。在 Finder 按 Command + Shift + G 打开 `~/Library/Application Support/cc.cassette.coffer/`，把整个 `cc.cassette.coffer` 文件夹复制到另一个安全位置，作为“恢复前救援副本”；确认 `vault.vault` 也在副本中。再单独复制冷备份文件，不要移动或覆盖原件。仅在确认救援副本可读后，才用冷备份副本替换正式目录中的 `vault.vault`，保留现有 `vault.bak1`、`vault.bak2`、`vault.bak3` 和冷备份原件。

打开 Coffer，用原主密码解锁，核对备份日期对应的条目。恢复旧快照后，较新的钱包和条目暂时不会显示，这是快照时间差，不代表它们已从救援副本删除。测试结束时完全退出 Coffer，再把救援副本中的 `vault.vault` 放回正式目录；重新打开并确认最新条目及钱包恢复。恢复过程不要选择“放弃并重置”，不要在旧快照上创建或修改数据。任何文件、密码或条目异常时先退出应用并保留所有副本。

只分享 DMG 或 ZIP 安装包。每台电脑独立创建保险库，不需要发送原使用者的主密码、钥匙串或数据目录。

钱包主网转出和恢复演练尚未全部人工验收，详见 [验收记录](superpowers/wallet-validation-2026-10-11.md)。

## 构建安装包

构建机器需要支持 Swift 6.2 的 Xcode、xcodegen、Python 3.9+ 和 OpenSSL（macOS 自带 LibreSSL 可用）；收件人只需要 macOS 12+，不需要这些构建工具。打包前自动运行 Core 与本地钱包环境集成测试，失败时停止打包。

```sh
./scripts/package-macos.sh
```

产物位于 `.build/distribution/Coffer-macOS12-universal.dmg` 和 `.build/distribution/Coffer-macOS12-universal.zip`，各附有 SHA-256 校验文件。DMG 内含应用、Applications 快捷方式及升级说明。脚本只打包应用和说明，不读取保险库和钥匙串，也不会替换本机已安装的应用。

GitHub Actions 的 `macOS installers` 流程也运行同一脚本，先测试再构建通用 DMG / ZIP。PR 和 main 更新时自动运行，流程合并至默认分支后也可在 Actions 页面手动运行。成功后下载 `Coffer-macOS12-universal` artifact，解压得到 DMG、ZIP 和校验文件；这不会自动发布 GitHub Release。
