# Core Contracts Documentation

本目录包含跨链桥和质押系统的核心合约实现。

## 📁 目录结构

```
src/core/
├── PoolManager.sol          # 资金池和质押管理主合约
├── PoolManagerStorage.sol   # 资金池存储层
├── MessageManager.sol       # 跨链消息管理合约
└── MessageManagerStorage.sol # 消息管理存储层
```

---

## 🏗️ 架构概览

```
┌─────────────────────────────────────────────────────────┐
│                     用户交互层                            │
├─────────────────────────────────────────────────────────┤
│  质押功能              │  跨链桥功能        │  提取功能    │
│  - DepositStaking     │  - BridgeInitiate  │  - Withdraw │
│  - ClaimReward        │  - BridgeFinalize  │  - ClaimAll │
└─────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────┐
│                    PoolManager.sol                       │
│  - 资金池管理                                             │
│  - 质押逻辑                                               │
│  - 跨链桥接口                                             │
│  - 奖励分配                                               │
└─────────────────────────────────────────────────────────┘
                           ↓
┌────────────────────┬───────────────────────────────────┐
│  MessageManager    │    PoolManagerStorage             │
│  - 跨链消息验证     │    - 状态存储                      │
│  - 消息追踪         │    - 池子数据                      │
│  - 防重放攻击       │    - 用户数据                      │
└────────────────────┴───────────────────────────────────┘
```

---

## 📄 合约详细说明

### 1. PoolManager.sol

**主合约 - 资金池和质押管理**

#### 核心功能模块

##### 🔸 流动性管理

提供跨链桥的基础流动性。

```solidity
// 存入 ETH 提供流动性
function depositEthToBridge() public payable returns (bool)

// 存入 ERC20 提供流动性
function depositErc20ToBridge(address tokenAddress, uint256 amount) public returns (bool)

// 管理员提取流动性（仅 withdrawManager）
function withdrawEthFromBridge(address payable withdrawAddress, uint256 amount) public returns (bool)
function withdrawErc20FromBridge(address tokenAddress, address withdrawAddress, uint256 amount) public returns (bool)
```

##### 🔸 跨链桥功能

在不同链之间转移资产。

```solidity
// 源链：发起跨链转账
function BridageInitiateETH(uint256 sourceChainId, uint256 destChainId, address destTokenAddress, address to) external payable

function BridgeInitiateERC20(
    uint256 sourceChainId,
    uint256 destChainId,
    address sourceTokenAddress,
    address destTokenAddress,
    address to,
    uint256 value
) external

// 目标链：完成跨链转账（仅 Relayer）
function BridgeFinalizeETH(...) external payable onlyRelayer
function BridgeFinalizeERC20(...) external onlyRelayer
```

**跨链流程示例：**

```
用户在以太坊              Relayer 监听                用户在 BSC 接收
     │                        │                            │
     ├─ BridageInitiateETH    │                            │
     │  (1 ETH)              │                            │
     │                        │                            │
     │  ─────────────────────>│                            │
     │  发送 1 ETH 到合约      │                            │
     │  扣除手续费 0.001 ETH  │                            │
     │                        │                            │
     │                        ├─ 监听 MessageSent 事件     │
     │                        │                            │
     │                        ├─ 验证交易                  │
     │                        │                            │
     │                        ├─ BridgeFinalizeETH ────────>│
     │                        │  在 BSC 执行               │
     │                        │                            │
     │                        │                            ├─ 收到 0.999 ETH
```

##### 🔸 质押系统

用户质押资产获取跨链手续费奖励。

```solidity
// 质押
function DepositAndStakingETH() external payable
function DepositAndStakingERC20(address _token, uint256 _amount) external

// 提取（本金 + 奖励）
function WithdrawAll() external                    // 提取所有代币
function WithdrawByID(uint256 i) external          // 提取特定质押记录

// 仅领取奖励（本金继续质押）
function ClaimAllReward() external                 // 领取所有代币奖励
function ClaimbyID(uint256 i) external             // 领取特定记录奖励
```

**质押奖励机制：**

