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
        transferOwnership(initialOwner);
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
        if (!IsSupportedToken[tokenAddress]) {
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
    function BridageInitiateETH(uint256 sourceChainId, uint256 destChainId, address destTokenAddress, address to)
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
        if (!IsSupportedToken[sourceTokenAddress]) {
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

        if (!IsSupportedToken[destTokenAddress]) {
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

    function DepositAndStakingERC20(address _token, uint256 _amount) external nonReentrant whenNotPaused {}

    function IsSupportChainId(uint256 chainId) internal view returns (bool) {
        return IsSupportedChainId[chainId];
    }
}
