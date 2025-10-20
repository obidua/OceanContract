// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.24;

// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// import "./interfaces/ICoreConfig.sol";
// import "./interfaces/IPortfolioManager.sol";
// import "./libraries/OceanErrors.sol";

// /// @title ROIDistributor
// /// @notice Pays daily ROI in USD terms, settling in RAMA at the day’s snapshot price.
// /// @dev Designed for an off-chain bot (adminControl or owner) to call once per day at any time.
// contract ROIDistributor is Initializable, OwnableUpgradeable, UUPSUpgradeable {
//     ICoreConfig public cfg;
//     IPortfolioManager public pm;

//     /// @dev Daily price snapshot (USD per RAMA, 1e18 WAD) indexed by dayId = uint32( block.timestamp / 1 days ).
//     mapping(uint32 => uint256) public priceWadOfDay;

//     /// @dev lastPaidDay per portfolio to enforce "one pay per day per pid".
//     mapping(uint256 => uint32) public lastPaidDay;

//     /// @dev Per-day aggregates (for auditing & analytics)
//     struct DaySnap {
//         uint256 priceWad; // USD per RAMA (WAD)
//         uint256 totalUsdPaid; // sum of USD ROI paid this day
//         uint256 totalRamaPaid; // sum of RAMA distributed this day
//     }
//     mapping(uint32 => DaySnap) public daySnapshot;

//     /// @dev Optional per-user running totals
//     struct UserTotals {
//         uint256 totalUsd; // lifetime USD ROI paid
//         uint256 totalRama; // lifetime RAMA paid
//     }
//     mapping(address => UserTotals) public userTotals;

//     // Daily rates (WAD/day). Keep in sync with PortfolioManager or configure here.
//     uint256 public dailyRateTier0; // e.g. 0.0033 * 1e18
//     uint256 public dailyRateTier1; // e.g. 0.0040 * 1e18
//     uint256 public dailyRateBoosterTier0; // e.g. 0.0066 * 1e18
//     uint256 public dailyRateBoosterTier1; // e.g. 0.0080 * 1e18

//     event DayPriceSet(uint32 indexed dayId, uint256 priceWad);
//     event RatesUpdated(uint256 r0, uint256 r1, uint256 rb0, uint256 rb1);
//     event RoiPaid(
//         address indexed user,
//         uint256 indexed pid,
//         uint32 indexed dayId,
//         uint256 usdAmount,
//         uint256 ramaAmount,
//         uint256 priceWad,
//         bool booster,
//         uint8 tier
//     );

//     modifier onlyDistributor() {
//         // mirror your pattern: owner or AdminControl can run the bot
//         require(
//             msg.sender == cfg.adminControl() || msg.sender == owner(),
//             OceanErrors.NotAuthorized
//         );
//         _;
//     }

//     function initialize(address _cfg) external initializer {
//         __Ownable_init();
//         __UUPSUpgradeable_init();
//         cfg = ICoreConfig(_cfg);
//         pm = IPortfolioManager(cfg.portfolioManager());

//         // default rates (match PortfolioManager defaults; can be changed later)
//         dailyRateTier0 = 33e14; // 0.33%
//         dailyRateTier1 = 40e14; // 0.40%
//         dailyRateBoosterTier0 = 66e14; // 0.66%
//         dailyRateBoosterTier1 = 80e14; // 0.80%
//         emit RatesUpdated(
//             dailyRateTier0,
//             dailyRateTier1,
//             dailyRateBoosterTier0,
//             dailyRateBoosterTier1
//         );
//     }

//     // set portfolio manager if needed
//     function setPortfolioManager(address _pm) external onlyOwner {
//         require(_pm != address(0), OceanErrors.ZeroAddress);
//         pm = IPortfolioManager(_pm);
//     }

//     // -----------------------------------------------------------------------
//     // Admin/bot controls
//     // -----------------------------------------------------------------------

//     /// @notice Set the USD/RAMA price for a given dayId (required before distribution for that day).
//     function setDayPrice(
//         uint32 dayId,
//         uint256 priceWad
//     ) external onlyDistributor {
//         require(priceWad > 0, "BAD_PRICE");
//         priceWadOfDay[dayId] = priceWad;
//         daySnapshot[dayId].priceWad = priceWad;
//         emit DayPriceSet(dayId, priceWad);
//     }

