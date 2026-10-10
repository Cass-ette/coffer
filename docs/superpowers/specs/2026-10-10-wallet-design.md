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

CofferCore `Entry` 新增 payload 类型（沿用现有 PayloadKind 模式）：

```swift
public enum PayloadKind: Codable {
    // ...现有 case...
    case wallet(WalletPayload)
}

public struct WalletPayload: Codable, Equatable, Sendable {
    public enum Chain: String, Codable, Sendable {
        case tron
    }
    public enum SecretKind: String, Codable, Sendable {
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

- **地址可搜索**：Entry 的 title/subtitle 走现有 SearchIndex，地址同时进索引（用户常“搜地址找钱包”）。
- **watchOnly 模式**：只存地址也能用余额+收款功能（省去“只想看看”用户被迫存私钥的问题）；secretKind 为 watchOnly 时转账按钮禁用并说明原因。
- 助记词/私钥作为普通字段进 vault 密文（与银行卡密码同级保护，AES-GCM + DEK in Keychain），不额外分层——vault 本身的加密强度就是它的保密边界（见 §4）。

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
3. **内存卫生**：签名用 `Data`，签名完成立即用零覆写再释放（尽力而为，spec 5.2 已如实承认 Swift 无法保证绝对清零）。
4. **助记词展示**：新建钱包首次展示与“查看助记词”操作均需 Touch ID；页面常驻“此 12 词 = 钱包全部资产，抄纸备份、禁止拍照”警告文案。
5. **转账确认**：金额、对方地址、预估手续费三要素齐全才可确认；地址显示首尾各 6 位 + 校验通过徽标，防看错/防 clipboard 劫持式整段展示。

## 5. Tron 集成

### 5.1 依赖：TronKit.swift（首选）

- horizontalsystems/TronKit.swift，MIT，SPM。生产级钱包（Unstoppable Wallet）在用。
- 覆盖：secp256k1 签名、Keccak、Base58Check 地址校验、Tron 交易 protobuf 编码、能量估算。
- 计划阶段先验证包可用性与 API 表面；若不可用，回退方案：secp256k1.swift + 自实现 protobuf（代价更高，风险已在评估）。

### 5.2 网络：TronGrid

统一 HTTPS API（免费档 + API key），无节点：

| 用途 | 端点 |
|------|------|
| TRX 余额、账户资源 | `/v1/accounts/{address}` |
| USDT 余额（balanceOf） | `/wallet/triggerconstantcontract` 只读模拟 |
| 转账（构建/模拟/广播） | `/wallet/triggersmartcontract`、`broadcasttransaction` |
| 费率 | `/wallet/getchainparameters`（能量燃烧价等动态参数） |

- USDT 合约地址常量：`TR7NHqjeKQxGTCi8q8ZY4QL5knYg7dVgX7`（主网唯一，硬编码合理）。
- API key 存 AppSettings（非机密级，泄露仅影响限额）；所有请求 10s 超时。

### 5.3 手续费：查询而非硬编码

1. 转账前模拟执行（triggerconstantcontract）取 energy_used；
2. getchainparameters 取当前能量燃烧单价；
3. 展示「预计 ≈ XX TRX（可退路：质押免燃烧，本期不做）」。
4. 广播失败/能量不足：按返回码给出人话错误（如 TRX 不够付手续费）。

## 6. UI 设计

### 6.1 编辑器（EntryEditorView 扩展）

类型选「钱包」后出现：

- 钱包名称（title，必填）
- 来源二选一：**新建**（App 生成助记词）/ **导入**（粘贴助记词或私钥）
- 新建：生成后全屏展示 12 词（Touch ID 门控）→ 要求用户点击每个词完成「抄写确认」交互 → 抄写确认后展示地址
- 导入：粘贴 → 即时校验（词表合法性/私钥格式）→ 实时显示派生地址让用户核对（应与其原钱包地址一致）→ 保存
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
6. 广播 → 成功：显示交易哈希（可复制 + Tronscan 链接）→ sheet 关闭回详情页；失败：保留输入，人话错误
7. 全程 sheet 不可被关闭中途丢失已输入内容（进度内 confirm 退出）

## 7. 错误处理

| 场景 | 处理 |
|------|------|
| 余额查询失败/超时 | 降级显示缓存或「不可用」，不阻塞其他功能 |
| 地址校验失败 | 输入阶段拦截，指明原因（格式/校验位） |
| 私钥与地址不匹配（导入时） | 保存前拦截——派生地址 ≠ 用户提供的地址时报错 |
| TRX 不足以付能量费 | 转账确认前拦截，提示需保留多少 TRX |
| 广播返回能量不足/失败 | 保留表单，展示链上错误的人话翻译 |
| Touch ID 失败/取消 | 中止转账，vault 保持解锁（转账门独立于 vault 解锁） |
| TronGrid 限流 | 余额缓存兜底；转账提示稍后重试 |

## 8. 测试策略

**CofferCore 单测（TDD，沿用现有 XCTest 模式）**

- WalletPayload：编解码 round-trip、watchOnly 无 secret、与旧版 vault 文档兼容（向后解码无 wallet 字段）
- 地址校验：合法/非法 Base58Check、前缀 T
- 网络层以协议抽象（`TronProviding`），单测全部 mock：
  - 余额解析（USDT/TRX）、缓存过期逻辑
  - 转账交易构建参数、能量估算换算、费用不足分支
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

每个里程碑结束 app 处于可用状态，可独立提交。