```
每个质押周期 (21 天):
├─ 跨链手续费累积到 FeePoolValue
├─ Relayer 调用 CompletePoolAndNew 轮换池子
│  └─ 将 FeePoolValue 分配给完成的池子
└─ 用户领取奖励

用户奖励计算公式:
奖励 = (用户质押金额 / 池子总质押量) × 池子总手续费
```

**池子轮转机制的核心优势：**

```
1. 持续质押 + 灵活提取

  // 用户可以随时质押到"未开始"的池子
  if (Pools[address(ETH_ADDRESS)][PoolIndex].startTimeStamp > block.timestamp) {
      Users[msg.sender].push(...);  // 质押成功
  }

  - ✅ 用户不需要锁定，可以随时提取本金+奖励
  - ✅ 继续质押的用户自动进入下一个周期（TotalAmount继承）
  - ✅ 新用户可以在池子开始前加入，公平参与

  2. 手续费的公平分配机制

  // 计算用户在每个池子的奖励
  uint256 _Reward = (Amount * Pools[_token][j].TotalFee) / Pools[_token][j].TotalAmount;

  分配逻辑：
  - 每个池子的手续费 TotalFee 在周期结束时确定
  - 用户奖励 = (个人质押量 / 池子总质押量) × 池子总手续费
  - 跨多个周期质押的用户累积多个池子的奖励

  示例场景：
  用户A在第1个池子质押 100 ETH
  - 第1个池子（21天）结束：手续费 10 ETH，A获得份额
  - 第2个池子（21天）：A的100 ETH继续质押，再获得新手续费份额
  - 第3个池子：依此类推...

  用户A在第60天提取：获得 3个池子的累积奖励

  3. 激励长期质押者

  // 提取时遍历所有参与的池子
  for (uint256 j = startPoolId; j < EndPoolId; j++) {
      uint256 _Reward = (Amount * Pools[_token][j].TotalFee) / Pools[_token][j].TotalAmount;
      Reward += _Reward;
  }

  - 质押时间越长，参与的池子周期越多
  - 累积的奖励越多（复利效应）
  - 鼓励用户长期持有，增加流动性稳定性

  4. Gas效率优化

  对比传统方案：
  - ❌ 实时计算奖励：每次桥接都要更新所有质押者的奖励（O(n)操作）
  - ✅ 池子轮转：奖励在提取时才计算，桥接时只累加 FeePoolValue（O(1)操作）

  // 桥接时只需累加手续费（极低Gas）
  FeePoolValue[ETH_ADDRESS] += fee;

  // 提取时才遍历池子计算（由用户承担Gas）
  for (uint256 j = startPoolId; j < EndPoolId; j++) {
      // 计算奖励...
  }
```

##### 🔸 查询函数

```solidity
// 查询用户质押本金
function getPrincipal() external view returns (KeyValuePair[] memory)

// 查询用户未领取奖励
function getReward() external view returns (KeyValuePair[] memory)

// 查询资金池余额
function fetchFundingPoolBalance(address token) external view returns (uint256)

// 查询池子信息
function getPoolLength(address _token) external view returns (uint256)
function getPool(address _token, uint256 _index) external view returns (Pool memory)

// 查询用户信息
function getUserLength(address _user) external view returns (uint256)
function getUser(address _user) external view returns (User[] memory)
```

##### 🔸 管理员功能

```solidity
// Relayer 权限
function CompletePoolAndNew(Pool[] memory CompletePools) external onlyRelayer
function setMinTransferAmount(uint256 _MinTransferAmount) external onlyReLayer
function setValidChainId(uint256 chainId, bool isValid) external onlyReLayer
function setSupportToken(address _token, bool _isSupport, uint32 startTimes) external onlyReLayer
function setPerFee(uint256 _PerFee) external onlyReLayer
function setMinStakeAmount(address _token, uint256 _amount) external onlyReLayer

// Owner 权限
function pause() external onlyOwner
function unpause() external onlyOwner

// WithdrawManager 权限
function QuickSendAssertToUser(address _token, address to, uint256 _amount) external onlyWithdrawManager
```

#### 关键数据结构

