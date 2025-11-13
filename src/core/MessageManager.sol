// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./MessageManagerStorage.sol";

contract MessageManager is Initializable, OwnableUpgradeable, ReentrancyGuard, MessageManagerStorage {
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address _poolManagerAddress) public initializer {
        __Ownable_init(initialOwner);
        poolManagerAddress = _poolManagerAddress;
        nextMessageNumber = 1;
    }

    modifier onlyTokenBridge() {
        require(msg.sender == poolManagerAddress, "MessageManager: only token bridge can do this operate");
        _;
    }

    function sendMessage(
        uint256 sourceChainId,
        uint256 destChainId,
        address sourceTokenAddress,
        address destTokenAddress,
        address _from,
        address _to,
        uint256 _value,
        uint256 _fee
    ) external onlyTokenBridge {
        if (_to == address(0)) {
            revert ZeroAddressNotAllowed();
        }
        uint256 messageNumber = nextMessageNumber;
        bytes32 messageHash = keccak256(
            abi.encode(
                sourceChainId,
                destChainId,
                sourceTokenAddress,
                destTokenAddress,
                _from,
                _to,
                _value,
                _fee,
                messageNumber
            )
        );
        nextMessageNumber++;
        sentMessageStatus[messageHash] = true;
        emit MessageSent(
            sourceChainId,
            destChainId,
            sourceTokenAddress,
            destTokenAddress,
            _from,
            _to,
            _fee,
            _value,
            messageNumber,
            messageHash
        );
    }

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
    ) external onlyTokenBridge nonReentrant {
        bytes32 messageHash = keccak256(
            abi.encode(
                sourceChainId, destChainId, sourceTokenAddress, destTokenAddress, _from, _to, _value, _fee, _nonce
            )
        );
        require(!claimMessageStatus[messageHash], "MessageManager: message already claimed");
        claimMessageStatus[messageHash] = true;
        emit MessageClaimed(sourceChainId, destChainId, sourceTokenAddress, destTokenAddress, messageHash, _nonce);
    }
}
