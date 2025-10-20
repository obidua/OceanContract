// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/ICoreConfig.sol";
import "./interfaces/IERC20.sol";

contract MainWallet is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    ICoreConfig public cfg;
    IERC20 public RAMA;

    mapping(address => uint256) public balance; // claimable RAMA

    event Credited(
        address indexed user,
        uint256 amount,
        bytes32 indexed bucket
    );
    event Withdrawn(address indexed user, uint256 amount, uint256 fee);

    function initialize(address _cfg) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        cfg = ICoreConfig(_cfg);
        RAMA = IERC20(cfg.rama());
    }

    function creditDirect(address user, uint256 amount) external {
        _credit(user, amount, "DIRECT");
    }
    function creditSlab(address user, uint256 amount) external {
        _credit(user, amount, "SLAB");
    }
    function creditRoyalty(address user, uint256 amount) external {
        _credit(user, amount, "ROYALTY");
    }
    function creditReward(address user, uint256 amount) external {
        _credit(user, amount, "REWARD");
    }

    function _credit(address user, uint256 amount, bytes32 bucket) internal {
        require(
            msg.sender == cfg.incomeDistributor() ||
                msg.sender == cfg.slabManager() ||
                msg.sender == cfg.royaltyManager() ||
                msg.sender == cfg.rewardVault() ||
                msg.sender == owner(),
            "NOT_AUTH"
        );
        balance[user] += amount;
        emit Credited(user, amount, bucket);
    }

    function withdraw(uint256 amount, address to) external {
        require(balance[msg.sender] >= amount, "INSUFFICIENT");
        balance[msg.sender] -= amount;
        uint256 fee = (amount * cfg.claimFeeBps()) / 10000; // 5%
        require(RAMA.transfer(cfg.treasury(), fee), "FEE_FAIL");
        require(RAMA.transfer(to, amount - fee), "TRANSFER_FAIL");
        emit Withdrawn(msg.sender, amount - fee, fee);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