```solidity
// 质押池
struct Pool {
    uint32 startTimestamp;     // 池子开始时间
    uint32 endTimestamp;       // 池子结束时间
    address token;             // 代币地址
    uint256 TotalAmount;       // 总质押量
    uint256 TotalFee;          // 总手续费
    uint256 TotalFeeClaimed;   // 已领取的手续费
    bool IsCompleted;          // 是否已完成
}

// 用户质押记录
struct User {
    bool isWithdrawed;         // 是否已提取
    uint256 StartPoolId;       // 开始质押的池子ID
    uint256 EndPoolId;         // 结束池子ID（暂未使用）
    address token;             // 质押的代币
    uint256 Amount;            // 质押金额
}

// 键值对（用于查询返回）
struct KeyValuePair {
    address key;               // 代币地址
    uint256 value;             // 数值（本金或奖励）
}
```

#### 权限控制

| 角色                | 权限                         | 说明                   |
| ------------------- | ---------------------------- | ---------------------- |
| **Owner**           | 暂停/恢复合约                | 紧急情况下控制合约状态 |
| **Relayer**         | 执行跨链、轮换池子、设置参数 | 核心运营角色           |
| **WithdrawManager** | 提取流动性、紧急转账         | 资金管理角色           |
| **普通用户**        | 质押、提取、跨链             | 日常操作               |

---

### 2. PoolManagerStorage.sol

**存储层 - 状态变量定义**

#### 状态变量

```solidity
// 常量
address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

// 配置参数
uint32 public periodTime;              // 质押周期（默认 21 天）
uint256 public MinTransferAmount;      // 最小跨链金额
uint256 public PerFee;                 // 手续费率（默认 10000 = 0.1%）
uint256 public stakingMessageNumber;   // 质押消息编号

// 角色地址
address public relayerAddress;         // Relayer 地址
address public withdrawManager;        // 提款管理员地址
IMessageManager public messageManager; // 消息管理器合约

// 支持的代币
address[] public SupportTokens;        // 支持的代币列表

// 映射
mapping(uint256 => bool) public IsSupportedChainId;        // 支持的链ID
mapping(address => bool) public IsSupportToken;            // 支持的代币
mapping(address => uint256) public FundingPoolBalance;     // 资金池余额
mapping(address => uint256) public FeePoolValue;           // 手续费池余额
mapping(address => uint256) public MinStakeAmount;         // 最小质押金额
mapping(address => Pool[]) public Pools;                   // 质押池列表
mapping(address => User[]) public Users;                   // 用户质押记录
```

---

### 3. MessageManager.sol

**消息管理器 - 跨链消息验证**

#### 核心功能

##### 发送消息（源链）

```solidity
function sendMessage(
    uint256 sourceChainId,
    uint256 destChainId,
    address sourceTokenAddress,
    address destTokenAddress,
    address _from,
    address _to,
    uint256 _value,
    uint256 _fee
) external onlyTokenBridge
```

**功能：**

1. 生成唯一的消息哈希
2. 递增消息编号（nonce）
3. 标记消息为已发送
4. 触发 `MessageSent` 事件供 Relayer 监听

##### 认领消息（目标链）

```solidity
function claimMessage(
    uint256 sourceChainId,
    uint256 destChainId,
    address sourceTokenAddress,
    address destTokenAddress,
    address _from,
    address _to,
    uint256 _value,
    uint256 _fee,
    uint256 _nonce
) external onlyTokenBridge nonReentrant
```

**功能：**

1. 验证消息哈希
2. 检查消息是否已被认领（防重放）
3. 标记消息为已认领
4. 触发 `MessageClaimed` 事件

#### 安全机制

```
防重放攻击:
├─ 源链: sentMessageStatus[messageHash] = true
└─ 目标链: claimMessageStatus[messageHash] = true

消息唯一性:
messageHash = keccak256(
    sourceChainId,
    destChainId,
    sourceToken,
    destToken,
    from,
    to,
    value,
    fee,
    nonce  ← 每条消息唯一
)
```

---

### 4. MessageManagerStorage.sol

**消息存储层**

