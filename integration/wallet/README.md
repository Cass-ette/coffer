# 钱包故障仿真环境

这是随 Coffer 一起维护的有状态 HTTP 仿真服务。目标是把实际故障持续沉淀为可复现的环境行为，而不是每次修改业务代码时临时编一个成功响应。

服务维护独立的 TRX / USDT 余额、能量、带宽、交易、租赁订单和回执。集成测试走 Coffer 实际的 URLSession、protobuf 核验、本地 secp256k1 签名和磁盘交易记录；不使用 HTTPProviding mock 或 URLProtocol 拦截。服务用 OpenSSL 校验签名，并拒绝篡改及重复交易。

## 运行

构建机器需要 Python 3.9+ 和 OpenSSL（macOS 自带 LibreSSL 可用）；不需要 Docker、API key 或外部服务。接收应用安装包的用户不需要这些工具。

在仓库根目录执行：

```sh
# 集成回归：自动启动独立服务、随机端口，完成后清理
swift test --package-path CofferCore --filter WalletEnvironmentTests

# 单元测试 + 集成回归
swift test --package-path CofferCore

# 独立启动，保留状态以便手动调试
python3 integration/wallet/simulator.py --scenario key-slice-rental.json --port 18765
```

服务固定监听 `127.0.0.1`，不会向外部网络转发请求。独立启动的默认账户使用公开测试私钥 `1` 对应的公钥，不读本机保险库或钥匙串。自动测试使用公开 BIP39 测试助记词及全新的临时交易记录目录。仿真服务不装入正式 App，正式 App 没有切换至此环境的入口。

```sh
# 查询状态、请求次数、余额、租赁订单与实际费用
curl http://127.0.0.1:18765/__admin/state

# 推进虚拟区块，触发能量委托到账、动态能量变化或回执可见
curl -X POST http://127.0.0.1:18765/__admin/advance \
  -H 'Content-Type: application/json' -d '{"blocks":2}'

# 推进虚拟链时间，测试过期交易恢复；不需要真实等待几分钟
curl -X POST http://127.0.0.1:18765/__admin/advance \
  -H 'Content-Type: application/json' -d '{"seconds":181}'

# 重置为另一个版本化场景
curl -X POST http://127.0.0.1:18765/__admin/reset \
  -H 'Content-Type: application/json' -d '{"scenario":"trongrid-429.json"}'
```

## 已覆盖的环境行为

| 场景 | 来源 | 断言重点 |
|---|---|---|
| `direct-usdt-zero-return` | 已遇到的问题重建 | ABI 返回零仍有 Transfer 事件，实际转账、双方余额和费用对账 |
| `key-slice-rental` | 2026-11-14 崩溃 | 助记词私钥非零下标；真实签名、付租金、延迟到账、重新报价、转 USDT |
| `fractional-rental-price` | 已遇到的问题重建 | 130285 × 67.25 SUN 向下取整为 8761666 SUN |
| `trongrid-429` | 已遇到的问题重建 | 真实 HTTP 429、Retry-After 等待、一次重试上限 |
| `unactivated-usdt` | 已遇到的问题重建 | 原生账户索引为空，合约余额仍为正 |
| `usdt-revert` | 已遇到的问题重建 | RPC 接受与 VM 成功独立核对，失败不能靠返回值变为成功 |
| `rental-response-lost` | 主动构造 | 租金已执行但确认丢失，重建记录存储后保持阻止新付款，查询资源后继续 |
| `broadcast-response-lost` | 主动构造 | USDT 已执行但确认丢失，回执延迟可见，哈希恢复且广播次数为一 |
| `dynamic-energy` | 主动构造 | 虚拟区块改变能量系数；重新报价变贵，旧预算执行失败仍扣手续费，不移动 USDT |

其他集成用例通过管理接口配置匿名 / API key 独立额度、持续 429、签名提交不重发、过期证明、错误签名和重复付款。

`defaults.json` 定义公共环境参数，`scenarios/*.json` 覆盖参数并保存来源。`/__admin/configure` 只接受已有参数，可在运行中改变能量单价、租金单价、库存、回执或委托延迟等。能量阶梯通过 `energy_schedule` 配置，原生索引与 token 余额独立维护。

故障注入由请求路径、次数和提交前后位置控制。例如：

```json
{
  "path": "/v2/buy-resource",
  "attempts": [1],
  "phase": "after",
  "status": 200,
  "body": {}
}
```

这表示服务已经执行付款，再返回不完整确认。它与提交前返回错误具有不同的余额和订单状态。响应丢失目前以不完整 JSON 确认重建，并非 TCP 丢包仿真。

## 每次真实问题的维护流程

1. 记录软件 / 系统版本、触发步骤、相关公开协议字段和顺序。移除用户凭证、签名、API key、订单号及用户地址；用公开测试账户重新构造。
2. 新建独立场景，标注 `schema_version` 与 `provenance`。`incident-model` 表示根据已遇到的问题重建，`synthetic` 表示主动构造，不能把后者当作生产观测。在描述中写明证据来源与重建假设。
3. 先增加能在旧实现中失败的用例。若当前状态模型无法表达故障，先扩充模型及管理接口，保留旧场景和断言。
4. 修复业务代码，验证余额守恒、实际费用、转出金额、资源、记录恢复和提交次数，不能只检查 HTTP 200 或返回了哈希。
5. 跑全部回归。模型与真实观测冲突时，用证据更新模型，说明差异；不能同时修改模型与期望值来掩盖业务错误。

`scripts/package-macos.sh` 已将全部 Core / 集成测试作为打包前置条件，任一失败都会停止构建。当前崩溃修复前的离线签名测试已复现 signal 5；仿真环境保留同一助记词切片路径作为长期回归。

## 边界与后续校准

这是客户端服务协议与状态仿真，不是 java-tron 节点或 TVM。protobuf 仅编码测试所需的 TransferContract / TriggerSmartContract 子集，实际客户端用生成的 protobuf 解码并核对。区块引用为合成值，不实现共识、分叉或完整的交易准入规则。OpenSSL 验证 ECDSA 的 r/s，恢复字节只做结构检查；未实现节点的完整签名恢复路径。

动态能量目前是可控的区块阶梯模型，带宽与扣费也只覆盖客户端当前依赖的规则；未模拟 24 小时资源恢复或租赁一小时后的资源回收。实际协议公式和参数需要用真实网络证据持续校准。GasFree 服务尚未纳入这个环境。测试贯通 Core 服务与真实磁盘记录，未启动 SwiftUI 页面或真实 Touch ID；“重启”用重建交易记录存储模拟，没有杀死并重启 App。

正式发布仍需要真实网络的只读兼容性检查及用户授权的小额转账验收，并在支持的 macOS 版本上验证实际应用。发现新的差异后，继续按上面的流程补充环境与回归场景。
