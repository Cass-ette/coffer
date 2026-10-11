# 官方 GasFree 独立钱包

用户确认扩展为官方 gasfree.io 独立钱包；原费用计划中的 GasFree 排除项由本授权更新。

## 实施与验收

1. TronGrid 设置增加申请步骤、匿名状态、只读 key 验证（新鲜鉴权请求），无需重启。147 项回归、App/CLI 构建通过。
2. 固定 Tron 主网 GasFree Controller、Beacon、USDT 与 TIP-712 类型；用官方 SDK 黄金向量验证派生地址及签名哈希。复用已有密码库，保留上游许可。
3. 独立 GasFree API Key/Secret 存本机独立钥匙串项；验证服务，严格核对派生地址、费用、nonce、冻结余额及服务商。凭证不进入聊天、日志、vault 或公开付款记录。
4. 钱包详情增加独立地址、链上余额与转账入口。确认页列首次激活费、服务费、总扣款及签名费用上限。当前普通钱包资金不自动转入，watchOnly 不签名。
5. 认证后刷新核验报价，提交前原子保存公开授权摘要。超时/退出保留待查状态，不重发；traceId 与链上哈希分开。只有固化链回执与匹配 USDT 事件验证后才标记完成。未知状态保留并支持以服务商 traceId 恢复查询。
6. 全量回归、App/CLI 构建，更新使用说明与验收记录；真实服务凭证及小额主网操作由用户在 App 完成。

## 边界

- GasFree 是另一收款地址，由现有钱包密钥控制；原地址 USDT/TRX 不可直接用作其余额。
- GasFree 以 USDT 收服务费，首次可能另收激活费；不是免费转账，也不承诺比租能量更便宜。
- 不改 vault 格式、不触碰正式 DEK 或冷备份；不自动支付、广播、搬资金。
- 服务凭证申请可能需要审核。没有凭证时明确未启用，不把无法发送的地址作为建议充值入口。
- 官方接口没有按 requestId 查 traceId 的文档。响应丢失时保留 requestId 供服务商排查，不把 requestId 当成 traceId，不因本机超时/服务端错误自动解除付款保护。
- 已核对主网代理实现 ABI：`permitTransfer(address,address,address,uint256,uint256,uint256,uint256,uint256,bytes)`、`nonces(address)` 与 `GasFreeTransfer` 事件。固化链超过授权到期时间 60 秒且 nonce 未消耗，才允许无 traceId 恢复；否则继续保留待确认。成功回执校验完整 calldata、签名摘要、事件中的服务商和 nonce，以及 USDT 全部扣款。

## 依据

- https://docs.gasfree.io/
- https://developer.gasfree.io/
- https://github.com/gasfreeio/gasfree-sdk-js （地址与 TIP-712 黄金向量）
- https://github.com/gasfreeio/gasfree-sdk-swift （算法核对；未引入其 iOS 依赖栈）

主网 API 为 `https://open.gasfree.io/tron`，HMAC 鉴权路径包含 `/tron`。密钥不内置在分发客户端。

2026-10-11 代码已实现；正式 GasFree 凭证配置、服务报价及小额主网手测尚待用户完成。开发仅调用公开只读接口与使用测试凭证的 mock，没有发起真实授权或付款。
