pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/ICoreConfig.sol";
import "./interfaces/ISafeWallet.sol";


/// @title RewardVault
/// @notice One-time (lifetime) milestone rewards with full tracking and views.
contract RewardVault is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    ICoreConfig public cfg;

    // user => milestoneIdx => claimed
    mapping(address => mapping(uint8 => bool)) public claimed;

    // Milestone tables (USD values are 1e18 WAD)
    uint256[] public milestoneThresholdsUSD; // e.g., 6k, 15k, 40k, ...
    uint256[] public milestoneRewardsUSD; // e.g., 100, 250, 500, ...

    // Lifetime totals per user (for fast dashboards)
    mapping(address => uint256) public totalRewardUsd; // 1e18 WAD
    mapping(address => uint256) public totalRewardRama; // wei

    // Detailed claim ledger
    struct RewardClaim {
        uint8 milestoneIdx;
        uint256 usdReward; // 1e18 WAD (from table at time of grant)
        uint256 ramaAmount; // wei (converted using oracle price at grant)
        uint256 qualifiedUsdAt; // 1e18 WAD (the T used to qualify at grant time)
        uint64 timestamp; // block.timestamp
    }
    mapping(address => RewardClaim[]) private _claims;

    event RewardGranted(
        address indexed user,
        uint8 indexed milestone,
        uint256 ramaAmount
    );
    event RewardGrantedDetailed(
        address indexed user,
        uint8 indexed milestone,
        uint256 usdReward,
        uint256 ramaAmount,
        uint256 qualifiedUsdAt,
        uint64 timestamp
    );

    /* ----------------------------- Init / Upgrade ----------------------------- */

    function initialize(address _cfg) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        cfg = ICoreConfig(_cfg);

        // 14 milestones (USD 1e18 units)
        milestoneThresholdsUSD = new uint256[](15);
        milestoneRewardsUSD = new uint256[](15);

        // Team Volume  -> Reward (USD)
        milestoneThresholdsUSD[0] = 6_000e18;
        milestoneRewardsUSD[0] = 100e18;

        milestoneThresholdsUSD[1] = 15_000e18;
        milestoneRewardsUSD[1] = 250e18;

        milestoneThresholdsUSD[2] = 40_000e18;
        milestoneRewardsUSD[2] = 500e18;

        milestoneThresholdsUSD[3] = 60_000e18;
        milestoneRewardsUSD[3] = 750e18;

        milestoneThresholdsUSD[4] = 120_000e18;
        milestoneRewardsUSD[4] = 1000e18;

        milestoneThresholdsUSD[5] = 300_000e18;
        milestoneRewardsUSD[5] = 2500e18;

        milestoneThresholdsUSD[6] = 600_000e18;
        milestoneRewardsUSD[6] = 5000e18;

        milestoneThresholdsUSD[7] = 1_500_000e18;
        milestoneRewardsUSD[7] = 8000e18;

        milestoneThresholdsUSD[8] = 3_000_000e18;
        milestoneRewardsUSD[8] = 12000e18;

        milestoneThresholdsUSD[9] = 6_000_000e18;
        milestoneRewardsUSD[9] = 30000e18;

        milestoneThresholdsUSD[10] = 15_000_000e18;
        milestoneRewardsUSD[10] = 50000e18;

        milestoneThresholdsUSD[11] = 30_000_000e18;
        milestoneRewardsUSD[11] = 85000e18;

        milestoneThresholdsUSD[12] = 60_000_000e18;
        milestoneRewardsUSD[12] = 150000e18;

        milestoneThresholdsUSD[13] = 200_000_000e18;
        milestoneRewardsUSD[13] = 500000e18;
        
        milestoneThresholdsUSD[14] = 500_000_000e18;
        milestoneRewardsUSD[14] = 1500000e18;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /* --------------------------------- Admin --------------------------------- */

    /// @notice Owner can update a milestone table entry (optional admin hook).
    function setMilestone(
        uint8 idx,
        uint256 thresholdUsd,
        uint256 rewardUsd
    ) external onlyOwner {
        require(idx < milestoneThresholdsUSD.length, "IDX_OOB");
        milestoneThresholdsUSD[idx] = thresholdUsd;
        milestoneRewardsUSD[idx] = rewardUsd;
    }

    /// @notice Owner replace entire tables (must be same length for both arrays).
    function setMilestones(
        uint256[] calldata thresholdsUsd,
        uint256[] calldata rewardsUsd
    ) external onlyOwner {
        require(thresholdsUsd.length == rewardsUsd.length, "LEN_MISMATCH");
        milestoneThresholdsUSD = thresholdsUsd;
        milestoneRewardsUSD = rewardsUsd;
    }

    /* ------------------------------ Manual Grant ----------------------------- */

    /// @notice Admin/manual grant a specific milestone in RAMA.
    function grant(
        address user,
        uint8 milestoneIdx,
        uint256 ramaAmount
    ) external {
        require(
            msg.sender == cfg.adminControl() || msg.sender == owner(),
            "NOT_AUTH"
        );
        require(!claimed[user][milestoneIdx], "ALREADY");
        claimed[user][milestoneIdx] = true;

        // credit RAMA
        (bool ok, ) = cfg.mainWallet().call(
            abi.encodeWithSignature(
                "creditReward(address,uint256)",
                user,
                ramaAmount
            )
        );
        require(ok, "MAIN_CREDIT_FAIL");

        // record (USD unknown in manual grant; store 0)
        _claims[user].push(
            RewardClaim({
                milestoneIdx: milestoneIdx,
                usdReward: 0,
                ramaAmount: ramaAmount,
                qualifiedUsdAt: 0,
                timestamp: uint64(block.timestamp)
            })
        );
        totalRewardRama[user] += ramaAmount;

        emit RewardGranted(user, milestoneIdx, ramaAmount);
        emit RewardGrantedDetailed(
            user,
            milestoneIdx,
            0,
            ramaAmount,
            0,
            uint64(block.timestamp)
        );
    }

    /* ---------------------------- Auto Credit Path --------------------------- */
    /// @notice Autocredit newly crossed milestones based on current qualified team business (USD 1e18).
    /// @dev Called by SlabManager.onBusinessDelta after recomputing qualified T (40/30/30).
    function checkAndCredit(address user, uint256 qualifiedUsd) external {
        require(
            msg.sender == cfg.slabManager() ||
                msg.sender == cfg.adminControl() ||
                msg.sender == owner(),
            "NOT_AUTH"
        );
        if (qualifiedUsd == 0) return;

        // Pull USD/RAMA price from your global oracle (WAD: 1e18 USD per RAMA)
        (bool okP, bytes memory data) = cfg.priceOracle().staticcall(
            abi.encodeWithSignature("ramaPriceInUSD()")
        );
        require(okP && data.length >= 32, "ORACLE_FAIL");
        uint256 priceWad = abi.decode(data, (uint256));
        require(priceWad > 0, "BAD_PRICE");

        uint256 len = milestoneThresholdsUSD.length;
        for (uint8 i = 0; i < len; i++) {
            if (
                !claimed[user][i] && qualifiedUsd >= milestoneThresholdsUSD[i]
            ) {
                uint256 usdReward = milestoneRewardsUSD[i]; // 1e18 WAD
                // Correct conversion (WAD math): RAMA = USD * 1e18 / priceWad
                uint256 ramaAmount = (usdReward * 1e18) / priceWad;

                claimed[user][i] = true;

                // credit MainWallet
                // (bool ok, ) = cfg.mainWallet().call(
                //     abi.encodeWithSignature(
                //         "creditReward(address,uint256)",
                //         user,
                //         ramaAmount
                //     )
                // );
                // require(ok, "MAIN_CREDIT_FAIL");

                ISafeWallet(cfg.safeWallet()).creditGeneral(
                    user,
                    ISafeWallet.TxKind.Reward,
                    milestoneRewardsUSD[i], // 1e18 USD, if you want to log it
                    ramaAmount, // RAMA wei
                    bytes32(uint256(i)) // memo: milestone index
                );

                // ledger
                _claims[user].push(
                    RewardClaim({
                        milestoneIdx: i,
                        usdReward: usdReward,
                        ramaAmount: ramaAmount,
                        qualifiedUsdAt: qualifiedUsd,
                        timestamp: uint64(block.timestamp)
                    })
                );
                totalRewardUsd[user] += usdReward;
                totalRewardRama[user] += ramaAmount;

                emit RewardGranted(user, i, ramaAmount);
                emit RewardGrantedDetailed(
                    user,
                    i,
                    usdReward,
                    ramaAmount,
                    qualifiedUsd,
                    uint64(block.timestamp)
                );
            }
        }
    }

    /* --------------------------------- Views --------------------------------- */

    /// @notice Milestone table size.
    function milestonesCount() external view returns (uint256) {
        return milestoneThresholdsUSD.length;
    }

    /// @notice Get one milestone (thresholdUSD, rewardUSD).
    function getMilestone(
        uint8 idx
    ) external view returns (uint256 thresholdUsd, uint256 rewardUsd) {
        require(idx < milestoneThresholdsUSD.length, "IDX_OOB");
        return (milestoneThresholdsUSD[idx], milestoneRewardsUSD[idx]);
    }

    /// @notice Full tables (return copies).
    function getAllMilestones()
        external
        view
        returns (uint256[] memory thresholdsUsd, uint256[] memory rewardsUsd)
    {
        return (milestoneThresholdsUSD, milestoneRewardsUSD);
    }

    /// @notice Has the user already claimed this milestone?
    function isMilestoneClaimed(
        address user,
        uint8 idx
    ) external view returns (bool) {
        return claimed[user][idx];
    }

    /// @notice For UI: full claimed/unclaimed status array for a user.
    function getUserMilestoneStatus(
        address user
    ) external view returns (bool[] memory status) {
        uint256 n = milestoneThresholdsUSD.length;
        status = new bool[](n);
        for (uint256 i = 0; i < n; i++) status[i] = claimed[user][uint8(i)];
    }

    /// @notice User lifetime totals (USD WAD, RAMA wei).
    function getUserTotals(
        address user
    ) external view returns (uint256 usdTotal, uint256 ramaTotal) {
        return (totalRewardUsd[user], totalRewardRama[user]);
    }

    /// @notice # of detailed claims for user.
    function getUserClaimsCount(address user) external view returns (uint256) {
        return _claims[user].length;
    }

    /// @notice Get one claim record by index.
    function getUserClaimByIndex(
        address user,
        uint256 idx
    ) external view returns (RewardClaim memory rec) {
        require(idx < _claims[user].length, "OOB");
        return _claims[user][idx];
    }

    /// @notice Paginated claims slice [offset, offset+limit).
    function getUserClaimsSlice(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (RewardClaim[] memory out) {
        RewardClaim[] storage arr = _claims[user];
        uint256 n = arr.length;
        if (offset >= n) return new RewardClaim[](0);

        uint256 end = offset + limit;
        if (end > n) end = n;

        out = new RewardClaim[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = arr[i];
        }
    }

    /// @notice Preview which milestones would be credited at a given qualifiedUsd (without changing state).
    /// @dev Returns indexes and the USD reward for each unclaimed-but-eligible milestone.
    function previewEligible(
        address user,
        uint256 qualifiedUsd
    ) external view returns (uint8[] memory idxs, uint256[] memory usdRewards) {
        uint256 len = milestoneThresholdsUSD.length;
        // first pass: count
        uint256 c;
        for (uint8 i = 0; i < len; i++) {
            if (!claimed[user][i] && qualifiedUsd >= milestoneThresholdsUSD[i])
                c++;
        }
        idxs = new uint8[](c);
        usdRewards = new uint256[](c);

        // second pass: fill
        uint256 k;
        for (uint8 i = 0; i < len; i++) {
            if (
                !claimed[user][i] && qualifiedUsd >= milestoneThresholdsUSD[i]
            ) {
                idxs[k] = i;
                usdRewards[k] = milestoneRewardsUSD[i];
                k++;
            }
        }
    }
}

