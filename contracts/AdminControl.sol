// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/ICoreConfig.sol";

contract AdminControl is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    ICoreConfig public cfg;

    struct Bypass {
        bool full;
        bool legA;
        bool legB;
        bool legC;
        bool slab;
        bool royalty;
        bool rewards;
    }
    mapping(address => Bypass) public bypasses;

    mapping(address => bool) public superUser;
    mapping(address => uint8) public superUserSlab; // manual maximal slab allowed to assign to directs (self-5%)

    event BypassSet(address indexed user, Bypass bp);
    event SuperUserSet(address indexed user, bool enabled, uint8 slab);

    function initialize(address _cfg) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        cfg = ICoreConfig(_cfg);
    }

    function setBypass(address user, Bypass calldata bp) external onlyOwner {
        bypasses[user] = bp;
        emit BypassSet(user, bp);
    }

    function setSuperUser(
        address user,
        bool enabled,
        uint8 slab
    ) external onlyOwner {
        superUser[user] = enabled;
        superUserSlab[user] = slab;
        emit SuperUserSet(user, enabled, slab);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
