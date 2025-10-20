// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./interfaces/ICoreConfig.sol";
import "./interfaces/IUserRegistry.sol";
import "./libraries/OceanErrors.sol";
import "./interfaces/ISafeWallet.sol";

contract RoyaltyManager is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    ICoreConfig public cfg;
    IUserRegistry public users;

    // --- Reference table (USD 1e18) for UI/analytics ---
    struct RoyaltyTier {
        uint256 teamBusiness;
        uint256 monthlyUSD;
    }
    RoyaltyTier[] public tiers;

    // --- Merkle monthly ---
    mapping(uint64 => bytes32) public monthRoot; // monthId => merkle root
    mapping(uint64 => mapping(address => bool)) public claimed; // monthId => user => claimed?

    // --- Lean per-user state (informational) ---
    struct RoyaltyState {
        uint8 lastPaidTier; // 0..14
        uint64 lastPaidMonthEpoch; // e.g., YYYYMM as uint64
        bool paused; // informational (publisher decides & sets)
    }
    mapping(address => RoyaltyState) public royalty;

    // Optional caches for transparency (not required for payout correctness)
    mapping(address => uint256) public tNowCache; // latest qualified T used for month root (USD 1e18)
    mapping(address => uint256) public t60dAgoCache; // baseline qualified T from ~60 days earlier (USD 1e18)

    event RoyaltyRootSet(uint64 indexed monthId, bytes32 root);
    event RoyaltyPaid(
        address indexed user,
        uint64 indexed monthId,
        uint8 tierIdx,
        uint256 ramaAmount
    );
    event RoyaltyMetaSet(
        address indexed user,
        uint64 monthId,
        bool paused,
        uint256 tNow,
        uint256 t60dAgo
    );

    modifier onlyDistributor() {
        require(
            msg.sender == cfg.adminControl() || msg.sender == owner(),
            OceanErrors.NotAuthorized
        );
        _;
    }

    function initialize(address _cfg) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        cfg = ICoreConfig(_cfg);
        users = IUserRegistry(cfg.userRegistry());

        // Full table per spec (USD 1e18)
        tiers.push(RoyaltyTier(5000e18, 30e18));
        tiers.push(RoyaltyTier(10000e18, 80e18));
        tiers.push(RoyaltyTier(20000e18, 200e18));
        tiers.push(RoyaltyTier(60000e18, 500e18));
        tiers.push(RoyaltyTier(120000e18, 1000e18));
        tiers.push(RoyaltyTier(300000e18, 1500e18));
        tiers.push(RoyaltyTier(600000e18, 2500e18));
        tiers.push(RoyaltyTier(1500000e18, 5000e18));
        tiers.push(RoyaltyTier(3000000e18, 8000e18));
        tiers.push(RoyaltyTier(5000000e18, 12000e18));
        tiers.push(RoyaltyTier(10000000e18, 20000e18));
        tiers.push(RoyaltyTier(30000000e18, 40000e18));
        tiers.push(RoyaltyTier(50000000e18, 50000e18));
        tiers.push(RoyaltyTier(100000000e18, 100000e18));
    }

    // === Merkle monthly admin ===

    /// @notice Set the royalty Merkle root for a given month.
    /// @dev monthId format: e.g., YYYYMM (202510 for Oct 2025) or unix month start.
    function setMonthlyRoot(
        uint64 monthId,
        bytes32 root
    ) external onlyDistributor {
        monthRoot[monthId] = root;
        emit RoyaltyRootSet(monthId, root);
    }

    /// @notice (Optional) Record meta for a user used in this month's decision (UI/audit).
    /// @dev This lets your publisher store paused flag and snapshot T values for transparency.
    function setUserRoyaltyMeta(
        address user,
        uint64 monthId,
        bool paused_,
        uint256 tNowUsd,
        uint256 t60dAgoUsd
    ) external onlyDistributor {
        // mark paused status & caches; lastPaid fields are updated on successful claim

        //    uint8 lastPaidTier; // 0..14
        // uint64 lastPaidMonthEpoch; // e.g., YYYYMM as uint64
        // bool paused; // informational (publisher decides & sets)
        RoyaltyState storage st = royalty[user];
        st.paused = paused_;
        tNowCache[user] = tNowUsd;
        t60dAgoCache[user] = t60dAgoUsd;
        emit RoyaltyMetaSet(user, monthId, paused_, tNowUsd, t60dAgoUsd);
    }

    // === Claims ===

    /// @notice Claim this month's royalty (RAMA already computed off-chain).
    /// @param monthId    Month identifier (e.g., YYYYMM)
    /// @param amountRama RAMA wei to be credited
    /// @param tierIdx    The tier index used in the off-chain decision (0..14)
    /// @param proof      Merkle proof against the month's root
    function claimRoyalty(
        uint64 monthId,
        uint256 amountRama,
        uint256 amountInUSD,
        uint8 tierIdx,
        bytes32[] calldata proof
    ) external {
        bytes32 root = monthRoot[monthId];
        require(root != bytes32(0), "NO_ROOT");
        require(!claimed[monthId][msg.sender], "ALREADY");

        // leaf = keccak256(abi.encode(user, monthId, amountRama, tierIdx))
        bytes32 leaf = keccak256(
            abi.encode(msg.sender, monthId, amountRama, tierIdx)
        );
        require(MerkleProof.verify(proof, root, leaf), "BAD_PROOF");

        // mark claimed first
        claimed[monthId][msg.sender] = true;

        // credit royalty bucket (wallet/ledger)
        // (bool ok, ) = cfg.mainWallet().call(
        //     abi.encodeWithSignature(
        //         "creditRoyalty(address,uint256)",
        //         msg.sender,
        //         amountRama
        //     )
        // );

        ISafeWallet(cfg.safeWallet()).creditGeneral(
            msg.sender,
            ISafeWallet.TxKind.Royalty,
            amountInUSD, // pass USD 1e18 if you have it; otherwise 0
            amountRama, // RAMA wei computed from USD * price
            bytes32(uint256(monthId)) // memo: monthId
        );

        // require(ok, "MAIN_CREDIT_FAIL");

        // update lean state
        RoyaltyState storage st = royalty[msg.sender];
        st.lastPaidTier = tierIdx;
        st.lastPaidMonthEpoch = monthId;
        st.paused = false; // receiving a payment implies active

        emit RoyaltyPaid(msg.sender, monthId, tierIdx, amountRama);
    }

    // === Views ===

    function getTierCount() external view returns (uint256) {
        return tiers.length;
    }

    function getTier(uint256 idx) external view returns (RoyaltyTier memory) {
        return tiers[idx];
    }

    // threshold USD for tier idx
    function thresholdUSD(uint256 idx) external view returns (uint256) {
        require(idx < tiers.length, "IDX_OOB");
        return tiers[idx].teamBusiness;
    }
    // salary USD for tier idx
    function salaryUSD(uint256 idx) external view returns (uint256) {
        require(idx < tiers.length, "IDX_OOB");
        return tiers[idx].monthlyUSD;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