// ========================old

// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.24;

// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// import "./interfaces/ICoreConfig.sol";

// contract RewardVault is Initializable, OwnableUpgradeable, UUPSUpgradeable {
//     ICoreConfig public cfg;

//     // user => milestoneIdx => claimed
//     mapping(address => mapping(uint8 => bool)) public claimed;

//     // Milestone tables (USD values are 1e18 WAD)
//     uint256[] public milestoneThresholdsUSD; // e.g., 6k, 15k, 40k, ...
//     uint256[] public milestoneRewardsUSD; // e.g., 100, 250, 500, ...

//     event RewardGranted(
//         address indexed user,
//         uint8 indexed milestone,
//         uint256 ramaAmount
//     );

//     function initialize(address _cfg) external initializer {
//         __Ownable_init();
//         __UUPSUpgradeable_init();
//         cfg = ICoreConfig(_cfg);

//         // 14 milestones (USD 1e18 units)
//         milestoneThresholdsUSD = new uint256[](14);

//         milestoneRewardsUSD = new uint256[](14);

//         // Team Volume  -> Reward (USD)
//         milestoneThresholdsUSD[0] = 6_000e18;
//         milestoneRewardsUSD[0] = 100e18;
//         milestoneThresholdsUSD[1] = 15_000e18;
//         milestoneRewardsUSD[1] = 250e18;
//         milestoneThresholdsUSD[2] = 40_000e18;
//         milestoneRewardsUSD[2] = 500e18;
//         milestoneThresholdsUSD[3] = 120_000e18;
//         milestoneRewardsUSD[3] = 1_000e18;
//         milestoneThresholdsUSD[4] = 300_000e18;
//         milestoneRewardsUSD[4] = 2_500e18;
//         milestoneThresholdsUSD[5] = 600_000e18;
//         milestoneRewardsUSD[5] = 5_000e18;
//         milestoneThresholdsUSD[6] = 1_500_000e18;
//         milestoneRewardsUSD[6] = 8_000e18;
//         milestoneThresholdsUSD[7] = 3_000_000e18;
//         milestoneRewardsUSD[7] = 12_000e18;
//         milestoneThresholdsUSD[8] = 6_000_000e18;
//         milestoneRewardsUSD[8] = 30_000e18;
//         milestoneThresholdsUSD[9] = 15_000_000e18;
//         milestoneRewardsUSD[9] = 50_000e18;
//         milestoneThresholdsUSD[10] = 30_000_000e18;
//         milestoneRewardsUSD[10] = 85_000e18;
//         milestoneThresholdsUSD[11] = 60_000_000e18;
//         milestoneRewardsUSD[11] = 150_000e18;
//         milestoneThresholdsUSD[12] = 200_000_000e18;
//         milestoneRewardsUSD[12] = 500_000e18;
//         milestoneThresholdsUSD[13] = 500_000_000e18;
//         milestoneRewardsUSD[13] = 1_500_000e18;
//     }

