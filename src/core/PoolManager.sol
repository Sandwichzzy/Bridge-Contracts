// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IPoolManager.sol";
import "./PoolManagerStorage.sol";

contract PoolManager is Initializable, OwnableUpgradeable, ReentrancyGuard, PausableUpgradeable, PoolManagerStorage {
    using SafeERC20 for IERC20;

    modifier onlyRelayer() {
        require(msg.sender == relayerAddress, "PoolManager: only relayer can do this operate");
        _;
    }

    modifier onlyWithdrawManager() {
        require(
            msg.sender == address(withdrawManager),
            "PoolManager: onlyWithdrawManager only withdraw manager can call this function"
        );
        _;
    }

    constructor() {
        _disableInitializers();
    }

    receive() external payable {
        depositEthToBridge();
    }

    function initialize(
        address initialOwner,
        address _messageManager,
        address _relayerAddress,
        address _withdrawManager
    ) public initializer {
        __Ownable_init(initialOwner);
        __Pausable_init();

        messageManager = IMessageManager(_messageManager);
        relayerAddress = _relayerAddress;
        withdrawManager = _withdrawManager;
        periodTime = 21 days;
        MinTransferAmount = 0.1 ether;
        PerFee = 10000; // 0.1%
        stakingMessageNumber = 1;
    }

    /*@dev:项目方将资金Eth打入到资金池提供流动性*/
    function depositEthToBridge() public payable whenNotPaused nonReentrant returns (bool) {
        FundingPoolBalance[ETH_ADDRESS] += msg.value;
        emit DepositToken(ETH_ADDRESS, msg.sender, msg.value);
        return true;
    }

    function depositErc20ToBridge(address tokenAddress, uint256 amount)
        public
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        if (!IsSupportToken[tokenAddress]) {
            revert TokenIsNotSupported(tokenAddress);
        }
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        FundingPoolBalance[tokenAddress] += amount;
        emit DepositToken(tokenAddress, msg.sender, amount);
        return true;
    }

    /*
    @dev:从桥里面吧 ETH 和 ERC20 的资金提走
    @param withdrawAddress 提币地址
    @param amount 提币数量
    */
    function withdrawEthFromBridge(address payable withdrawAddress, uint256 amount)
        public
        payable
        onlyWithdrawManager
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        require(
            address(this).balance >= amount, "PoolManager withdrawEthFromBridge: insufficient ETH balance in contract"
        );
        FundingPoolBalance[ETH_ADDRESS] -= amount;
        (bool success,) = withdrawAddress.call{value: amount}("");
        if (!success) {
            return false;
        }
        emit WithdrawToken(ETH_ADDRESS, msg.sender, withdrawAddress, amount);
        return true;
    }

    function withdrawErc20FromBridge(address tokenAddress, address withdrawAddress, uint256 amount)
        public
        onlyWithdrawManager
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        require(
            FundingPoolBalance[tokenAddress] >= amount,
            "PoolManager withdrawEthFromBridge: Insufficient token balance in contract"
        );
        FundingPoolBalance[tokenAddress] -= amount;
        IERC20(tokenAddress).safeTransfer(withdrawAddress, amount);
        emit WithdrawToken(tokenAddress, msg.sender, withdrawAddress, amount);
        return true;
    }

    //BridgeInitiateETH 和 BridgeInitiateERC20 将 ETH 和 ERC20 的资金转入到源链的合约
    function BridgeInitiateETH(uint256 sourceChainId, uint256 destChainId, address destTokenAddress, address to)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        if (sourceChainId != block.chainid) {
            revert sourceChainIdError();
        }
        if (!IsSupportChainId(destChainId)) {
            revert ChainIdIsNotSupported(destChainId);
        }
        if (msg.value < MinTransferAmount) {
            revert LessThanMinTransferAmount(MinTransferAmount, msg.value);
        }

        FundingPoolBalance[ETH_ADDRESS] += msg.value;

        uint256 fee = (msg.value * PerFee) / 1_000_0000;
        uint256 amount = msg.value - fee;

        FeePoolValue[ETH_ADDRESS] += fee;
        messageManager.sendMessage(
            block.chainid, destChainId, ETH_ADDRESS, destTokenAddress, msg.sender, to, amount, fee
        );
        emit InitiateETH(sourceChainId, destChainId, destTokenAddress, msg.sender, to, amount);

        return true;
    }

    function BridgeInitiateERC20(
        uint256 sourceChainId,
        uint256 destChainId,
        address sourceTokenAddress,
        address destTokenAddress,
        address to,
        uint256 value
    ) external nonReentrant whenNotPaused returns (bool) {
        if (sourceChainId != block.chainid) {
            revert sourceChainIdError();
        }
        if (!IsSupportChainId(destChainId)) {
            revert ChainIdIsNotSupported(destChainId); //验证：目标链在我的白名单中
        }
        if (!IsSupportToken[sourceTokenAddress]) {
            revert TokenIsNotSupported(sourceTokenAddress);
        }
        uint256 BalanceBefore = IERC20(sourceTokenAddress).balanceOf(address(this));
        IERC20(sourceTokenAddress).safeTransferFrom(msg.sender, address(this), value);
        uint256 BalanceAfter = IERC20(sourceTokenAddress).balanceOf(address(this));

        uint256 amount = BalanceAfter - BalanceBefore;
        FundingPoolBalance[sourceTokenAddress] += amount;
        uint256 fee = (amount * PerFee) / 1_000_0000;

        amount = amount - fee;
        FeePoolValue[sourceTokenAddress] += fee;
        messageManager.sendMessage(
            block.chainid, destChainId, sourceTokenAddress, destTokenAddress, msg.sender, to, amount, fee
        );
        emit InitiateERC20(sourceChainId, destChainId, sourceTokenAddress, destTokenAddress, msg.sender, to, amount);
        return true;
    }

    //跨链桥的完成函数，在目标链上执行
    function BridgeFinalizeETH(
        uint256 sourceChainId,
        uint256 destChainId,
        address sourceTokenAddress,
        address from,
        address to,
        uint256 amount,
        uint256 _fee,
        uint256 _nonce
    ) external payable nonReentrant whenNotPaused onlyRelayer returns (bool) {
        if (destChainId != block.chainid) {
            revert ChainIdMismatch(destChainId, block.chainid);
        }

        if (!IsSupportChainId(sourceChainId)) {
            revert ChainIdIsNotSupported(sourceChainId);
        }

        (bool _ret,) = payable(to).call{value: amount}("");
        if (!_ret) {
            revert TransferETHFailed();
        }

        FundingPoolBalance[ETH_ADDRESS] -= amount;

        messageManager.claimMessage(
            sourceChainId, destChainId, sourceTokenAddress, ETH_ADDRESS, from, to, amount, _fee, _nonce
        );

        emit FinalizeETH(sourceChainId, destChainId, sourceTokenAddress, address(this), to, amount);

        return true;
    }

    //跨链桥的完成函数，在目标链上执行
    function BridgeFinalizeERC20(
        uint256 sourceChainId,
        uint256 destChainId,
        address from,
        address to,
        address sourceTokenAddress,
        address destTokenAddress,
        uint256 amount,
        uint256 _fee,
        uint256 _nonce
    ) external whenNotPaused onlyRelayer returns (bool) {
        if (destChainId != block.chainid) {
            revert sourceChainIdError(); // 验证：我就是目标链
        }
        // 在跨链桥接中，需要建立双向信任关系：
        if (!IsSupportChainId(sourceChainId)) {
            revert ChainIdIsNotSupported(sourceChainId); // 验证：源链在我的白名单中
        }

        if (!IsSupportToken[destTokenAddress]) {
            revert TokenIsNotSupported(destTokenAddress);
        }

        require(
            IERC20(destTokenAddress).balanceOf(address(this)) >= amount,
            "PoolManager: insufficient token balance for transfer"
        );

        IERC20(sourceTokenAddress).safeTransfer(to, amount);
        FundingPoolBalance[destTokenAddress] -= amount;

        messageManager.claimMessage(
            sourceChainId, destChainId, sourceTokenAddress, destTokenAddress, from, to, amount, _fee, _nonce
        );

        emit FinalizeERC20(sourceChainId, destChainId, sourceTokenAddress, destTokenAddress, address(this), to, amount);

        return true;
    }

    /**
     *
     * staking eth and erc20 *****
     *
     */
    function DepositAndStakingETH() external payable nonReentrant whenNotPaused {
        if (msg.value < MinStakeAmount[address(ETH_ADDRESS)]) {
            revert LessThanMinStakeAmount(MinStakeAmount[address(ETH_ADDRESS)], msg.value);
        }
        // 检查是否存在 ETH 质押池
        if (Pools[address(ETH_ADDRESS)].length == 0) {
            revert NewPoolIsNotCreate(1);
        }
        //获取最新池子
        uint256 PoolIndex = Pools[address(ETH_ADDRESS)].length - 1;
        if (Pools[address(ETH_ADDRESS)][PoolIndex].startTimeStamp > block.timestamp) {
            // 池子还未开始，允许质押
            Users[msg.sender].push(
                User({isWithdrawed: false, StartPoolId: PoolIndex, EndPoolId: 0, token: ETH_ADDRESS, Amount: msg.value})
            );
            Pools[address(ETH_ADDRESS)][PoolIndex].TotalAmount += msg.value;
        } else {
            // 池子已开始，拒绝质押
            revert NewPoolIsNotCreate(PoolIndex + 1);
        }
        FundingPoolBalance[ETH_ADDRESS] += msg.value;
        emit StakingETHEvent(msg.sender, block.chainid, msg.value);
    }

    function DepositAndStakingERC20(address _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (!IsSupportToken[_token]) {
            revert TokenIsNotSupported(_token);
        }
        if (_amount < MinStakeAmount[_token]) {
            revert LessThanMinStakeAmount(MinStakeAmount[_token], _amount);
        }
        uint256 BalanceBefore = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 BalanceAfter = IERC20(_token).balanceOf(address(this));

        _amount = BalanceAfter - BalanceBefore;
        if (Pools[_token].length == 0) {
            revert NewPoolIsNotCreate(1);
        }
        uint256 PoolIndex = Pools[_token].length - 1;
        if (Pools[_token][PoolIndex].startTimeStamp > block.timestamp) {
            Users[msg.sender].push(
                User({isWithdrawed: false, StartPoolId: PoolIndex, EndPoolId: 0, token: _token, Amount: _amount})
            );
            Pools[_token][PoolIndex].TotalAmount += _amount;
        } else {
            revert NewPoolIsNotCreate(PoolIndex + 1);
        }
        FundingPoolBalance[_token] += _amount;
        emit StakingERC20Event(msg.sender, _token, block.chainid, _amount);
    }

    /**
     *
     * withdraw and claim function *****
     *
     */
    function WithdrawAll() external nonReentrant whenNotPaused {
        for (uint256 i = 0; i < SupportTokens.length; i++) {
            WithdrawOrClaimBySimpleAsset(msg.sender, SupportTokens[i], true);
        }
    }

    function ClaimAllReward() external nonReentrant whenNotPaused {
        for (uint256 i = 0; i < SupportTokens.length; i++) {
            WithdrawOrClaimBySimpleAsset(msg.sender, SupportTokens[i], false);
        }
    }

    function WithdrawByID(uint256 i) external nonReentrant whenNotPaused {
        if (i >= Users[msg.sender].length) {
            revert OutOfRange(i, Users[msg.sender].length);
        }
        WithdrawOrClaimBySimpleID(msg.sender, i, true);
    }

    function ClaimbyID(uint256 i) external nonReentrant whenNotPaused {
        if (i >= Users[msg.sender].length) {
            revert OutOfRange(i, Users[msg.sender].length);
        }
        WithdrawOrClaimBySimpleID(msg.sender, i, false);
    }
    //管理员紧急操作

    function QuickSendAssertToUser(address _token, address to, uint256 _amount) external onlyWithdrawManager {
        SendAssertToUser(_token, to, _amount);
    }

    function WithdrawPoolManagerAssetTo(address _token, address to, uint256 _amount) external onlyWithdrawManager {
        SendAssertToUser(_token, to, _amount);
    }

    // 返回用户质押的代币资产
    //   struct KeyValuePair {
    //       address key;    // 代币地址
    //       uint256 value;  // 该代币的总质押本金
    //   }
    function getPrincipal() external view returns (KeyValuePair[] memory) {
        KeyValuePair[] memory result = new KeyValuePair[](SupportTokens.length);
        for (uint256 i = 0; i < SupportTokens.length; i++) {
            uint256 Amount = 0;
            for (uint256 j = 0; j < Users[msg.sender].length; j++) {
                if (Users[msg.sender][j].token == SupportTokens[i]) {
                    if (Users[msg.sender][j].isWithdrawed) {
                        continue; // 跳过已提取的
                    }
                    Amount += Users[msg.sender][j].Amount;
                }
            }
            result[i] = KeyValuePair({key: SupportTokens[i], value: Amount});
        }
        return result;
    }

    function getReward() external view returns (KeyValuePair[] memory) {
        KeyValuePair[] memory result = new KeyValuePair[](SupportTokens.length);
        // n 个代币 遍历所有支持的代币
        for (uint256 i = 0; i < SupportTokens.length; i++) {
            uint256 Reward = 0;
            //遍历用户的所有质押记录 m 笔质押
            for (uint256 j = 0; j < Users[msg.sender].length; j++) {
                if (Users[msg.sender][j].token == SupportTokens[i]) {
                    if (Users[msg.sender][j].isWithdrawed) {
                        continue;
                    }
                    uint256 EndPoolId = Pools[SupportTokens[i]].length - 1;

                    uint256 Amount = Users[msg.sender][j].Amount;
                    uint256 startPoolId = Users[msg.sender][j].StartPoolId;
                    if (startPoolId > EndPoolId) {
                        continue;
                    }
                    // 遍历池子计算奖励
                    for (uint256 k = startPoolId; k < EndPoolId; k++) {
                        if (k > Pools[SupportTokens[i]].length - 1) {
                            revert NewPoolIsNotCreate(k);
                        }
                        uint256 _Reward =
                            (Amount * Pools[SupportTokens[i]][k].TotalFee) / Pools[SupportTokens[i]][k].TotalAmount;
                        Reward += _Reward;
                    }
                }
            }
            result[i] = KeyValuePair({key: SupportTokens[i], value: Reward});
        }
        return result;
    }

    function fetchFundingPoolBalance(address token) external view returns (uint256) {
        return FundingPoolBalance[token];
    }

    function getPoolLength(address _token) external view returns (uint256) {
        return Pools[_token].length;
    }

    function getUserLength(address _user) external view returns (uint256) {
        return Users[_user].length;
    }

    function getPool(address _token, uint256 _index) external view returns (Pool memory) {
        return Pools[_token][_index];
    }

    function getUser(address _user) external view returns (User[] memory) {
        return Users[_user];
    }

    function setMinTransferAmount(uint256 _MinTransferAmount) external onlyRelayer {
        MinTransferAmount = _MinTransferAmount;
        emit SetMinTransferAmount(_MinTransferAmount);
    }

    function setValidChainId(uint256 chainId, bool isValid) external onlyRelayer {
        IsSupportedChainId[chainId] = isValid;
        emit SetValidChainId(chainId, isValid);
    }

    function setSupportERC20Token(address ERC20Address, bool isValid) external onlyRelayer {
        IsSupportToken[ERC20Address] = isValid;
        if (isValid) {
            SupportTokens.push(ERC20Address);
        }
        emit SetSupportTokenEvent(ERC20Address, isValid, block.chainid);
    }

    function setPerFee(uint256 _PerFee) external onlyRelayer {
        require(_PerFee < 1_000_000);
        PerFee = _PerFee;
        emit SetPerFee(_PerFee);
    }

    function setMinStakeAmount(address _token, uint256 _amount) external onlyRelayer {
        if (_amount == 0) {
            revert Zero(_amount);
        }
        MinStakeAmount[_token] = _amount;
        emit SetMinStakeAmountEvent(_token, _amount, block.chainid);
    }

    /*
     * @dev:添加支持的质押代币，并创建初始质押池和桥接池。只有 Relayer 可以调用
     * @param _token 质押代币地址
     * @param _isSupport 是否支持该代币质押
     * @param startTimes 质押池的起始时间戳
     */
    function setSupportToken(address _token, bool _isSupport, uint32 startTimes) external onlyRelayer {
        if (IsSupportToken[_token]) {
            revert TokenIsAlreadySupported(_token, _isSupport);
        }
        IsSupportToken[_token] = _isSupport;
        //genesis pool [startTimes - periodTime, startTimes] 索引 0
        Pools[_token].push(
            Pool({
                startTimeStamp: uint32(startTimes) - periodTime, // 开始时间在过去
                endTimeStamp: startTimes, // 结束时间是传入的 startTimes
                token: _token,
                TotalAmount: 0,
                TotalFee: 0,
                TotalFeeClaimed: 0,
                IsCompleted: false
            })
        );

        //genesis bridge 第一个真正的质押池 [startTimes, startTimes + periodTime]
        Pools[_token].push(
            Pool({
                startTimeStamp: uint32(startTimes),
                endTimeStamp: startTimes + periodTime,
                token: _token,
                TotalAmount: 0,
                TotalFee: 0,
                TotalFeeClaimed: 0,
                IsCompleted: false
            })
        );

        //Next bridge
        SupportTokens.push(_token);
        emit SetSupportTokenEvent(_token, _isSupport, block.chainid);
    }
    /**
     *
     * Relayer function *****
     *
     */

    /*
     * @dev:质押池轮换机制：完成当前质押周期，并创建下一个质押周期。只有 Relayer 可以调用
     * @param CompletePools 完成的质押池列表
     */
    function CompletePoolAndNew(Pool[] memory CompletePools) external payable onlyRelayer {
        for (uint256 i = 0; i < CompletePools.length; i++) {
            address _token = CompletePools[i].token;
            uint256 PoolIndex = Pools[_token].length - 1; // 获取最新池子索引
            //标记当前池完成
            Pools[_token][PoolIndex].IsCompleted = true;
            if (PoolIndex != 0) {
                Pools[_token][PoolIndex].TotalFee = FeePoolValue[_token]; // 将累计的费用分配给这个池子
                FeePoolValue[_token] = 0; // 清空费用池
            }
            uint32 startTimes = Pools[_token][PoolIndex].endTimeStamp; // 新池从旧池结束时间开始
            Pools[_token].push(
                Pool({
                    startTimeStamp: startTimes,
                    endTimeStamp: startTimes + periodTime,
                    token: _token,
                    TotalAmount: Pools[_token][PoolIndex].TotalAmount, // ⚠️ 继承旧池的质押总额
                    TotalFee: 0, // 新池费用从0开始
                    TotalFeeClaimed: 0,
                    IsCompleted: false
                })
            );
            emit CompletePoolEvent(_token, PoolIndex, block.chainid);
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     *
     * internal function *****
     *
     */
    //向用户发送资产（ETH 或 ERC20 代币）
    function SendAssertToUser(address _token, address to, uint256 _amount) internal returns (bool) {
        if (!IsSupportToken[_token]) {
            revert TokenIsNotSupported(_token);
        }
        require((FundingPoolBalance[_token] >= _amount), "PoolManager: insufficient token balance for transfer");
        FundingPoolBalance[_token] -= _amount;
        if (_token == address(ETH_ADDRESS)) {
            if (address(this).balance < _amount) {
                revert NotEnoughETH();
            }
            (bool success,) = payable(to).call{value: _amount}("");
            if (!success) {
                revert TransferETHFailed();
            }
        } else {
            if (IERC20(_token).balanceOf(address(this)) < _amount) {
                revert NotEnoughToken(_token);
            }
            IERC20(_token).safeTransfer(to, _amount);
        }
        return true;
    }

    /*
    @dev:通过质押资产的单一类型（ETH 或 ERC20）进行提取或奖励领取
    @param _user 用户地址
    @param _token 资产地址（ETH_ADDRESS 或 ERC20 地址）
    @param IsWithdraw 是否为提取操作（true=提取本金+奖励，false=仅领取奖励）
    */
    function WithdrawOrClaimBySimpleAsset(address _user, address _token, bool IsWithdraw) internal {
        if (Pools[_token].length == 0) {
            revert NewPoolIsNotCreate(0);
        }
        // 遍历用户的质押记录
        for (uint256 index = Users[_user].length; index > 0; index--) {
            uint256 currentIndex = index - 1;
            if (Users[_user][currentIndex].token == _token) {
                // 处理该代币的质押
                if (Users[_user][currentIndex].isWithdrawed) {
                    continue;
                }
                uint256 EndPoolId = Pools[_token].length - 1;

                uint256 Reward = 0;
                uint256 Amount = Users[_user][currentIndex].Amount;
                uint256 startPoolId = Users[_user][currentIndex].StartPoolId;
                // 从用户开始质押的池子(StartPoolId)到当前最新池子(EndPoolId)，计算奖励
                for (uint256 j = startPoolId; j < EndPoolId; j++) {
                    // 奖励 = (用户质押金额 × 该池总手续费) / 该池总质押量
                    uint256 _Reward = (Amount * Pools[_token][j].TotalFee * 1e18) / Pools[_token][j].TotalAmount;
                    Reward += _Reward / 1e18;
                    Pools[_token][j].TotalFeeClaimed += _Reward;
                }

                Amount += Reward;

                Users[_user][currentIndex].isWithdrawed = true;
                //  如果是提取 (IsWithdraw = true)：
                if (IsWithdraw) {
                    //从当前池中减少用户的质押量
                    Pools[_token][EndPoolId].TotalAmount -= Users[_user][currentIndex].Amount;
                    // 发送本金+奖励
                    SendAssertToUser(_token, _user, Amount);
                    // 删除质押记录（通过 swap-and-pop）
                    if (Users[_user].length > 0) {
                        Users[_user][currentIndex] = Users[_user][Users[_user].length - 1];
                        Users[_user].pop();
                    }
                    emit Withdraw(_user, startPoolId, EndPoolId, block.chainid, _token, Amount - Reward, Reward);
                } else {
                    //如果是领取奖励 (IsWithdraw = false)
                    //更新开始池子 ID 为当前最新池子
                    Users[_user][currentIndex].StartPoolId = EndPoolId;
                    //仅发送奖励
                    SendAssertToUser(_token, _user, Reward);
                    //保留质押记录继续质押
                    emit ClaimReward(_user, startPoolId, EndPoolId, block.chainid, _token, Reward);
                }
            }
        }
    }

    /*
    @dev:据特定的质押记录 ID 来处理用户的提取或领取奖励操作 :针对单个质押记录进行操作
    @param _user 用户地址
    @param index 质押记录索引
    @param IsWithdraw 是否为提取操作（true=提取本金+奖励，false=仅领取奖励）
    */
    function WithdrawOrClaimBySimpleID(address _user, uint256 index, bool IsWithdraw) internal {
        address _token = Users[_user][index].token;
        uint256 EndPoolId = Pools[_token].length - 1;

        uint256 Reward = 0;
        uint256 Amount = Users[_user][index].Amount;
        uint256 startPoolId = Users[_user][index].StartPoolId;
        if (Users[_user][index].isWithdrawed) {
            revert NoReward();
        }
        //遍历从 startPoolId 到 EndPoolId-1 的所有池子
        //每个池子的奖励 = 用户在该池的份额 × 该池的总手续费
        for (uint256 j = startPoolId; j < EndPoolId; j++) {
            // 奖励计算公式：(用户质押金额 × 该池总手续费 × 1e18) / 该池总质押量
            uint256 _Reward = (Amount * Pools[_token][j].TotalFee * 1e18) / Pools[_token][j].TotalAmount;
            Reward += _Reward / 1e18;
            Pools[_token][j].TotalFeeClaimed += _Reward;
        }

        Amount += Reward;

        if (IsWithdraw) {
            //从最新池子中减少用户的质押量
            Pools[_token][EndPoolId].TotalAmount -= Users[_user][index].Amount;
            SendAssertToUser(_token, _user, Amount); // 发送本金 + 奖励给用户
            if (Users[_user].length > 0) {
                Users[_user][index] = Users[_user][Users[_user].length - 1];
                Users[_user].pop();
            }
            emit Withdraw(_user, startPoolId, EndPoolId, block.chainid, _token, Amount - Reward, Reward);
        } else {
            //更新开始池子 ID 为当前最新池子（重置奖励计算起点）
            Users[_user][index].StartPoolId = EndPoolId;
            //仅发送奖励给用户（本金继续质押）
            SendAssertToUser(_token, _user, Reward);
            emit ClaimReward(_user, startPoolId, EndPoolId, block.chainid, _token, Reward);
        }
    }

    function IsSupportChainId(uint256 chainId) internal view returns (bool) {
        return IsSupportedChainId[chainId];
    }
}