//     /// @notice Update daily rates if your PortfolioManager changes rates.
//     function setRates(
//         uint256 r0,
//         uint256 r1,
//         uint256 rb0,
//         uint256 rb1
//     ) external onlyDistributor {
//         require(
//             r0 <= 5e16 && r1 <= 5e16 && rb0 <= 1e17 && rb1 <= 1e17,
//             "UNREASONABLE"
//         );
//         dailyRateTier0 = r0;
//         dailyRateTier1 = r1;
//         dailyRateBoosterTier0 = rb0;
//         dailyRateBoosterTier1 = rb1;
//         emit RatesUpdated(r0, r1, rb0, rb1);
//     }

//     // -----------------------------------------------------------------------
//     // Distribution
//     // -----------------------------------------------------------------------

//     /// @notice Distribute ROI for a set of portfolios for a specific dayId (bot can call any time in the day).
//     /// @dev Enforces "once per day per pid". Skips ineligible portfolios (frozen/capped).
//     function distributeDay(
//         uint32 dayId,
//         uint256[] calldata pids
//     ) external onlyDistributor {
//         uint256 priceWad = priceWadOfDay[dayId];
//         require(priceWad > 0, "PRICE_NOT_SET");

//         address wallet = cfg.safeWallet(); // or cfg.mainWallet() depending on your policy
//         require(wallet != address(0), "NO_WALLET");

//         for (uint256 i = 0; i < pids.length; i++) {
//             uint256 pid = pids[i];
//             if (lastPaidDay[pid] == dayId) continue; // already paid today

//             // load portfolio
//             IPortfolioManager.Portfolio memory p = pm.getPortfolio(pid);
//             address user = p.owner;

//             // eligibility: not frozen AND not capped
//             if (p.frozenUntil != 0 && block.timestamp <= p.frozenUntil)
//                 continue;
//             uint256 cap = (uint256(p.principal) * uint256(p.capPct)) / 100;
//             if (uint256(p.credited) >= cap) continue;

//             // USD principal (fixed at creation)
//             uint256 principalUsd = pm.getUSDPrincipal(pid); // 1e18 WAD
//             if (principalUsd == 0) continue;

//             // rate selection
//             uint256 rate = _rate(p.booster, p.tier);
//             if (rate == 0) continue;

//             // USD ROI for the day
//             uint256 usdRoi = (principalUsd * rate) / 1e18;
//             if (usdRoi == 0) {
//                 lastPaidDay[pid] = dayId;
//                 continue;
//             }

//             // RAMA to pay at today's price
//             uint256 ramaPay = (usdRoi * 1e18) / priceWad;
//             if (ramaPay == 0) {
//                 lastPaidDay[pid] = dayId;
//                 continue;
//             }

//             // CREDIT: write both USD & RAMA to wallet ledger (recommended)
//             // Signature suggestion: creditROIUSD(user, usdAmount, ramaAmount, dayId)
//             (bool ok, ) = wallet.call(
//                 abi.encodeWithSignature(
//                     "creditROIUSD(address,uint256,uint256,uint32)",
//                     user,
//                     usdRoi,
//                     ramaPay,
//                     dayId
//                 )
//             );
//             require(ok, "ROI_WALLET_CREDIT_FAIL");

//             // accounting
//             lastPaidDay[pid] = dayId;
//             daySnapshot[dayId].totalUsdPaid += usdRoi;
//             daySnapshot[dayId].totalRamaPaid += ramaPay;
//             userTotals[user].totalUsd += usdRoi;
//             userTotals[user].totalRama += ramaPay;

//             emit RoiPaid(
//                 user,
//                 pid,
//                 dayId,
//                 usdRoi,
//                 ramaPay,
//                 priceWad,
//                 p.booster,
//                 p.tier
//             );
//         }
//     }

//     // -----------------------------------------------------------------------
//     // Views / helpers
//     // -----------------------------------------------------------------------

//     function currentDayId() public view returns (uint32) {
//         return uint32(block.timestamp / 1 days);
//     }

//     function _rate(bool booster, uint8 tier) internal view returns (uint256) {
//         if (tier == 1) return booster ? dailyRateBoosterTier1 : dailyRateTier1;
//         return booster ? dailyRateBoosterTier0 : dailyRateTier0;
//     }

//     function _authorizeUpgrade(address) internal override onlyOwner {}
// }
