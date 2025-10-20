// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICoreConfig {
    // Core addresses

    function owner() external view returns (address);
    function rama() external view returns (address);
    function priceOracle() external view returns (address);

    // Module addresses
    function userRegistry() external view returns (address);
    function portfolioManager() external view returns (address);
    function slabManager() external view returns (address);
    function incomeDistributor() external view returns (address);
    function royaltyManager() external view returns (address);
    function rewardVault() external view returns (address);
    function freezePolicy() external view returns (address);
    function adminControl() external view returns (address);
    function safeWallet() external view returns (address);
    function mainWallet() external view returns (address);
    function treasury() external view returns (address);

    // Params
    function getUSDMinStake() external view returns (uint256); // e.g., 50e18
    function claimFeeBps() external view returns (uint16); // e.g., 500 = 5%
    function exitFeeBps() external view returns (uint16); // e.g., 2000 = 20%
    function capX() external view returns (uint256); // e.g., 4e18 = 4x
}
