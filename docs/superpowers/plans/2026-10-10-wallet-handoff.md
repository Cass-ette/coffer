# Coffer 钱包功能 — 执行交接文档

> 给执行者（人类/AI agent）：本文档是**现状快照 + 硬约束**。
> 完整任务文本（含全部代码）在 `docs/superpowers/plans/2026-10-10-wallet.md`（下称「计划」），
> 需求规格在 `docs/superpowers/specs/2026-10-10-wallet-design.md`（下称「spec」）。
> 三者冲突时以计划为准，计划含糊时以 spec 为准。

## 1. 当前状态（2026-10-11）

- 仓库：`~/Projects/coffer`，**工作分支 `feature/wallet`**（从 main 拉出，后续任务都在这个分支提交）
- CofferCore 测试基线：**68/68 绿**（`cd CofferCore && swift test`）
- 已完成（含两阶段审查）：
  - **T0** 修测试套件（`d84c3f4`）：groupIDs/isHidden 签名演进没同步测试导致编译失败，已修
  - **T1** WalletPayload 数据模型（`d17205e`）：EntryType.wallet + EntryPayload.wallet + WalletPayload struct + SearchIndex 只搜地址不搜 secret
  - **T2** 旧 vault 兼容门（`39e32fa` + `70136ee`）：LegacyVaultCompatTests + watchOnly 归一化 + 助记词不可搜索测试
- **⚠️ 当前 app 和 CLI 编译不过**——T1 加了 wallet case，app/cli 的穷举 switch 还没补分支。这是**预期状态**，T3 的波及修复会让它们重新可编译。不要慌，也不要在 T3 之前去"修"它。

## 2. 剩余任务（全部在计划文档里有完整代码）

| # | 任务 | 一句话 |
|---|------|--------|
| T3 | 未知类型降级 | EntryType.unknown + degradedTypeRaw + RawJSON + EntryPayload 自定义 Codable 复刻 `_0` 格式 + app/CLI 波及分支。**数据安全核心** |
| T4 | CLI wallet 只读分支 | printPayload 加 wallet/unknown 分支，buildPayload 拒绝，secret 永不打印 |
| T5 | Vendor TronKit fork | 见 §3.4 fork 重建说明 |
| T6 | TronWalletService | 地址校验/助记词派生（TDD，黄金值见计划） |
| T7 | TronGridClient | 余额查询 + 金额精度（TDD，mock 注入） |
| T8 | 编辑器钱包表单 | 新建/导入/仅地址三模式 + 助记词抄写确认 sheet（Touch ID 门） |
| T9 | 详情页余额 + 收款二维码 | WalletDetailView + AppSettings 两项 + SettingsView 钱包 Section |
| T10 | 转账构建/估价 | TronTransferService（TDD，含广播成功/失败 mock 测试） |
| T11 | TransferSheet | 三屏状态机 + Touch ID 门 + 私钥内存瞬存 |
| T12 | 验收收尾 | README + 冷备份恢复演练（shasum 校验流程在计划里） |

## 3. 硬约束（违反任何一条 = 返工）

### 3.1 数据安全（最高优先级，用户曾因版本更新丢过全部数据）

- **冷备份勿动**：`~/Documents/CofferBackups/vault-20261010-prewallet.*` 是隔离副本，任何操作不碰它
- 每个任务结束跑全量 `swift test`，测试数只增不减（基线 68）
- vault 格式演进铁律：读旧必须兼容、未知类型降级为占位（`_0` 格式黄金测试 `testPayloadEncodesSynthesizedShape` 永远不许删）
- T12 恢复演练必须按计划里的 shasum 校验流程做，演练结束还原真 vault

### 3.2 磁盘格式（实测验证过，不许"顺手改进"）

- EntryPayload 的 Codable 合成格式是 `{"camelCaseCase名":{"_0":{…}}}`，如 `{"apiKey":{"_0":{…}}}`
- case 键是 `apiKey/sshKey/secureNote`（Swift case 名），**不是** `api_key`（那是 EntryType 的 rawValue，两套系统）
- 自定义 Codable（T3）必须逐字节复刻该格式——格式锁测试过了才算过

### 3.3 Swift 6.4 编译器坑（实测踩过）

- 嵌套泛型函数 + `guard let`/`case` 模式匹配组合 → `failed to produce diagnostic` 编译器崩溃。用平铺 if-let 链 + 顶层静态函数（计划里的代码已是规避后的写法，照抄）
- `String(format: "%064x", Int64)` 对 ≥2³² 的值**截断成全零**（金额 ≥4295 USDT 静默转错账）。金额 hex 一律 `String(amount, radix: 16)` + 补零

### 3.4 TronKit fork（T5）

- 上游 horizontalsystems/TronKit.swift 1.5.2 只声明 iOS 平台，macOS 编译不过
- `/tmp/tronkit-fork` 是已验证的 fork，但 /tmp 重启即清空；重建方法（3 个补丁）在计划 Task 5 Step 1 里有完整说明
- fork 复制进仓库 `Vendor/TronKit`（含 README-COFFER.md 记录 diff），CofferCore 用 `.package(path:)` 引用
- 只用 TronKit **公开** API：`Signer.sign(hash:privateKey:)`（`signature(hash:)` 是 internal）、`Signer.address(seed:)`、`Mnemonic.*`（HdWalletKit）。txID 即待签哈希

### 3.5 流程与提交

- TDD：先红测试再实现（计划里每个任务都给了完整测试代码）
- 每个任务单独 commit，消息**中文、不加 Co-Authored-By、不标 AI 辅助**
- 最小 diff：不做计划外的事，不顺手重构
- 命令速查：CofferCore 测试 `cd CofferCore && swift test`；app 构建 `cd ~/Projects/coffer && xcodebuild -scheme Coffer -configuration Debug -derivedDataPath .build build`（只看 error，Sendable warning 是存量噪音）；CLI `cd cli && swift build`
- **禁止直接在 main 上提交代码**（文档除外），一切在 feature/wallet

## 4. 需要用户配合的节点

- **T8/T11 手测**：新建钱包全流程、导入黄金助记词核对地址、转账 Touch ID 流程——需要真机操作
- **T11 转账实测**：用户明确接受主网小额（~1 USDT）测试
- **T12 恢复演练**：涉及替换真 vault 文件，需要用户在场确认
- 环境备忘：登录钥匙串若残留 `cc.cassette.coffer.dek` 条目会让 DEKStoreTests 误报 errSecDuplicateItem（T0 时清过一次，签名的 app 再写还会出现——是环境问题不是代码问题）

## 5. 完成定义

全部任务完成 = app 能新建/导入 Tron 钱包、显示 USDT/TRX 余额、出示收款二维码、Touch ID 门控转账（受理哈希 + Tronscan 链接），且：
- CofferCore 全量测试绿（68 + 新增）
- app 构建零 error
- CLI list 显示 wallet 条目（secret 不显示）
- 冷备份演练通过（142 条俱在 + 校验和一致）
- 用户手测通过

完成后 push feature/wallet，开 PR 到 main（PR 描述含 TronKit fork 差异、手测结果、演练结论）。