//     /// @notice Grant a specific milestone (admin/manual).
//     function grant(
//         address user,
//         uint8 milestoneIdx,
//         uint256 ramaAmount
//     ) external {
//         require(
//             msg.sender == cfg.adminControl() || msg.sender == owner(),
//             "NOT_AUTH"
//         );
//         require(!claimed[user][milestoneIdx], "ALREADY");
//         claimed[user][milestoneIdx] = true;

//         (bool ok, ) = cfg.mainWallet().call(
//             abi.encodeWithSignature(
//                 "creditReward(address,uint256)",
//                 user,
//                 ramaAmount
//             )
//         );
//         require(ok, "MAIN_CREDIT_FAIL");
//         emit RewardGranted(user, milestoneIdx, ramaAmount);
//     }

//     /// @notice Autocredit newly crossed milestones based on current qualified team business (USD 1e18).
//     /// @dev Called by SlabManager.onBusinessDelta after recomputing qualified T (40/30/30).
//     function checkAndCredit(address user, uint256 qualifiedUsd) external {
//         require(
//             msg.sender == cfg.slabManager() ||
//                 msg.sender == cfg.adminControl() ||
//                 msg.sender == owner(),
//             "NOT_AUTH"
//         );
//         if (qualifiedUsd == 0) return;

