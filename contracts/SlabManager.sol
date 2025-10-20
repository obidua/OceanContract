// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import "./interfaces/ICoreConfig.sol";
import "./interfaces/IUserRegistry.sol";
import "./interfaces/ISlabManager.sol";
import "./interfaces/IPortfolioManager.sol";
import "./libraries/OceanErrors.sol";
import "./interfaces/ISafeWallet.sol";

contract SlabManager is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ISlabManager
{
    ICoreConfig public cfg;
    IUserRegistry public registry;
    IPortfolioManager public pm;

    struct LegVol {
        uint256 vol;
    }
    struct SlabQ {
        mapping(address => LegVol) legs; // top-level child => volume (USD 1e18)
        address[] legKeys; // enumerable keys
        uint8 slabIdx; // 0..10  => [5,10,15,20,25,30,35,45,50,55,60]
        uint64 lastClaimAt;
        uint32 new50SinceLastClaim;
    }

    mapping(address => SlabQ) internal s;

    // (upline => descendant => top-level child under upline)
    mapping(address => mapping(address => address)) public topLegOf;

    // Slab ladder thresholds (lower bounds, USD 1e18)
    uint256[] public slabThresholds;
    uint8[11] public slabPercents; // [5,10,15,20,25,30,35,45,50,55,60]

    // Slab pool Merkle epoch (difference model distributor)
    bytes32 public _currentRoot;
    uint64 public _currentEpoch;
    mapping(address => uint64) public claimedAtEpoch;

    event BusinessDelta(
        address indexed upline,
        address indexed leg,
        int256 usdDelta,
        uint8 newSlab
    );
    event New50Direct(address indexed user, uint32 newCount);
    event RootSet(uint64 indexed epoch, bytes32 root);
    event Claimed(
        address indexed user,
        uint256 amount,
        uint8 slabIdx,
        uint64 epoch
    );

    // NEW: for off-chain royalty publisher / analytics
    event QualifiedUpdated(
        address indexed user,
        uint256 qualifiedT, // USD 1e18
        uint8 slabIdx, // derived from T
        uint256 L1, // leg1 USD
        uint256 L2, // leg2 USD
        uint256 Lrest // sum of leg3+
    );

    modifier onlyPM() {
        require(
            msg.sender == cfg.portfolioManager(),
            OceanErrors.NotAuthorized
        );
        _;
    }
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
        registry = IUserRegistry(cfg.userRegistry());
        pm = IPortfolioManager(cfg.portfolioManager());

        slabPercents = [5, 10, 15, 20, 25, 30, 35, 45, 50, 55, 60];

        slabThresholds = new uint256[](11);
        slabThresholds[0] = 500e18;
        slabThresholds[1] = 2500e18;
        slabThresholds[2] = 10000e18;
        slabThresholds[3] = 25000e18;
        slabThresholds[4] = 50000e18;
        slabThresholds[5] = 100000e18;
        slabThresholds[6] = 500000e18;
        slabThresholds[7] = 1000000e18;
        slabThresholds[8] = 2500000e18;
        slabThresholds[9] = 5000000e18;
        slabThresholds[10] = 20000000e18;
    }

    // set contracts
    function setCoreConfig(address _cfg) external onlyOwner {
        cfg = ICoreConfig(_cfg);
        registry = IUserRegistry(cfg.userRegistry());
        pm = IPortfolioManager(cfg.portfolioManager());
    }

    // --- PM hooks ---
    function onBusinessDelta(address user, int256 usdDelta) external onlyPM {
        address cur = user;
        address parent = registry.getReferrer(cur);
        while (parent != address(0)) {
            // resolve cached top-level leg under parent for this descendant
            address legKey = topLegOf[parent][user];
            if (legKey == address(0)) {
                legKey = _firstHopChild(parent, user);
                topLegOf[parent][user] = legKey;
                if (_isNewLeg(parent, legKey)) s[parent].legKeys.push(legKey);
            }

            // apply delta
            if (usdDelta >= 0) {
                s[parent].legs[legKey].vol += uint256(usdDelta);
            } else {
                uint256 dec = uint256(-usdDelta);
                uint256 old = s[parent].legs[legKey].vol;
                s[parent].legs[legKey].vol = dec > old ? 0 : (old - dec);
            }

            // recompute 40/30/30-qualified capacity T and slabIdx
            (
                uint256 qualifiedT,
                uint8 newSlabIdx,
                uint256 L1,
                uint256 L2,
                uint256 Lrest
            ) = _qualifiedTAndSlabWithLegs(parent);
            s[parent].slabIdx = newSlabIdx;

            emit BusinessDelta(parent, legKey, usdDelta, newSlabIdx);
            emit QualifiedUpdated(
                parent,
                qualifiedT,
                newSlabIdx,
                L1,
                L2,
                Lrest
            );

            // trigger One-Time Rewards unlocks strictly under 40/30/30 rule
            // RewardVault.checkAndCredit(address user, uint256 qualifiedBusinessUsd)
            address rv = cfg.rewardVault();
            if (rv != address(0) && qualifiedT > 0) {
                (bool okRV, ) = rv.call(
                    abi.encodeWithSignature(
                        "checkAndCredit(address,uint256)",
                        parent,
                        qualifiedT
                    )
                );
                require(okRV, "REWARD_CHECK_FAIL");
            }

            cur = parent;
            parent = registry.getReferrer(parent);
        }
    }

    function noteNew50Direct(address referrer) external onlyPM {
        s[referrer].new50SinceLastClaim += 1;
        emit New50Direct(referrer, s[referrer].new50SinceLastClaim);
    }

    // --- Views ---
    function getSlabIndex(address user) external view returns (uint8) {
        return s[user].slabIdx;
    }

    function currentEpoch() external view returns (uint64) {
        return _currentEpoch;
    }

    function currentRoot() external view returns (bytes32) {
        return _currentRoot;
    }

    /// @notice Returns current 40/30/30-qualified team business (USD 1e18) for `user`.
    /// @dev Off-chain royalty publisher reads this on month start for Merkle building.
    function getQualifiedBusinessUSD(
        address user
    ) external view returns (uint256) {
        (uint256 T, , , , ) = _qualifiedTAndSlabWithLegs(user);
        return T;
    }

    /// @notice Convenience view for analytics (top two legs and rest).
    function getLegsTop2AndRest(
        address user
    ) external view returns (uint256 L1, uint256 L2, uint256 Lrest) {
        (L1, L2, Lrest) = _currentLegs(user);
    }

    // --- Claim gates (Slab pool) ---
    function canClaim(address user) public view returns (bool) {
        if (!pm.hasActiveMin50(user)) return false;
        if (s[user].new50SinceLastClaim < 1) return false;
        uint8 slabIdx_ = s[user].slabIdx;
        if (registry.getUser(user).directsCount < uint32(slabIdx_) + 1)
            return false; // N directs needed
        if (block.timestamp < uint256(s[user].lastClaimAt) + 24 hours)
            return false;
        return true;
    }

    // --- Merkle epoch mgmt (Slab pool) ---
    function setMerkleRoot(
        uint64 epochId,
        bytes32 root
    ) external onlyDistributor {
        require(epochId == _currentEpoch + 1, "SEQ");
        _currentEpoch = epochId;
        _currentRoot = root;
        emit RootSet(epochId, root);
    }

    function claimSlab(uint256 amount, bytes32[] calldata proof) external {
        require(canClaim(msg.sender), OceanErrors.ClaimCooldown);
        require(claimedAtEpoch[msg.sender] != _currentEpoch, "ALREADY");

        bytes32 leaf = keccak256(abi.encode(msg.sender, _currentEpoch, amount));
        require(MerkleProof.verify(proof, _currentRoot, leaf), "BAD_PROOF");

        // reset gates
        s[msg.sender].new50SinceLastClaim = 0;
        s[msg.sender].lastClaimAt = uint64(block.timestamp);
        claimedAtEpoch[msg.sender] = _currentEpoch;

        // (bool ok, ) = cfg.mainWallet().call(
        //     abi.encodeWithSignature(
        //         "creditSlab(address,uint256)",
        //         msg.sender,
        //         amount
        //     )
        // );

        ISafeWallet(cfg.safeWallet()).creditGeneral(
            msg.sender,
            ISafeWallet.TxKind.Slab,
            0, // USD ledger (if you want, you can pass the USD equivalent)
            amount, // RAMA wei for slab pool
            bytes32(uint256(_currentEpoch)) // memo: epoch id
        );

        // require(ok, "MAIN_CREDIT_FAIL");
        
        emit Claimed(msg.sender, amount, s[msg.sender].slabIdx, _currentEpoch);
    }

    // =========================
    // Qualification helpers
    // =========================

    /// @dev Compute (T, slabIdx, L1, L2, Lrest) from current leg volumes where
    ///      T = max qualified threshold satisfying L1>=0.40T, L2>=0.30T, Lrest>=0.30T.
    function _qualifiedTAndSlabWithLegs(
        address u
    )
        internal
        view
        returns (
            uint256 T,
            uint8 slabIdx_,
            uint256 L1,
            uint256 L2,
            uint256 Lrest
        )
    {
        (L1, L2, Lrest) = _currentLegs(u);
        if (L1 == 0) return (0, 0, 0, 0, 0);

        // T candidates (integer floors): t1 = L1/0.40 = L1*5/2, t2/t3 = *10/3
        uint256 t1 = (L1 * 5) / 2;
        uint256 t2 = (L2 * 10) / 3;
        uint256 t3 = (Lrest * 10) / 3;
        T = _min3(t1, t2, t3);

        if (T == 0) return (0, 0, L1, L2, Lrest);

        // slabIdx is the highest index whose threshold <= T
        slabIdx_ = _slabIdxFromT(T);
    }

    /// @dev Returns (L1, L2, Lrest) sorted from leg storage.
    function _currentLegs(
        address u
    ) internal view returns (uint256 L1, uint256 L2, uint256 Lrest) {
        address[] storage ks = s[u].legKeys;
        uint256 len = ks.length;
        if (len == 0) return (0, 0, 0);

        uint256[] memory vols = new uint256[](len);
        for (uint i = 0; i < len; i++) vols[i] = s[u].legs[ks[i]].vol;
        _sortDesc(vols);

        L1 = vols[0];
        L2 = vols.length > 1 ? vols[1] : 0;
        for (uint i = 2; i < vols.length; i++) Lrest += vols[i];
    }

    function _slabIdxFromT(uint256 T) internal view returns (uint8 idx) {
        for (int i = int(slabThresholds.length) - 1; i >= 0; i--) {
            if (T >= slabThresholds[uint(i)]) return uint8(uint(i));
        }
        return 0;
    }

    function _min3(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256) {
        uint256 m = a < b ? a : b;
        return m < c ? m : c;
    }

    // --- utils ---
    function _isNewLeg(
        address upline,
        address leg
    ) internal view returns (bool) {
        address[] storage ks = s[upline].legKeys;
        for (uint i = 0; i < ks.length; i++) if (ks[i] == leg) return false;
        return true;
    }

    function _firstHopChild(
        address ancestor,
        address descendant
    ) internal view returns (address) {
        address cur = descendant;
        address parent = registry.getReferrer(cur);
        address prev = descendant;
        while (parent != address(0)) {
            if (parent == ancestor) return prev; // prev is the first-hop child under ancestor
            prev = parent;
            parent = registry.getReferrer(parent);
        }
        return address(0);
    }

    function _sortDesc(uint256[] memory a) internal pure {
        // insertion sort (small arrays)
        for (uint i = 1; i < a.length; i++) {
            uint256 key = a[i];
            uint j = i;
            while (j > 0 && a[j - 1] < key) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = key;
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
