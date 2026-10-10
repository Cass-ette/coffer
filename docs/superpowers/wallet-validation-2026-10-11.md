# 钱包验收记录（2026-10-11）

分支：`feature/wallet`。T0–T11 的代码已实现；T8/T11 真机手测与 T12 恢复演练待用户在场完成。
目前未通过 Coffer 向主网广播真实转账，未替换真实 vault，未改动 `~/Documents/CofferBackups/vault-20261010-prewallet.*`。

## 自动验证

| 检查 | 结果 |
|---|---|
| `cd CofferCore && swift test` | 102 项通过，0 失败；原基线 68 项保留 |
| `TronTransferServiceTests` | 14 项通过，包含金额精度、余额/费用不足、实际签名字节核对、广播拒绝与未知状态 |
| App Debug 构建 | `xcodebuild -scheme Coffer -configuration Debug -derivedDataPath .build build` 成功；依赖及存量 Sendable 警告仍在 |
| CLI 构建 | `cd cli && swift build` 成功 |
| 真实 vault 只读统计 | 手测前 148 条；入账修复后 149 条可读。仅保留统计结果，不记录条目或凭证内容 |
| 钥匙串测试隔离 | 随机独立 service；不再操作正式 DEK 项 |
| 兼容性 | `_0` 编码黄金测试、旧文档读取与未知类型保留回写测试通过 |

TronGrid 只读冒烟使用公开黄金地址 `TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH`：
余额查询曾返回 8250.355783 USDT / 0 TRX；资源端点返回 `freeNetLimit: 600`、`freeNetUsed: 166`。
另取得未签名交易样本用于 mock 测试，无真实广播。该地址的助记词公开，不能作为实际收款钱包。

用户开始手测前已保留加密快照：`/private/tmp/coffer-wallet-pretest-l2mg2v1t`，包含真实 vault 与 bak1–3，四份副本校验通过。
这是手测前的应急副本；恢复演练前必须重新捕获届时的真实库，避免覆盖手测新增条目。

## 实现中对骨架的必要修正

- USDT 余额改为直接调用合约的 `balanceOf(address)`。真实入账手测发现，新地址尚未激活时，`/v1/accounts/{address}` 返回空数组，但合约已持有 USDT；账户索引也可能延迟。不能把空账户或合约查询失败当成零余额。网络请求绕过本机 HTTP 缓存。
- 账户资源取自 POST `/wallet/getaccountresource`，不是 `/v1/accounts/{address}`；资源用量为零时节点可以省略该字段。
- 免费带宽不足以覆盖整笔交易时，TRON 按整笔字节计费，而非仅计超出免费额度的差额。
  依据：[java-tron BandwidthProcessor 的 useFreeNet/useTransactionFee](https://github.com/tronprotocol/java-tron/blob/develop/chainbase/src/main/java/org/tron/core/db/BandwidthProcessor.java)。
  当前仍按计划以约 345 字节估价；未抵扣质押资源，实际手续费以链上为准。
- 不仅核对节点返回的 JSON，还核对 `SHA256(raw_data_hex) == txID` 和 protobuf 内的实际合约、地址、调用数据、费用上限。
  使用 fork 新增的公开 `TransactionVerifier` 复用上游生成的 protobuf 类型，没有手写 protobuf。
- 广播响应必须明确为成功才显示“已受理”；超时/缺少有效确认显示“状态未知”并保留哈希。
- 转账签名密钥在独立认证后、交易构建核验完毕时读取，签后尽力覆零；私钥地址须与转出地址一致。

TronKit 平台与验证接口差异见 [README-COFFER.md](../../Vendor/TronKit/README-COFFER.md)。

## 用户手测（待完成）

已核对一笔由外部钱包转入的交易：主网 USDT 合约执行 `SUCCESS`，实际转入 3.500000 USDT。
当时收款地址的账户查询为 `data: []`，合约 `balanceOf` 为 3,500,000 最小单位，复现了 UI 零余额问题。
已先补失败测试再修复，增加未激活账户、索引延迟、无效响应和整数精度四项回归；修复提交 `3e5223c`。
修复版已重新构建并启动，用户明确确认“已显示 3.500000 USDT”；本项真实入账与刷新验收通过。
交易哈希与用户钱包地址不写入仓库。

开始前保存编辑并退出旧版 Coffer，只打开本分支生成的 `.build/Build/Products/Debug/Coffer.app`。

- [ ] 新建钱包：独立认证 → 12 词展示 → 逐词抄写确认 → 保存；重新解锁后条目仍可读。
- [ ] 导入公开黄金助记词：派生地址与上述黄金地址一致；另验证私钥格式错误被拒绝。
- [ ] 仅地址钱包：余额和二维码可用，转账禁用，CLI 不输出凭证。
- [x] 新地址真实 USDT 入账与手动刷新：用户确认显示 3.500000 USDT。
- [ ] 余额刷新/缓存与 TronGrid 错误提示正常。
- [ ] 转账输入：坏地址、超额、超过六位小数、TRX 不足被拦截。
- [ ] 取消转账认证：返回确认页，未发起构建/签名/广播；重新确认要求再次认证。
- [ ] 使用用户自己的钱包及收款地址转出约 1 USDT：确认金额/地址/费用 → 认证 → 受理哈希 → Tronscan 链上成功 → 收款到账。
- [ ] 转账后检查原有条目保留；CLI 统计不少于手测开始前的 148 条（加上新增的钱包条目）。

## 冷备份恢复演练（待用户在场确认）

严格按 [计划 T12](plans/2026-10-10-wallet.md#task-12-m4-验收收尾) 执行；不得在用户未确认或 App 未完全退出时替换真实 vault。

1. 完成手测后退出 Coffer，确认没有旧版/新版进程持有保险库。
2. 记录当时真实 `vault.vault` 的校验和，创建独立的恢复工作目录，备份真实 vault；同时备份现有 bak1–3，验证副本校验和。
3. 只复制冷备份到真实 vault 路径，冷备份原件保持不变。
4. 启动新版 Coffer，由用户解锁，核对冷备份中 142 条及计划指定的两项抽查记录；期间不新增、编辑或删除条目。
5. 完全退出 Coffer，还原步骤 2 的真实 vault 及滚动备份；执行校验和核对，必须一致。
6. 新版 CLI 只读统计真实库，确认原有及手测新增条目俱在。

任何异常先停止演练并保留步骤 2 的救援副本。备份位置、校验结果及用户确认结果将在实际执行后追加。

## 收尾状态

- [x] T10：`31d493e`；带宽计费修正：`8f3ed23`。
- [x] T11 代码：`5212d9d`；手测待完成。
- [x] README 钱包说明与安全模型更新。
- [ ] 用户手测与小额主网转账结论。
- [ ] 冷备份演练、真实 vault 还原与校验结果。
- [ ] 验收通过后 push `feature/wallet`，创建面向 `main` 的 PR，附本记录与 fork 差异。