```solidity
abstract contract MessageManagerStorage is IMessageManager {
    uint256 public nextMessageNumber;                  // 下一个消息编号
    address public poolManagerAddress;                 // PoolManager 合约地址

    mapping(bytes32 => bool) public sentMessageStatus;   // 已发送的消息
    mapping(bytes32 => bool) public claimMessageStatus;  // 已认领的消息
}
```

---

## 🔄 完整的跨链流程

### 步骤 1: 用户在源链发起跨链

```solidity
// 用户在以太坊调用
poolManager.BridageInitiateETH{value: 1 ether}(
    1,      // sourceChainId: Ethereum
    56,     // destChainId: BSC
    WBNB,   // destTokenAddress
    user    // to
);
```

**合约执行：**

1. 验证链 ID、金额
2. 收取用户的 1 ETH
3. 计算手续费：0.001 ETH
4. 实际跨链金额：0.999 ETH
5. 调用 `messageManager.sendMessage()`
6. 触发 `InitiateETH` 和 `MessageSent` 事件

### 步骤 2: Relayer 监听和中继

```javascript
// Relayer 监听源链事件
poolManager.on("MessageSent", async (event) => {
  const { sourceChainId, destChainId, messageHash, ...params } = event;

  // 验证交易确认数
  await waitForConfirmations(event.transactionHash, 12);

  // 在目标链执行 Finalize
  await destPoolManager.BridgeFinalizeETH(params);
});
```

### 步骤 3: 在目标链完成跨链

```solidity
// Relayer 在 BSC 调用
poolManager.BridgeFinalizeETH{value: 0.999 ether}(
    1,      // sourceChainId: Ethereum
    56,     // destChainId: BSC
    ETH_ADDRESS,
    user,   // from
    user,   // to
    0.999 ether,
    0.001 ether,
    nonce
);
```

**合约执行：**

1. 验证链 ID、Relayer 权限
2. 向用户发送 0.999 ETH
3. 调用 `messageManager.claimMessage()` 防重放
4. 触发 `FinalizeETH` 和 `MessageClaimed` 事件

---

## 💰 质押和奖励流程

### 场景：用户质押 ETH 获取手续费奖励

#### 1. 初始化代币支持（Owner/Relayer）

```solidity
// 添加 ETH 质押支持
poolManager.setSupportToken(
    ETH_ADDRESS,
    true,
    block.timestamp + 1 days  // 1天后开始接受质押
);

// 结果：创建两个池子
// Pool 0: 创世池（占位符）
// Pool 1: 第一个真实质押池（21天周期）
```

#### 2. 用户质押

```solidity
// 用户质押 10 ETH
poolManager.DepositAndStakingETH{value: 10 ether}();

// 记录创建：
// Users[user].push({
//     isWithdrawed: false,
//     StartPoolId: 1,
//     token: ETH_ADDRESS,
//     Amount: 10 ether
// });
```

#### 3. 手续费累积

```
21 天内的跨链交易:
├─ 交易 1: 1 ETH × 0.1% = 0.001 ETH
├─ 交易 2: 5 ETH × 0.1% = 0.005 ETH
├─ 交易 3: 2 ETH × 0.1% = 0.002 ETH
└─ ...

累积到 FeePoolValue[ETH_ADDRESS] = 0.5 ETH
```

#### 4. 池子轮换（Relayer）

```solidity
// 21 天后，Relayer 轮换池子
Pool[] memory pools = new Pool[](1);
pools[0].token = ETH_ADDRESS;
poolManager.CompletePoolAndNew(pools);

// 执行：
// 1. 标记 Pool 1 为完成
// 2. 将 0.5 ETH 手续费分配给 Pool 1
// 3. 创建新的 Pool 2，继承所有质押
```

#### 5. 用户领取奖励

```solidity
// 查询奖励
KeyValuePair[] memory rewards = poolManager.getReward();
// 返回: { key: ETH_ADDRESS, value: 0.05 ether }
// 计算: (10 ETH / 100 ETH总质押) × 0.5 ETH手续费 = 0.05 ETH

// 领取奖励（本金继续质押）
poolManager.ClaimAllReward();

// 或者提取本金+奖励
poolManager.WithdrawAll();
```

