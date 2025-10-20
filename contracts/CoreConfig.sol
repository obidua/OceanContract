// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/ICoreConfig.sol";
import "./libraries/OceanErrors.sol";

contract CoreConfig is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ICoreConfig
{
    address public override rama;
    address public override priceOracle;

    address public override userRegistry;
    address public override portfolioManager;
    address public override slabManager;
    address public override incomeDistributor;
    address public override royaltyManager;
    address public override rewardVault;
    address public override freezePolicy;
    address public override adminControl;
    address public override safeWallet;
    address public override mainWallet;
    address public override treasury;

    uint256 private USD_MIN_STAKE; // 50e18
    uint16 private CLAIM_FEE_BPS; // 500 = 5%
    uint16 private EXIT_FEE_BPS; // 2000 = 20%
    uint256 private CAP_X; // 4e18

    event AddressSet(bytes32 indexed key, address indexed value);
    event ParamsSet(
        uint256 minStake,
        uint16 claimFee,
        uint16 exitFee,
        uint256 capX
    );

    function initialize(
        address _rama,
        address _priceOracle,
        address _treasury
    ) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        require(
            _rama != address(0) &&
                _priceOracle != address(0) &&
                _treasury != address(0),
            OceanErrors.ZeroAddress
        );
        rama = _rama;
        priceOracle = _priceOracle;
        treasury = _treasury;
        USD_MIN_STAKE = 10e6;
        CLAIM_FEE_BPS = 500;
        EXIT_FEE_BPS = 2000;
        CAP_X = 4e18;
    }

    // --- Admin setters ---
    function setAddress(bytes32 key, address value) external onlyOwner {
        require(value != address(0), OceanErrors.ZeroAddress);
        if (key == keccak256("userRegistry")) userRegistry = value;
        else if (key == keccak256("portfolioManager")) portfolioManager = value;
        else if (key == keccak256("slabManager")) slabManager = value;
        else if (key == keccak256("incomeDistributor"))
            incomeDistributor = value;
        else if (key == keccak256("royaltyManager")) royaltyManager = value;
        else if (key == keccak256("rewardVault")) rewardVault = value;
        else if (key == keccak256("freezePolicy")) freezePolicy = value;
        else if (key == keccak256("adminControl")) adminControl = value;
        else if (key == keccak256("safeWallet")) safeWallet = value;
        else if (key == keccak256("mainWallet")) mainWallet = value;
        else if (key == keccak256("priceOracle")) priceOracle = value;
        else if (key == keccak256("treasury")) treasury = value;
        else if (key == keccak256("rama")) rama = value;
        else revert("UNKNOWN_KEY");
        emit AddressSet(key, value);
    }

    function setParams(
        uint256 minStake,
        uint16 claimFee,
        uint16 exitFee,
        uint256 capX_
    ) external onlyOwner {
        USD_MIN_STAKE = minStake;
        CLAIM_FEE_BPS = claimFee;
        EXIT_FEE_BPS = exitFee;
        CAP_X = capX_;
        emit ParamsSet(minStake, claimFee, exitFee, capX_);
    }


    function setUSDMinStake(uint256 minStake) external onlyOwner {
        USD_MIN_STAKE = minStake;
    }

    // --- Views ---
    function getUSDMinStake() external view override returns (uint256) {
        return USD_MIN_STAKE;
    }
    function claimFeeBps() external view override returns (uint16) {
        return CLAIM_FEE_BPS;
    }
    function exitFeeBps() external view override returns (uint16) {
        return EXIT_FEE_BPS;
    }
    function capX() external view override returns (uint256) {
        return CAP_X;
    }

    // Disambiguate multiple base declarations of owner()
    function owner()
        public
        view
        override(OwnableUpgradeable, ICoreConfig)
        returns (address)
    {
        return super.owner();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
