//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IMessageManager.sol";
import "../interfaces/IPoolManager.sol";

abstract contract PoolManagerStorage {
    // Mapping from pool ID to pool address
    mapping(bytes32 => address) internal _poolById;

    // Mapping from pool address to pool ID
    mapping(address => bytes32) internal _idByPool;

    // Array of all pool IDs
    bytes32[] internal _allPoolIds;

    // Mapping from pool ID to its index in the _allPoolIds array
    mapping(bytes32 => uint256) internal _allPoolIdsIndex;
}
