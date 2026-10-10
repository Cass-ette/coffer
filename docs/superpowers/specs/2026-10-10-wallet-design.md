# Coffer 钱包功能设计（Tron TRC-20 USDT）

日期：2026-10-10
状态：待用户确认

## 1. 概述

Coffer 新增虚拟货币钱包能力：以**新条目类型 wallet** 存放 Tron 钱包（助记词/私钥 + 地址），支持查询 USDT/TRX 实时余额、展示收款二维码，以及在 Touch ID 门控下发起 TRC-20 USDT 转账。

功能边界（三档能力，本 spec 覆盖前两档 + 第三档的最小实现）：

| 档 | 能力 | 本期 |
|----|------|------|
| 1 | 凭证加密存储 | ✅ |
| 2 | 只读余额查询 | ✅ |
| 3 | 转账签名广播 | ✅（仅 USDT 合约转账，单链单代币） |

不做：多链（以太坊/Solana 等）、任意代币、DeFi/DApp 签名、质押能量管理、NFT。

### 非目标与定位

- Coffer 仍是密码管理器，不是热钱包 App。转账是“低频、小额、自担风险”能力，UI 上持续强化这一定位（主网标识、金额确认、手续费透明）。
- 用户已明确知情：测试期只放小额资产。

## 2. 用户故事

1. 作为用户，我能在 Coffer 新建一个 Tron 钱包（App 生成 12 词助记词），从交易所提 USDT 到它的地址。
2. 作为用户，我能导入已有助记词/私钥，钱包地址与原钱包一致。
3. 作为用户，我打开钱包条目能看到 USDT 与 TRX 实时余额。
4. 作为用户，收款时能出示地址 + 二维码。
5. 作为用户，转账时需要过 Touch ID 才能签名，能看到预估手续费，广播后拿到交易哈希与 Tronscan 链接。

## 3. 数据模型

沿用现有双枚举模式：`EntryType`（字符串枚举，落库/CLI/列表图标用）+ `EntryPayload`（关联值枚举）。

```swift
// EntryType 增加：
public enum EntryType: String, Codable, Sendable, CaseIterable {
    // ...现有 case...
    case wallet
}

// EntryPayload 增加（注：现有 payload 均 Hashable，Entry 由此合成 Hashable）：
public enum EntryPayload: Codable, Hashable, Sendable {
    // ...现有 case...
    case wallet(WalletPayload)
}

public struct WalletPayload: Codable, Hashable, Sendable {
    public enum Chain: String, Codable, Hashable, Sendable {
        case tron
    }
    public enum SecretKind: String, Codable, Hashable, Sendable {
        case mnemonic        // 12/24 词助记词（最高权限）
        case privateKey      // 64 位十六进制私钥
        case watchOnly       // 只存地址，无秘密（不能转账）
    }

    public var chain: Chain                 // 恒 .tron
    public var address: String              // T 开头 Base58Check
    public var secretKind: SecretKind       // 决定转账能力
    public var secret: String?              // mnemonic/privateKey 原文；watchOnly 为 nil
    public var derivationPath: String?      // BIP44 m/44'/195'/0'/0/0，导入时若非默认路径需记录
    public var note: String?
}
```

设计要点：

- **地址可搜索**：把地址写入 subtitle（现有 SearchIndex 只索引 title/subtitle/customFields，不改 SearchIndex 本身；subtitle 默认填地址，用户可改）。
- **watchOnly 模式**：只存地址也能用余额+收款功能（省去“只想看看”用户被迫存私钥的问题）；secretKind 为 watchOnly 时转账按钮禁用并说明原因。创建入口见 §6.1「仅导入地址」。
- 助记词/私钥作为普通字段进 vault 密文（与银行卡密码同级保护，AES-GCM + DEK in Keychain），不额外分层——vault 本身的加密强度就是它的保密边界（见 §4）。
- **CLI**：cli/main.swift 对 EntryType/EntryPayload 的穷举 switch 增加 wallet 分支；list 展示地址，secret 永不打印；本期 CLI 不做 wallet 的 add（app 内流程含助记词展示确认，CLI 场景不安全）。

## 4. 安全架构

分层复用 Coffer 既有设施，不新建密码学：

```
vault AES-GCM 密文（磁盘）
  └── DEK 存 Keychain（硬件级保护，需 Touch ID 解锁 vault）
        └── 转账签名前：独立再过一次 Touch ID（LAContext，复用隐藏分组同套机制）
              └── 私钥明文仅在内存存在数秒：解密→构建交易→签名→立即置零
```

1. **存储**：secret 只在 vault 密文里出现。锁屏（LockCoordinator）后内存无明文。
2. **转账门**：每次转账独立 Touch ID（业界软钱包标准，见 Trust Wallet/Phantom）。vault 处于解锁状态不豁免——防“电脑开着被人顺手操作”。
   - 生物识别不可用时回退：主密码再验一次（走 UnlockService 现有路径），不静默跳过。
