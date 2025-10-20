// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/ICoreConfig.sol";

contract OCEANDeFi is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    ICoreConfig public cfg;

    function initialize(address _cfg) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        cfg = ICoreConfig(_cfg);
    }

    // convenience views for frontends
    function addresses() external view returns (address[12] memory out) {
        out[0] = cfg.rama();
        out[1] = cfg.priceOracle();
        out[2] = cfg.userRegistry();
        out[3] = cfg.portfolioManager();
        out[4] = cfg.slabManager();
        out[5] = cfg.incomeDistributor();
        out[6] = cfg.royaltyManager();
        out[7] = cfg.rewardVault();
        out[8] = cfg.freezePolicy();
        out[9] = cfg.adminControl();
        out[10] = cfg.safeWallet();
        out[11] = cfg.mainWallet();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