//         // Read current USD/RAMA price (USD per RAMA, 1e18)
//         (bool okP, bytes memory data) = cfg.priceOracle().staticcall(
//             abi.encodeWithSignature("ramaPriceInUSD()")
//         );
//         require(okP && data.length >= 32, "ORACLE_FAIL");
//         uint256 priceWad = abi.decode(data, (uint256));
//         require(priceWad > 0, "BAD_PRICE");

//         uint256 len = milestoneThresholdsUSD.length;
//         for (uint8 i = 0; i < len; i++) {
//             // If user qualifies this milestone and hasn't claimed it yet
//             if (
//                 !claimed[user][i] && qualifiedUsd >= milestoneThresholdsUSD[i]
//             ) {
//                 // Convert USD reward to RAMA: rama = usd / price
//                 uint256 usdReward = milestoneRewardsUSD[i]; // 1e18
//                 uint256 ramaAmount = ((usdReward * 1e18) / priceWad) * 1e12;

//                 claimed[user][i] = true;

//                 (bool ok, ) = cfg.mainWallet().call(
//                     abi.encodeWithSignature(
//                         "creditReward(address,uint256)",
//                         user,
//                         ramaAmount
//                     )
//                 );
//                 require(ok, "MAIN_CREDIT_FAIL");
//                 emit RewardGranted(user, i, ramaAmount);
//             }
//         }
//     }

//     function _authorizeUpgrade(address) internal override onlyOwner {}
// }
