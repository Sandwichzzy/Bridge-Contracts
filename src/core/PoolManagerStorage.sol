//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IMessageManager.sol";
import "../interfaces/IPoolManager.sol";

abstract contract PoolManagerStorage is IPoolManager {
    address public constant ETH_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    uint32 public periodTime;

    uint256 public MinTransferAmount;
    uint256 public PerFee; //0.1%
    uint256 public stakingMessageNumber;

    address public relayerAddress;

    IMessageManager public messageManager;

    address[] public SupportTokens;
    address public assertBalanceMessager;
    address public withdrawManager;

    mapping(uint256 => bool) public IsSupportedChainId;
    mapping(address => bool) public IsSupportToken;
    mapping(address => uint256) public FundingPoolBalance;
    // token address => fee pool value
    mapping(address => uint256) public FeePoolValue;
    // token address => min stake amount
    mapping(address => uint256) public MinStakeAmount;

    // token address => pool list
    mapping(address => Pool[]) public Pools;
    // user address => user staking info list
    mapping(address => User[]) public Users;
}
