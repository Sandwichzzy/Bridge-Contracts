## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

1.  不同链的原生代币不同

// 场景 1: ETH (Ethereum) -> BNB (BSC)
sourceChain: Ethereum, sourceToken: ETH_ADDRESS
destChain: BSC, destToken: WBNB (wrapped BNB)

// 场景 2: ETH (Ethereum) -> MATIC (Polygon)  
 sourceChain: Ethereum, sourceToken: ETH_ADDRESS
destChain: Polygon, destToken: WMATIC (wrapped MATIC)

2. Wrapped Token 映射

ETH 在跨链时可能需要映射到：

- 目标链的原生币：ETH → BNB
- Wrapped 版本：ETH → WETH (在目标链上)
- 桥接代币：ETH → bridgedETH

3. 实际使用场景

// 从以太坊跨 1 ETH 到 BSC
BridageInitiateETH(
sourceChainId: 1, // Ethereum
destChainId: 56, // BSC
destTokenAddress: WBNB, // 目标链上映射为 WBNB
to: 0x123...
)

4. 代码中的使用

在 src/core/PoolManager.sol:145-146：
messageManager.sendMessage(
block.chainid, destChainId, ETH_ADDRESS, destTokenAddress, // 记录映射关系
msg.sender, to, amount, fee
);

这个 destTokenAddress 会被存储在跨链消息中，告诉目标链：

- "我收到了源链的 ETH"
- "我应该给用户发送 destTokenAddress 对应的资产"

为什么 BridgeFinalizeETH 不需要？

因为 Finalize 函数在目标链执行，它已经知道：

1. 接收到的是什么代币（从消息中读取）
2. 需要发送原生 ETH（通过 call{value: amount}）

Relayer 调用 Finalize 时已经验证了映射关系，所以不需要再传入。

总结对比

| 函数               | 位置   | destTokenAddress | 原因                             |
| ------------------ | ------ | ---------------- | -------------------------------- |
| BridageInitiateETH | 源链   | ✅ 需要          | 告诉系统目标链上应该发什么代币   |
| BridgeFinalizeETH  | 目标链 | ❌ 不需要        | 已从消息中知道，直接发送原生 ETH |

押池周期轮换函数 使用场景示例

// 假设有 ETH 和 USDT 两个质押池，都运行了 21 天
Pool[] memory pools = new Pool[](2);
pools[0].token = ETH_ADDRESS;
pools[1].token = USDT_ADDRESS;

// Relayer 调用完成旧池并创建新池
poolManager.CompletePoolAndNew(pools);

// 结果：
// - 旧的 ETH 池和 USDT 池被标记为完成
// - 累计的手续费被分配给旧池
// - 新的 ETH 池和 USDT 池被创建，用户质押自动延续

| 特性     | WithdrawOrClaimBySimpleID      | WithdrawOrClaimBySimpleAsset      |
| -------- | ------------------------------ | --------------------------------- |
| 操作范围 | 针对单个质押记录（通过 index） | 针对某个代币的所有质押记录        |
| 遍历方式 | 直接访问指定 index             | 遍历用户所有记录，筛选代币类型    |
| 使用场景 | 用户想提取/领取特定的一笔质押  | 用户想提取/领取某个代币的所有质押 |
| 效率     | 更高效（单次操作）             | 需要遍历，效率较低                |