---

## ⚠️ 安全考虑

### 已实现的安全措施

1. ✅ **防重入攻击**

   - 使用 `nonReentrant` 修饰符
   - CEI 模式（部分函数）

2. ✅ **防重放攻击**

   - MessageManager 的消息哈希验证
   - nonce 机制

3. ✅ **权限控制**

   - `onlyOwner`, `onlyRelayer`, `onlyWithdrawManager`
   - 多角色权限分离

4. ✅ **暂停机制**

   - 紧急情况下可暂停合约

5. ✅ **安全数学运算**
   - 使用 SafeERC20 处理代币转账
   - 防止整数溢出（Solidity 0.8+）

## 📊 合约交互图

```
┌─────────────┐
│    User     │
└──────┬──────┘
       │
       │ 1. 质押/跨链/提取
       ↓
┌─────────────────────────────┐
│      PoolManager.sol        │
│  ┌─────────────────────────┐│
│  │  流动性管理              ││
│  │  - depositEthToBridge   ││
│  │  - withdrawEthFromBridge││
│  └─────────────────────────┘│
│  ┌─────────────────────────┐│
│  │  跨链桥功能              ││
│  │  - BridageInitiateETH   ││
│  │  - BridgeFinalizeETH    ││
│  └─────────────────────────┘│
│  ┌─────────────────────────┐│
│  │  质押系统                ││
│  │  - DepositAndStaking    ││
│  │  - WithdrawAll          ││
│  │  - ClaimReward          ││
│  └─────────────────────────┘│
└───────┬──────────────────┬──┘
        │                  │
        │ 2. 发送/认领消息 │
        ↓                  │
┌────────────────────┐     │
│ MessageManager.sol │     │
│  - sendMessage     │     │
│  - claimMessage    │     │
│  - 防重放验证       │     │
└────────────────────┘     │
                           │
                           │ 3. 读写状态
                           ↓
        ┌──────────────────────────────┐
        │  Storage Layer               │
        │  ┌───────────────────────────┤
        │  │ PoolManagerStorage        │
        │  │  - Pools                  │
        │  │  - Users                  │
        │  │  - FundingPoolBalance     │
        │  └───────────────────────────┤
        │  │ MessageManagerStorage     │
        │  │  - sentMessageStatus      │
        │  │  - claimMessageStatus     │
        │  └───────────────────────────┘
        └──────────────────────────────┘
```

---

## 🔧 配置参数

| 参数                | 默认值       | 说明         | 修改函数               |
| ------------------- | ------------ | ------------ | ---------------------- |
| `periodTime`        | 21 days      | 质押周期     | 初始化时设置           |
| `MinTransferAmount` | 0.1 ether    | 最小跨链金额 | `setMinTransferAmount` |
| `PerFee`            | 10000 (0.1%) | 手续费率     | `setPerFee`            |
| `MinStakeAmount`    | 按代币设置   | 最小质押金额 | `setMinStakeAmount`    |

---

## 📝 事件列表

### PoolManager 事件

```solidity
event DepositToken(address indexed token, address indexed from, uint256 amount);
event WithdrawToken(address indexed token, address indexed operator, address indexed to, uint256 amount);
event InitiateETH(uint256 indexed sourceChainId, uint256 indexed destChainId, address destTokenAddress, address indexed from, address to, uint256 amount);
event InitiateERC20(uint256 indexed sourceChainId, uint256 indexed destChainId, address sourceTokenAddress, address destTokenAddress, address indexed from, address to, uint256 amount);
event FinalizeETH(uint256 indexed sourceChainId, uint256 indexed destChainId, address sourceTokenAddress, address indexed from, address to, uint256 amount);
event FinalizeERC20(uint256 indexed sourceChainId, uint256 indexed destChainId, address sourceTokenAddress, address destTokenAddress, address indexed from, address to, uint256 amount);
event StakingETHEvent(address indexed user, uint256 indexed chainId, uint256 amount);
event StakingERC20Event(address indexed user, address indexed token, uint256 indexed chainId, uint256 amount);
event Withdraw(address indexed user, uint256 startPoolId, uint256 endPoolId, uint256 indexed chainId, address indexed token, uint256 amount, uint256 reward);
event ClaimReward(address indexed user, uint256 startPoolId, uint256 endPoolId, uint256 indexed chainId, address indexed token, uint256 reward);
event CompletePoolEvent(address indexed token, uint256 indexed poolId, uint256 indexed chainId);
event SetSupportTokenEvent(address indexed token, bool isSupport, uint256 indexed chainId);
event SetMinStakeAmountEvent(address indexed token, uint256 amount, uint256 indexed chainId);
event SetMinTransferAmount(uint256 amount);
event SetValidChainId(uint256 indexed chainId, bool isValid);
event SetPerFee(uint256 fee);
```

