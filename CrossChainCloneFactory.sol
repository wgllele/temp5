// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.28;

/// @title 跨链收款克隆工厂
/// @notice owner 维护 gas 费收款地址，并用 EIP-1167 + CREATE2 克隆收款模板。
/// @dev 代操作的 gas 费打到 `feeRecipient`，不打给 `msg.sender`，避免同一份签名被抢跑。
///      salt 与模板约定一致：`keccak256(abi.encode(recipient))`。
///      克隆公式与 `MultiSig._cloneDeterministic` 相同，deployer = 本合约。
contract CrossChainCloneFactory {
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event FeeRecipientUpdated(address indexed feeRecipient);

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);
    error ZeroAddress();
    error Create2Failed();

    address private _owner;
    address private _feeRecipient;

    modifier onlyOwner() {
        if (_owner != msg.sender) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    constructor(address initOwner, address feeRecipient_) {
        if (initOwner == address(0)) revert OwnableInvalidOwner(address(0));
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        _owner = initOwner;
        _feeRecipient = feeRecipient_;
        emit OwnerChanged(address(0), initOwner);
        emit FeeRecipientUpdated(feeRecipient_);
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function feeRecipient() external view returns (address) {
        return _feeRecipient;
    }

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        emit OwnerChanged(_owner, newOwner);
        _owner = newOwner;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        _feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /// @notice 与收款模板权限校验对齐：`keccak256(abi.encode(recipient))`。
    function computeSalt(address recipient) external pure returns (bytes32) {
        return keccak256(abi.encode(recipient));
    }

    /// @notice 预测 `cloneAccount(impl, salt)` 的地址（未部署也可算）。
    function predictAddress(address impl, bytes32 salt) public view returns (address predicted) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
                impl,
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash))))
        );
    }

    function cloneAccount(address impl, bytes32 salt) external onlyOwner returns (address instance) {
        return _cloneDeterministic(impl, salt);
    }

    function cloneAccounts(address impl, bytes32[] calldata salts)
        external
        onlyOwner
        returns (address[] memory predicteds)
    {
        uint256 length = salts.length;
        predicteds = new address[](length);
        for (uint256 i; i < length; ++i) {
            predicteds[i] = _cloneDeterministic(impl, salts[i]);
        }
    }

    function _cloneDeterministic(address impl, bytes32 salt) internal returns (address instance) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, or(shr(0xe8, shl(0x60, impl)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            mstore(0x20, or(shl(0x78, impl), 0x5af43d82803e903d91602b57fd5bf3))
            instance := create2(0, 0x09, 0x37, salt)
        }
        if (instance == address(0)) revert Create2Failed();
    }
}