3. **内存卫生**：签名用 `Data`，签名完成立即用零覆写再释放（尽力而为；Swift 字符串/密钥无法保证绝对清零，如实承认）。
4. **助记词展示**：新建钱包首次展示与“查看助记词”操作均需 Touch ID；页面常驻“此 12 词 = 钱包全部资产，抄纸备份、禁止拍照”警告文案。
5. **转账确认**：金额、对方地址、预估手续费三要素齐全才可确认；地址显示首尾各 6 位 + 校验通过徽标，防看错/防 clipboard 劫持式整段展示。

## 5. Tron 集成

### 5.1 依赖：TronKit.swift（首选）

- horizontalsystems/TronKit.swift，MIT，SPM。生产级钱包（Unstoppable Wallet）在用。
- 覆盖：secp256k1 签名、Keccak、Base58Check 地址校验、BIP39 助记词、Tron 交易 protobuf 编码、能量估算。
- 计划阶段第一步验证包可用性（编译 + 生成地址 + 模拟交易三连冒烟）。**回退边界**：若验证失败，回退方案（secp256k1 + Keccak + BIP39 各用独立成熟库、Tron protobuf 手写）视为 M3 范围变更——停下来重排 M3 计划，不在本 spec 内继续膨胀。

### 5.2 网络：TronGrid

统一 HTTPS API（免费档 + API key），无节点：

| 用途 | 端点 |
|------|------|
| TRX 余额、账户资源 | `/v1/accounts/{address}` |
| USDT 余额（balanceOf） | `/wallet/triggerconstantcontract` 只读模拟 |
| 转账（构建/模拟/广播） | `/wallet/triggersmartcontract`、`broadcasttransaction` |
| 费率 | `/wallet/getchainparameters`（能量燃烧价等动态参数） |

- USDT 合约地址常量：`TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`（主网唯一，硬编码合理；hex `41a614f803b6fd780986a42c78ec9c7f77e6ded13c`，2026-10-10 实测核验）。
- API key 存 AppSettings（非机密级，泄露仅影响限额）；所有请求 10s 超时。

### 5.3 手续费与金额精度：查询而非硬编码

1. 转账前模拟执行（triggerconstantcontract）取 energy_used；
2. getchainparameters 取当前能量燃烧单价；
3. **带宽**一并计入：每日免费带宽约 600 点，一笔 TRC-20 转账约耗 345 点；免费额度不足则按字节烧 TRX，估价时计入；
4. 展示「预计 ≈ XX TRX（可退路：质押免燃烧，本期不做）」。
5. **金额精度**：USDT（TRC-20）为 **6 位小数**（非 EVM 惯例的 18 位）。输入框限制 6 位小数、展示同 6 位；链上金额一律用整数最小单位（sun 类比：1 USDT = 10^6）换算，杜绝浮点误差；转账金额 > 余额（USDT）在确认前拦截（另见 §7）。
6. 广播失败/能量不足：按返回码给出人话错误（如 TRX 不够付手续费）。

### 5.4 广播语义：受理 ≠ 成功

broadcasttransaction 返回成功仅表示**交易进入内存池**，链上执行仍可能失败（典型：REVERT / OUT_OF_ENERGY / 带宽不足被丢弃）。本期采用**受理即展示**策略：

- 广播受理 → 显示交易哈希 + Tronscan 链接 +「以链上执行结果为准」提示文案，sheet 关闭；
- 不做轮询交易回执（YAGNI，用户在 Tronscan 看最终状态；余额下次刷新自然体现）；
- 若广播响应中直接带 DUPLICATE_INPUT / 签名错误等即时失败码，按失败处理（§7）。

## 6. UI 设计

### 6.1 编辑器（EntryEditorView 扩展）

类型选「钱包」后出现：

- 钱包名称（title，必填）
- 来源三选一：**新建**（App 生成助记词）/ **导入**（粘贴助记词或私钥）/ **仅导入地址**（watchOnly）
- 新建：生成后全屏展示 12 词（Touch ID 门控）→ 要求用户点击每个词完成「抄写确认」交互 → 抄写确认后展示地址
- 导入：粘贴 → 即时校验（词表合法性/私钥格式）→ 实时显示派生地址让用户核对（应与其原钱包地址一致）→ 保存
- 仅导入地址：校验 Base58Check 合法即可保存（secretKind = watchOnly，secret 为 nil）
- 备注、分组、标签沿用现有编辑器字段

### 6.2 详情页（wallet 类型）

```
┌────────────────────────────┐
│ 钱包名称      [Tron 徽标]   │
│ TAbC…9F2E（点按复制整地址） │
│────────────────────────────│
│ USDT  123.45               │  ← 大字，实时查询
│ TRX   27.8（手续费余额）    │
│ [刷新] 上次更新 5 分钟前    │
│────────────────────────────│
│ [收款]        [转账]        │
└────────────────────────────┘
```

- **余额缓存**：查询结果缓存 5 分钟（AppSettings 可调），打开详情页先显示缓存再静默刷新；连续失败降级为「余额不可用，点按重试」。
- **收款**：弹窗大字地址 + 二维码（CoreImage 生成）+ 复制按钮。
- **助记词查看**：折叠入口「查看助记词」→ Touch ID → 展示 + 警告文案。
- watchOnly 条目：转账按钮禁用，说明「此钱包未存助记词/私钥，仅可收款与查余额」。