### MessageManager 事件

```solidity
event MessageSent(
    uint256 indexed sourceChainId,
    uint256 indexed destChainId,
    address sourceTokenAddress,
    address destTokenAddress,
    address indexed from,
    address to,
    uint256 fee,
    uint256 value,
    uint256 messageNumber,
    bytes32 messageHash
);

event MessageClaimed(
    uint256 indexed sourceChainId,
    uint256 indexed destChainId,
    address sourceTokenAddress,
    address destTokenAddress,
    bytes32 indexed messageHash,
    uint256 nonce
);
```

---

## 🚀 部署指南

### 1. 部署顺序

```solidity
// 1. 部署 MessageManager
MessageManager messageManager = new MessageManager();
messageManager.initialize(owner, address(0)); // poolManager地址稍后设置

// 2. 部署 PoolManager
PoolManager poolManager = new PoolManager();
poolManager.initialize(
    owner,
    address(messageManager),
    relayerAddress,
    withdrawManagerAddress
);

// 3. 更新 MessageManager 的 poolManager 地址
messageManager.updatePoolManager(address(poolManager)); // 需要添加此函数
```

### 2. 初始化配置

```solidity
// 设置支持的链
poolManager.setValidChainId(1, true);   // Ethereum
poolManager.setValidChainId(56, true);  // BSC
poolManager.setValidChainId(137, true); // Polygon

// 添加代币支持并创建质押池
poolManager.setSupportToken(
    ETH_ADDRESS,
    true,
    block.timestamp + 1 days
);

// 设置质押参数
poolManager.setMinStakeAmount(ETH_ADDRESS, 0.1 ether);
poolManager.setPerFee(10000); // 0.1%
```

### 3. 提供初始流动性

```solidity
// 项目方提供初始流动性
poolManager.depositEthToBridge{value: 100 ether}();
```

---

## 📚 使用示例

### 用户质押 ETH

```javascript
const tx = await poolManager.DepositAndStakingETH({
  value: ethers.utils.parseEther("10"),
});
await tx.wait();
console.log("质押成功！");
```

### 用户跨链转账

```javascript
// 从以太坊跨 1 ETH 到 BSC
const tx = await poolManager.BridageInitiateETH(
  1, // Ethereum
  56, // BSC
  WBNB_ADDRESS,
  userAddress,
  { value: ethers.utils.parseEther("1") }
);
await tx.wait();
console.log("跨链交易已发起！");
```

### 查询和领取奖励

```javascript
// 查询奖励
const rewards = await poolManager.getReward();
console.log("ETH 奖励:", ethers.utils.formatEther(rewards[0].value));

// 领取奖励
const tx = await poolManager.ClaimAllReward();
await tx.wait();
console.log("奖励已领取！");
```

---

cast send --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY 0x015DD02C6D1CF3f1711dcf453ed4b4f34B778E65 "setValidChainId(uint256,bool)" 11155111 true

cast send --rpc-url $S_URP_URL --private-key $PRIVATE_KEY 0x9B3F87aa9ABbC18b78De9fF245cc945F794F7559 "setValidChainId(uint256,bool)" 90101 true

cast send --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY 0x9B3F87aa9ABbC18b78De9fF245cc945F794F7559 "setSupportERC20Token(address,bool)" 0x12E60438898FB3b4aac8439DEeD57194Dc9C87aa true
