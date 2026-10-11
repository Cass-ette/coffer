# Coffer

仅运行于 macOS 的本地密码与权限保险库：把网站账号、开发运维密钥、TOTP 验证码、敏感笔记，
以及"我能访问哪些系统"这件事本身，收进一个 Touch ID 一按即开的加密库里。

## 为什么是 Coffer

痛点不是"没有地方存密码"，而是**遗忘**：手上有多个系统的访问权限（部分在局域网），
时间一长记不清"我到底能进哪些系统、账号是什么、在内网还是公网"。
Coffer 以**检索优先**为核心价值：

- 全局模糊搜索 + 一层平级分组 + 自由标签，三种找回方式并存
- 任意应用中 `⌥Space` 呼出浮动搜索面板：指纹 → 敲两三个字 → 复制，全程 ≤ 5 秒
- 七种条目类型：登录账号 / 纯权限记录 / API 密钥 / SSH 私钥 / TOTP 验证码 / 安全笔记（含附件）/ Tron 钱包

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
- 无遥测；普通保险库操作在本地完成。钱包余额、估价和广播通过 HTTPS 访问 TronGrid；能量比价及租赁访问 TronSave，服务商可见公开地址与交易信息
- 保险库加密使用 CryptoKit + CommonCrypto；钱包使用 [TronKit macOS fork](Vendor/TronKit/README-COFFER.md) 及其依赖，私钥和助记词不发送到节点

## 钱包

仅支持 **Tron 主网的 TRC-20 USDT**，适合低频、小额操作。USDT 与 TRX 均按六位小数显示，
金额转换使用整数，超出六位小数的输入会被拒绝。
主网小额转账与恢复演练尚待人工验收，进度见[钱包验收记录](docs/superpowers/wallet-validation-2026-10-11.md)。

| 操作 | 行为 |
|---|---|
| 新建 | 认证后生成 12 词助记词，逐词完成抄写确认再保存 |
| 导入 | 导入 BIP39 助记词或十六进制私钥，核对派生地址后保存 |
| 仅导入地址 | 查询余额、展示二维码与复制收款地址，不能转账 |
| 收款 | 展示 Tron 地址二维码；仅接收 Tron 网络的 TRX / TRC-20 USDT |
| 转账 | 输入地址与金额 → 比较直接 TRX 付费 / 按次租能量 → 核对预计总价与当前资源下的费用上限 → 独立认证 → 签名广播 → 查实际费用 |

助记词采用 `m/44'/195'/0'/0/0`，不支持 BIP39 附加密码或自定义派生路径。请把助记词抄纸备份，
不要拍照、截图或存入云端。黄金测试助记词是公开凭证，禁止向它对应的钱包充值。

钱包复用三层安全边界：磁盘上的 AES-GCM 保险库、钥匙串与保险库解锁、每次查看凭证或转账时的独立认证。
独立认证使用 Touch ID / macOS 系统认证，系统认证失败或不可用时要求 Coffer 主密码；取消认证会中止转账。
签名私钥在签名时从已解锁的保险库读取，以 `Data` 短暂使用后尽力覆零；Swift 内存复制无法保证绝对清零。

新地址即使尚未激活 Tron 账户，也能接收 USDT；余额直接从 USDT 合约查询。

转账前需准备足够的 TRX 支付手续费。估价抵扣现有能量和带宽，显示预计支出、费用明细及按当前费率与资源计算的最高约支出；
合约执行预算预留 20% 余量，不预扣，实际费用取链上回执。节点构建的实际交易字节须通过地址、合约、金额、带宽和费用上限核对才能签名。

按次租赁使用 TronSave 的一小时能量产品，仅购买本次能量缺口，无需 API key 或预充值；
比价包含固定租金、租赁付款网络费和 USDT 转账网络费。**租赁按订单收费，未用完不承诺退款**，不等同于严格按实际能量用量付费。
报价约 90 秒有效，费用上涨需重新确认。支付私钥始终留在本机，仅提交本地签名后的 TRX 付款；
确认付款成功且资源到账后才自动发送 USDT。等待超时可关闭窗口，记录会保留；付款已确认但资源不足时可重新核对当前资源下的直接转账费用。

**节点受理不代表转账成功**：请通过结果页的交易哈希和 Tronscan 链接确认链上执行结果。
若广播超时，状态会显示为“待确认”，请先查链上记录，勿立即重复转账。链上失败也可能消耗手续费。
最近一次转账的公开哈希、租赁金额与回执单独保存在本机 `wallet-transactions` 目录，不包含凭证或已签名交易，不改变 vault 格式。
这些本机记录用于中断恢复与费用核对，不是完整账本；钱包助记词恢复不会带回这些记录。

设置中可配置 TronGrid API key 与余额缓存时间（默认 5 分钟）。CLI 对钱包只读：可列出地址，
不打印助记词或私钥，也不支持写入钱包凭证。启用钱包后请使用新版 Coffer，旧版无法识别 wallet 条目。

本分支验收构建位于 `.build/Build/Products/Debug/Coffer.app`。旧的 Xcode DerivedData 构建可能把不认识的钱包条目误报成“vault 文件可能损坏”；
此时先退出旧版再打开上述新版，不要直接恢复备份或重建保险库。

## 构建

需要 macOS 26 + Touch ID 机型、Xcode、[xcodegen](https://github.com/yonaskolb/XcodeGen)。

```bash
git clone https://github.com/Cass-ette/coffer.git
cd coffer
xcodegen generate
open Coffer.xcodeproj   # ⌘R 运行
```

数据文件位于 `~/Library/Application Support/cc.cassette.coffer/`，永不进入仓库。

## 已知问题

### Touch ID 调用方式
`LAContext.evaluatePolicy` 必须使用 completion handler 方式调用，async/await 方式在某些 macOS 版本上不工作：
```swift
// ✅ 正确
context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, error in
    continuation.resume(returning: success)
}

// ❌ 不工作
let success = try await context.evaluatePolicy(...)
```

### Keychain ACL 在开发构建中失败
开发阶段使用 `SecAccessControlCreateWithFlags` 创建带生物识别保护的 Keychain 项会报 -34018 错误。
解决方案：
- 开发/测试：使用简单的 `kSecAttrAccessible = kSecAttrAccessibleWhenUnlocked`
- 正式发布：用 Apple Developer 账号签名后再启用 ACL 保护

### Touch ID 按钮无响应
症状：点击 Touch ID 按钮完全无反应，不弹出认证对话框。
根因：DEK 丢失（Keychain 条目被手动删除或损坏），`unlockWithBiometricsSync()` 检测到 DEK 不存在后静默返回 `.needMasterPassword`，UI 没有明显反馈。
解决方案：
- 用主密码解锁一次，`unlockWithMasterPassword()` 会自动检测并恢复 DEK 到 Keychain
- 下次锁定后 Touch ID 即可正常使用

## 非目标（v1）

浏览器自动填充 / iOS 与云同步 / 数据导入 / 密码健康审计 / 拼音搜索。
