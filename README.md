# Coffer

仅运行于 macOS 的本地密码与权限保险库：把网站账号、开发运维密钥、TOTP 验证码、敏感笔记，
以及"我能访问哪些系统"这件事本身，收进一个 Touch ID 一按即开的加密库里。

## 为什么是 Coffer

痛点不是"没有地方存密码"，而是**遗忘**：手上有多个系统的访问权限（部分在局域网），
时间一长记不清"我到底能进哪些系统、账号是什么、在内网还是公网"。
Coffer 以**检索优先**为核心价值：

- 全局模糊搜索 + 一层平级分组 + 自由标签，三种找回方式并存
- 任意应用中 `⌥Space` 呼出浮动搜索面板：指纹 → 敲两三个字 → 复制，全程 ≤ 5 秒
- 六种条目类型：登录账号 / 纯权限记录 / API 密钥 / SSH 私钥 / TOTP 验证码 / 安全笔记（含附件）

![主窗口](assets/brand/screenshots/main.png)
![锁定页](assets/brand/screenshots/lock.png)
![浮动搜索](assets/brand/screenshots/panel.png)

## 安全模型

- 单文件保险库 `vault.vault`，AES-256-GCM 整库加密，原子写入 + 三代滚动备份
- 两层钥匙：随机 256 位 DEK 加密数据；DEK 经 PBKDF2-SHA256（600k 迭代）由主密码包装，
  同时以 Touch ID / Mac 登录密码 ACL 存入本机钥匙串（不可迁移）——日常解锁只需按一次指纹
- 闲置自动锁定（默认 5 分钟）+ 睡眠/锁屏/切用户/屏保立即锁定
- 复制敏感字段后自动清空剪贴板（默认 45 秒，防误清保护）
- 敏感字段不参与搜索索引；密码/密钥/正文永不出现在搜索联想里
- 无网络行为、无遥测、零第三方依赖（CryptoKit + CommonCrypto + 自实现 RFC 6238 TOTP）

## 构建

需要 macOS 26 + Touch ID 机型、Xcode、[xcodegen](https://github.com/yonaskolb/XcodeGen)。

```bash
git clone https://github.com/Cass-ette/coffer.git
cd coffer
xcodegen generate
open Coffer.xcodeproj   # ⌘R 运行
```

数据文件位于 `~/Library/Application Support/Coffer/`，永不进入仓库。

## 非目标（v1）

浏览器自动填充 / iOS 与云同步 / 数据导入 / 密码健康审计 / 拼音搜索。