### 6.3 转账流程（独占 sheet，防止中途切走）

1. 输入：对方地址（粘贴/手动，粘贴后强制完整显示校验结果）+ 金额（USDT）
2. 地址校验：Base58Check 失败 → 当场拒绝，不允许进入下一步
3. 费用预估：模拟执行 + 实时费率 →「预计消耗 ≈ XX TRX」；TRX 余额不足时直接警告并阻止
4. 确认页：金额、对方地址首尾 6 位、费用、USDT 转后余额预览 →「确认转账」
5. **Touch ID 门**（§4.2）→ 解密 secret → 构建+签名（内存内完成，签后置零）
6. 广播 → 受理：显示交易哈希（可复制 + Tronscan 链接 +「以链上执行结果为准」提示，见 §5.4）→ sheet 关闭回详情页；即时失败：保留输入，人话错误
7. 全程 sheet 不可被关闭中途丢失已输入内容（进度内 confirm 退出）

## 7. 错误处理

| 场景 | 处理 |
|------|------|
| 余额查询失败/超时 | 降级显示缓存或「不可用」，不阻塞其他功能 |
| 地址校验失败 | 输入阶段拦截，指明原因（格式/校验位） |
| 私钥与地址不匹配（导入时） | 保存前拦截——派生地址 ≠ 用户提供的地址时报错 |
| TRX 不足以付能量费 | 转账确认前拦截，提示需保留多少 TRX |
| 转账金额 > USDT 余额 | 确认前拦截 |
| 输入超过 6 位小数 | 输入框即时截断/提示 |
| 广播返回能量不足/失败 | 保留表单，展示链上错误的人话翻译 |
| Touch ID 失败/取消 | 中止转账，vault 保持解锁（转账门独立于 vault 解锁） |
| TronGrid 限流 | 余额缓存兜底；转账提示稍后重试 |

## 8. 测试策略

**CofferCore 单测（TDD，沿用现有 XCTest 模式）**

- WalletPayload：编解码 round-trip、watchOnly 无 secret、与旧版 vault 文档兼容（向后解码无 wallet 字段）
- 地址校验：合法/非法 Base58Check、前缀 T
- 网络层以协议抽象（`TronProviding`），单测全部 mock：
  - 余额解析（USDT/TRX）、缓存过期逻辑
  - 转账交易构建参数、能量+带宽估算换算、费用不足分支、金额 > 余额分支
  - 金额精度：6 位小数截断、字符串→最小单位整数换算无浮点
  - 广播成功/失败路径
- 助记词生成：熵长度 128 位、词表合法、同熵同词、SecRandom 可替换注入

**App 层手测清单**

- 新建钱包全流程（含抄写确认交互）
- 导入已知测试助记词 → 地址核对
- 余额显示与缓存刷新
- 转账（主网小额实测，用户已确认）：正常/Touch ID 取消/地址错/TRX 不足
- 锁屏后回来看余额仍可（余额不需要 secret）

## 9. 里程碑拆分

1. M1：WalletPayload + 编辑器（新建/导入）+ 详情页静态展示 —— 可存可看
2. M2：TronGrid 余额 + 收款二维码 —— 可查可收
3. M3：转账（校验→估价→Touch ID→签名→广播）—— 可转
4. M4：错误路径打磨 + 手测 + README 更新

## 10. 数据安全：绝不弄丢用户已有数据

用户明确要求（曾因版本更新丢失过全部数据）：钱包功能开发全程，现有 142 条记录的保全优先于一切新功能。

**多层防线（实现与发布均须遵守）：**

1. **冷备份先行**：钱包功能动第一行代码前，vault.vault + bak1 已复制到 `~/Documents/CofferBackups/vault-20261010-prewallet.*`（已做 ✅）。该副本与开发流程完全隔离，任何操作不碰它。
2. **兼容性测试是 M1 第一道门**：新增 `EntryType.wallet` 后，旧版 vault（无 wallet 字段）的解码 round-trip 单测必须先行通过，才允许任何后续改动。核心风险点：`EntryPayload` 的 Codable 是 Swift 自动合成的 keyed 编码，`decode` 无法识别未知 case 时会**整文档解码失败**——这正是历史上丢数据的典型机制。因此每次 vault 格式演进（本期和以后）都遵守：**读旧文件必须兼容、写新文件必须旧版可跳过（未知条目类型降级为占位而非报错）**。
3. **保存路径原子性**：沿用 VaultFileStore 现有写策略（tmp 文件原子替换 + 三份滚动备份 bak1-3），钱包功能不新增任何绕过该路径的写入。
4. **发布前验收**：M1/M3 结束各做一次「用 2026-10-10 冷备份副本解密 → 条目数 142 → 内容抽查」演练，写进验收清单。
5. **变更纪律**：任何涉及 Entry/VaultDocument 编解码的 PR，必须附带新旧格式兼容测试，否则不许合并。

