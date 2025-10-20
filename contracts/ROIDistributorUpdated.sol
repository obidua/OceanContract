// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/ICoreConfig.sol";
import "./interfaces/IUserRegistry.sol";
import "./interfaces/IPortfolioManager.sol";
import "./interfaces/IPriceOracleDaily.sol";

interface ISafeWallet {
    function creditROIUSDBatch(
        address user,
        uint32[] calldata periodIds,
        uint256[] calldata usdAmounts,
        uint256[] calldata ramaAmounts
    ) external;
}

/**
 * NOTE: In this version, "day" in storage/API now represents a generic "period"
 * whose length is `epochSeconds` (default 1 day). For pricing we map each period
 * to its UTC dayId and read the daily price from PriceOracleDaily.
 */
contract ROIDistributor is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    ICoreConfig public cfg;
    IUserRegistry public users;
    IPortfolioManager public pm;
    IPriceOracleDaily public oracle;

    // ======= CONFIGURABLE PERIOD LENGTH (epoch) =======
    uint32 public epochSeconds; // default 86400; for tests set to 60

    // daily/booster rates (WAD per period; these remain daily percentages)
    uint256 public dailyRateTier0; // 0.33% = 33e14
    uint256 public dailyRateTier1; // 0.40% = 40e14
    uint256 public dailyRateBoosterTier0; // 0.66% = 66e14
    uint256 public dailyRateBoosterTier1; // 0.80% = 80e14

    // Last fully-claimed "period" (inclusive). 0 => never claimed.
    mapping(address => uint32) public lastClaimDay; // interpreted as "periodId" now

    // Lifetime totals
    mapping(address => uint256) public totalClaimedUsd; // 1e18 WAD
    mapping(address => uint256) public totalClaimedRama; // wei
    mapping(address => uint32) public userClaimEpoch; // increments each claim

    // Per-portfolio USD paid ledger for 200/250% cap
    mapping(uint256 => uint256) public paidUsdByPid;

    struct ClaimRec {
        uint32 fromDay; // periodId (inclusive)
        uint32 toDay; // periodId (inclusive)
        uint256 usdTotal; // 1e18
        uint256 ramaTotal; // wei
        uint64 claimedAt;
        uint32 epoch;
    }
    mapping(address => ClaimRec[]) internal _history;

    struct PidClaim {
        uint256 pid;
        uint256 usdTotal;
        uint256 ramaTotal;
    }
    mapping(address => mapping(uint32 => PidClaim[])) internal _epochPidClaims;

    uint32 public maxDaysPerClaim; // actually "max periods per claim"

    event ClaimedROI(
        address indexed user,
        uint32 indexed fromDay,
        uint32 indexed toDay,
        uint256 usdTotal,
        uint256 ramaTotal,
        uint32 epoch
    );
    event ClaimedROIByPortfolio(
        address indexed user,
        uint32 indexed epoch,
        uint256 pid,
        uint256 usdTotal,
        uint256 ramaTotal
    );

    // ---------------- Init / Upgrade ----------------
    function initialize(address _cfg, address _oracle) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        cfg = ICoreConfig(_cfg);
        users = IUserRegistry(cfg.userRegistry());
        pm = IPortfolioManager(cfg.portfolioManager());
        oracle = IPriceOracleDaily(_oracle);

        // default epoch = 1 day; for testing set to 60 via admin
        epochSeconds = 1 days;

        dailyRateTier0 = 33e14;
        dailyRateTier1 = 40e14;
        dailyRateBoosterTier0 = 66e14;
        dailyRateBoosterTier1 = 80e14;

        maxDaysPerClaim = 90; // i.e., max 90 periods per claim
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ---------------- Admin ----------------
    function setOracle(address a) external onlyOwner {
        require(a != address(0), "ZERO_ORACLE");
        oracle = IPriceOracleDaily(a);
    }

    function setRates(
        uint256 t0,
        uint256 t1,
        uint256 b0,
        uint256 b1
    ) external onlyOwner {
        require(t0 > 0 && t1 > 0 && b0 > 0 && b1 > 0, "BAD_RATE");
        dailyRateTier0 = t0;
        dailyRateTier1 = t1;
        dailyRateBoosterTier0 = b0;
        dailyRateBoosterTier1 = b1;
    }

    /// @notice Set the generic period length in seconds.
    /// For daily operation keep 86400. For testing, you can set 60 (1 minute).
    /// NOTE: Changing this affects *future* claims; user state is kept in period IDs.
    function setEpochSeconds(uint32 secs) external onlyOwner {
        require(secs >= 60 && secs <= 7 days, "RANGE");
        epochSeconds = secs;
    }

    /// @notice Gas-safety guard (max periods per claim).
    function setMaxDaysPerClaim(uint32 maxDays_) external onlyOwner {
        require(maxDays_ >= 1 && maxDays_ <= 3650, "RANGE");
        maxDaysPerClaim = maxDays_;
    }

    // ---------------- Views ----------------
    function getLastClaimedDay(address user) external view returns (uint32) {
        return lastClaimDay[user]; // periodId
    }

    function getTotalsClaimed(
        address user
    ) external view returns (uint256, uint256) {
        return (totalClaimedUsd[user], totalClaimedRama[user]);
    }

    function getClaimHistoryCount(
        address user
    ) external view returns (uint256) {
        return _history[user].length;
    }

    function getClaimHistorySlice(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (ClaimRec[] memory out) {
        ClaimRec[] storage arr = _history[user];
        uint256 n = arr.length;
        if (offset >= n) return new ClaimRec[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;
        out = new ClaimRec[](end - offset);
        for (uint256 i = offset; i < end; i++) out[i - offset] = arr[i];
    }

    function getPidClaimsCount(
        address user,
        uint32 epoch
    ) external view returns (uint256) {
        return _epochPidClaims[user][epoch].length;
    }

    function getPidClaimsSlice(
        address user,
        uint32 epoch,
        uint256 offset,
        uint256 limit
    ) external view returns (PidClaim[] memory out) {
        PidClaim[] storage arr = _epochPidClaims[user][epoch];
        uint256 n = arr.length;
        if (offset >= n) return new PidClaim[](0);

        uint256 end = offset + limit;
        if (end > n) end = n;
        out = new PidClaim[](end - offset);
        for (uint256 i = offset; i < end; i++) out[i - offset] = arr[i];
    }

    /// Dynamic per-period preview (freeze+cap aware).
    /// NOTE: arguments are *periodIds* now.
    function perDayPreview(
        // kept name for compatibility
        address user,
        uint32 fromDay,
        uint32 toDay
    )
        external
        view
        returns (
            uint32[] memory periodIds,
            uint256[] memory usdPer,
            uint256[] memory ramaPer
        )
    {
        require(toDay >= fromDay, "RANGE");
        uint32 latestFinPeriod = _latestFinalizedPeriodId();
        if (toDay > latestFinPeriod) toDay = latestFinPeriod;

        uint256 len = uint256(toDay) - uint256(fromDay) + 1;
        periodIds = new uint32[](len);
        usdPer = new uint256[](len);
        ramaPer = new uint256[](len);

        for (uint32 p = fromDay; p <= toDay; p++) {
            uint256 usd = _userUsdForPeriod_FreezeCap(user, p);
            uint256 rama = 0;
            if (usd != 0) {
                uint32 dayId = _dayIdFromPeriod(p);
                uint256 price6 = oracle.getPrice6ForDay(dayId); // micro-USD per RAMA
                rama = (usd * 1e18) / price6;
            }
            uint256 i = uint256(p - fromDay);
            periodIds[i] = p;
            usdPer[i] = usd;
            ramaPer[i] = rama;
        }
    }

    /// Portfolio-wise preview for window [lastClaim+1 .. latestFinalizedPeriod]
    function previewClaimPerPortfolio(
        address user
    )
        external
        view
        returns (
            uint256[] memory pids,
            uint256[] memory usdTotals,
            uint256[] memory ramaTotals,
            uint32 fromPeriod,
            uint32 lastPeriod
        )
    {
        (fromPeriod, lastPeriod) = _autoWindow(user);
        if (lastPeriod < fromPeriod) {
            return (
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                fromPeriod,
                lastPeriod
            );
        }

        uint256[] memory userPids = pm.portfoliosOf(user);
        pids = new uint256[](userPids.length);
        usdTotals = new uint256[](userPids.length);
        ramaTotals = new uint256[](userPids.length);

        for (uint256 i = 0; i < userPids.length; i++) {
            uint256 pid = userPids[i];
            IPortfolioManager.Portfolio memory p = pm.getPortfolio(pid);
            if (p.owner != user) continue;
            uint256 usdSum;
            uint256 ramaSum;
            for (uint32 pr = fromPeriod; pr <= lastPeriod; pr++) {
                uint256 usd = _portfolioUsdForPeriod(p, pid, pr);
                if (usd == 0) continue;
                uint32 dayId = _dayIdFromPeriod(pr);
                uint256 price6 = oracle.getPrice6ForDay(dayId);
                usdSum += usd;
                ramaSum += (usd * 1e18) / price6;
            }
            pids[i] = pid;
            usdTotals[i] = usdSum;
            ramaTotals[i] = ramaSum;
        }
    }

    // -------- CLAIM (no inputs; auto up to latest finalized period) --------
    function claimROI() external {
        (uint32 fromPeriod, uint32 lastPeriod) = _autoWindow(msg.sender);
        require(lastPeriod >= fromPeriod, "NOTHING");

        uint32 span = lastPeriod - fromPeriod + 1;
        require(span <= maxDaysPerClaim, "TOO_MANY_PERIODS");

        uint256[] memory userPids = pm.portfoliosOf(msg.sender);
        uint256[] memory perPidUsd = new uint256[](userPids.length);
        uint256[] memory perPidRama = new uint256[](userPids.length);

        uint32[] memory periodIds = new uint32[](span);
        uint256[] memory usdAmounts = new uint256[](span);
        uint256[] memory ramaAmounts = new uint256[](span);

        uint256 usdTotal;
        uint256 ramaTotal;

        for (uint32 pr = fromPeriod; pr <= lastPeriod; pr++) {
            uint256 usdPr;
            for (uint256 i = 0; i < userPids.length; i++) {
                uint256 pid = userPids[i];
                IPortfolioManager.Portfolio memory p = pm.getPortfolio(pid);
                if (p.owner != msg.sender) continue;
                uint256 usdPid = _portfolioUsdForPeriod(p, pid, pr);
                if (usdPid == 0) continue;
                usdPr += usdPid;
            }

            uint256 idx = uint256(pr - fromPeriod);
            periodIds[idx] = pr;

            if (usdPr == 0) continue;

            uint32 dayId = _dayIdFromPeriod(pr);
            uint256 price6 = oracle.getPrice6ForDay(dayId);
            uint256 ramaPr = (usdPr * 1e18) / price6;

            usdAmounts[idx] = usdPr;
            ramaAmounts[idx] = ramaPr;
            usdTotal += usdPr;
            ramaTotal += ramaPr;

            // per-pid ledgers
            for (uint256 i = 0; i < userPids.length; i++) {
                uint256 pid = userPids[i];
                IPortfolioManager.Portfolio memory p = pm.getPortfolio(pid);
                if (p.owner != msg.sender) continue;
                uint256 usdPid = _portfolioUsdForPeriod(p, pid, pr);
                if (usdPid == 0) continue;
                paidUsdByPid[pid] += usdPid;
                perPidUsd[i] += usdPid;
                perPidRama[i] += (usdPid * 1e18) / price6;
            }
        }

        ISafeWallet(cfg.safeWallet()).creditROIUSDBatch(
            msg.sender,
            periodIds,
            usdAmounts,
            ramaAmounts
        );

        lastClaimDay[msg.sender] = lastPeriod; // store last claimed period
        totalClaimedUsd[msg.sender] += usdTotal;
        totalClaimedRama[msg.sender] += ramaTotal;

        uint32 epoch = ++userClaimEpoch[msg.sender];

        _history[msg.sender].push(
            ClaimRec({
                fromDay: fromPeriod,
                toDay: lastPeriod,
                usdTotal: usdTotal,
                ramaTotal: ramaTotal,
                claimedAt: uint64(block.timestamp),
                epoch: epoch
            })
        );

        for (uint256 i = 0; i < userPids.length; i++) {
            if (perPidUsd[i] == 0 && perPidRama[i] == 0) continue;
            _epochPidClaims[msg.sender][epoch].push(
                PidClaim({
                    pid: userPids[i],
                    usdTotal: perPidUsd[i],
                    ramaTotal: perPidRama[i]
                })
            );
            emit ClaimedROIByPortfolio(
                msg.sender,
                epoch,
                userPids[i],
                perPidUsd[i],
                perPidRama[i]
            );
        }

        emit ClaimedROI(
            msg.sender,
            fromPeriod,
            lastPeriod,
            usdTotal,
            ramaTotal,
            epoch
        );
    }

    // ---------------- Window helpers (period-based) ----------------

    function _autoWindow(
        address user
    ) internal view returns (uint32 fromPeriod, uint32 lastPeriod) {
        uint32 latestFinPeriod = _latestFinalizedPeriodId();
        if (latestFinPeriod == 0) return (1, 0); // empty

        uint32 prev = lastClaimDay[user];
        fromPeriod = prev == 0 ? _firstEligiblePeriod(user) : (prev + 1);
        lastPeriod = latestFinPeriod;
    }

    function _firstEligiblePeriod(address user) internal view returns (uint32) {
        uint256[] memory pids = pm.portfoliosOf(user);
        if (pids.length == 0) return _latestFinalizedPeriodId();
        uint256 tmin = type(uint256).max;
        for (uint256 i = 0; i < pids.length; i++) {
            IPortfolioManager.Portfolio memory p = pm.getPortfolio(pids[i]);
            if (p.owner != user) continue;
            if (p.createdAt < tmin) tmin = p.createdAt;
        }
        if (tmin == type(uint256).max) return _latestFinalizedPeriodId();
        return uint32(tmin / epochSeconds);
    }

    // ---------------- Math (freeze + cap aware) ----------------

    function _userUsdForPeriod_FreezeCap(
        address user,
        uint32 periodId
    ) internal view returns (uint256 usd) {
        uint256[] memory pids = pm.portfoliosOf(user);
        for (uint256 i = 0; i < pids.length; i++) {
            IPortfolioManager.Portfolio memory p = pm.getPortfolio(pids[i]);
            if (p.owner != user) continue;
            usd += _portfolioUsdForPeriod(p, pids[i], periodId);
        }
    }

    function _portfolioUsdForPeriod(
        IPortfolioManager.Portfolio memory p,
        uint256 pid,
        uint32 periodId
    ) internal view returns (uint256 usd) {
        if (_isFrozenOnPeriod(pid, periodId)) return 0;

        uint256 principalUsd = pm.getUSDPrincipal(pid);
        if (principalUsd == 0) return 0;

        uint256 rate = _rateWad(p.booster, p.tier);
        usd = (principalUsd * rate) / 1e18;

        uint256 rem = _remainingUsdCap(pid);
        if (usd > rem) usd = rem;
    }

    function _remainingUsdCap(uint256 pid) internal view returns (uint256) {
        IPortfolioManager.Portfolio memory p = pm.getPortfolio(pid);
        uint256 principalUsd = pm.getUSDPrincipal(pid); // 1e18
        uint256 capUsd = (principalUsd * p.capPct) / 100; // 200/250%
        uint256 paid = paidUsdByPid[pid];
        return paid >= capUsd ? 0 : (capUsd - paid);
    }

    function _isFrozenOnPeriod(
        uint256 pid,
        uint32 periodId
    ) internal view returns (bool) {
        // map period -> UTC dayId and reuse day-based freeze intervals
        uint32 dayId = _dayIdFromPeriod(periodId);

        uint256 total = pm.getFreezeIntervalsCount(pid);
        if (total == 0) return false;

        uint32 latestFinDay = oracle.latestFinalizedDayId();
        uint256 cursor = 0;
        while (cursor < total) {
            uint256 chunk = total - cursor;
            if (chunk > 200) chunk = 200;
            IPortfolioManager.FreezeInterval[] memory slice = pm
                .getFreezeIntervalsSlice(pid, cursor, chunk);

            for (uint256 i = 0; i < slice.length; i++) {
                uint32 s = slice[i].startDay;
                uint32 e = slice[i].endDay;
                if (e == 0) {
                    uint32 tentativeEnd = s + 3; // ~72h = 3 days
                    if (tentativeEnd > latestFinDay)
                        tentativeEnd = latestFinDay;
                    e = tentativeEnd;
                }
                if (dayId >= s && dayId <= e) return true;
            }
            cursor += chunk;
        }
        return false;
    }

    function _rateWad(
        bool booster,
        uint8 tier
    ) internal view returns (uint256) {
        if (tier == 1) return booster ? dailyRateBoosterTier1 : dailyRateTier1;
        return booster ? dailyRateBoosterTier0 : dailyRateTier0;
    }

    // -------- Helpers: map between periods and days / oracle finality --------

    function _dayIdFromPeriod(uint32 periodId) internal view returns (uint32) {
        uint256 periodStartTs = uint256(periodId) * uint256(epochSeconds);
        return uint32(periodStartTs / 1 days);
    }

    function _latestFinalizedPeriodId() internal view returns (uint32) {
        // latest finalized day = oracle.yesterday
        uint32 latestFinDay = oracle.latestFinalizedDayId();
        if (latestFinDay == 0) return 0;

        // Use the last second of that day as a bound
        uint256 endTs = (uint256(latestFinDay) + 1) * 1 days - 1;
        return uint32(endTs / uint256(epochSeconds));
    }

    // -------- Extra views you added (kept, now period-aware internally) --------

    function ROIForAPortfolio(
        uint256 pid,
        uint32 fromDay, // interpreted as periodId
        uint32 toDay // interpreted as periodId
    ) external view returns (uint256 usdTotal, uint256 ramaTotal) {
        IPortfolioManager.Portfolio memory p = pm.getPortfolio(pid);
        address user = p.owner;
        require(user != address(0), "INVALID_PID");

        uint32 latestFin = _latestFinalizedPeriodId();
        if (toDay > latestFin) toDay = latestFin;
        require(toDay >= fromDay, "RANGE");

        for (uint32 pr = fromDay; pr <= toDay; pr++) {
            uint256 usd = _portfolioUsdForPeriod(p, pid, pr);
            if (usd == 0) continue;
            uint32 dayId = _dayIdFromPeriod(pr);
            uint256 price6 = oracle.getPrice6ForDay(dayId);
            usdTotal += usd;
            ramaTotal += (usd * 1e18) / price6;
        }
    }

    function ROIForBoosterPortfolios(
        address user,
        uint32 fromDay, // periodId
        uint32 toDay // periodId
    ) external view returns (uint256 usdTotal, uint256 ramaTotal) {
        uint256[] memory pids = pm.portfoliosOf(user);
        uint32 latestFin = _latestFinalizedPeriodId();
        if (toDay > latestFin) toDay = latestFin;
        require(toDay >= fromDay, "RANGE");

        for (uint256 i = 0; i < pids.length; i++) {
            IPortfolioManager.Portfolio memory p = pm.getPortfolio(pids[i]);
            if (p.owner != user) continue;
            if (!p.booster) continue;

            for (uint32 pr = fromDay; pr <= toDay; pr++) {
                uint256 usd = _portfolioUsdForPeriod(p, pids[i], pr);
                if (usd == 0) continue;
                uint32 dayId = _dayIdFromPeriod(pr);
                uint256 price6 = oracle.getPrice6ForDay(dayId);
                usdTotal += usd;
                ramaTotal += (usd * 1e18) / price6;
            }
        }
    }
}

// pragma solidity ^0.8.24;

// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// import "./interfaces/ICoreConfig.sol";
// import "./interfaces/IUserRegistry.sol";
// import "./interfaces/IPortfolioManager.sol";
// import "./interfaces/IPriceOracleDaily.sol";

// interface ISafeWallet {
//     function creditROIUSDBatch(
//         address user,
//         uint32[] calldata dayIds,
//         uint256[] calldata usdAmounts,
//         uint256[] calldata ramaAmounts
//     ) external;
// }

// contract ROIDistributor is Initializable, OwnableUpgradeable, UUPSUpgradeable {
//     ICoreConfig public cfg;
//     IUserRegistry public users;
//     IPortfolioManager public pm;
//     IPriceOracleDaily public oracle;

//     uint256 public dailyRateTier0; // 0.33% = 33e14
//     uint256 public dailyRateTier1; // 0.40% = 40e14
//     uint256 public dailyRateBoosterTier0; // 0.66% = 66e14
//     uint256 public dailyRateBoosterTier1; // 0.80% = 80e14

//     mapping(address => uint32) public lastClaimDay; // inclusive, 0=never
//     mapping(address => uint256) public totalClaimedUsd; // 1e18
//     mapping(address => uint256) public totalClaimedRama; // wei
//     mapping(address => uint32) public userClaimEpoch; // increments each claim

//     mapping(uint256 => uint256) public paidUsdByPid; // per-portfolio USD cap tracking

//     struct ClaimRec {
//         uint32 fromDay;
//         uint32 toDay;
//         uint256 usdTotal;
//         uint256 ramaTotal;
//         uint64 claimedAt;
//         uint32 epoch;
//     }
//     mapping(address => ClaimRec[]) internal _history;

//     struct PidClaim {
//         uint256 pid;
//         uint256 usdTotal;
//         uint256 ramaTotal;
//     }
//     mapping(address => mapping(uint32 => PidClaim[])) internal _epochPidClaims;

//     uint32 public maxDaysPerClaim; // gas guard

//     event ClaimedROI(
//         address indexed user,
//         uint32 indexed fromDay,
//         uint32 indexed toDay,
//         uint256 usdTotal,
//         uint256 ramaTotal,
//         uint32 epoch
//     );
//     event ClaimedROIByPortfolio(
//         address indexed user,
//         uint32 indexed epoch,
//         uint256 pid,
//         uint256 usdTotal,
//         uint256 ramaTotal
//     );

//     function initialize(address _cfg, address _oracle) external initializer {
//         __Ownable_init();
//         __UUPSUpgradeable_init();

//         cfg = ICoreConfig(_cfg);
//         users = IUserRegistry(cfg.userRegistry());
//         pm = IPortfolioManager(cfg.portfolioManager());
//         oracle = IPriceOracleDaily(_oracle);

//         dailyRateTier0 = 33e14;
//         dailyRateTier1 = 40e14;
//         dailyRateBoosterTier0 = 66e14;
//         dailyRateBoosterTier1 = 80e14;

//         maxDaysPerClaim = 90;
//     }

//     function _authorizeUpgrade(address) internal override onlyOwner {}

//     // ----- Admin -----
//     function setOracle(address a) external onlyOwner {
//         require(a != address(0), "ZERO_ORACLE");
//         oracle = IPriceOracleDaily(a);
//     }
//     function setRates(
//         uint256 t0,
//         uint256 t1,
//         uint256 b0,
//         uint256 b1
//     ) external onlyOwner {
//         require(t0 > 0 && t1 > 0 && b0 > 0 && b1 > 0, "BAD_RATE");
//         dailyRateTier0 = t0;
//         dailyRateTier1 = t1;
//         dailyRateBoosterTier0 = b0;
//         dailyRateBoosterTier1 = b1;
//     }
//     function setMaxDaysPerClaim(uint32 maxDays_) external onlyOwner {
//         require(maxDays_ >= 1 && maxDays_ <= 365, "RANGE");
//         maxDaysPerClaim = maxDays_;
//     }

//     // ----- Views -----
//     function getLastClaimedDay(address user) external view returns (uint32) {
//         return lastClaimDay[user];
//     }
//     function getTotalsClaimed(
//         address user
//     ) external view returns (uint256, uint256) {
//         return (totalClaimedUsd[user], totalClaimedRama[user]);
//     }
//     function getClaimHistoryCount(
//         address user
//     ) external view returns (uint256) {
//         return _history[user].length;
//     }
//     function getClaimHistorySlice(
//         address user,
//         uint256 offset,
//         uint256 limit
//     ) external view returns (ClaimRec[] memory out) {
//         ClaimRec[] storage arr = _history[user];
//         uint256 n = arr.length;
//         if (offset >= n) return new ClaimRec[](0);

//         uint256 end = offset + limit;
//         if (end > n) end = n;
//         out = new ClaimRec[](end - offset);
//         for (uint256 i = offset; i < end; i++) out[i - offset] = arr[i];
//     }
//     function getPidClaimsCount(
//         address user,
//         uint32 epoch
//     ) external view returns (uint256) {
//         return _epochPidClaims[user][epoch].length;
//     }
//     function getPidClaimsSlice(
//         address user,
//         uint32 epoch,
//         uint256 offset,
//         uint256 limit
//     ) external view returns (PidClaim[] memory out) {
//         PidClaim[] storage arr = _epochPidClaims[user][epoch];
//         uint256 n = arr.length;
//         if (offset >= n) return new PidClaim[](0);
//         uint256 end = offset + limit;
//         if (end > n) end = n;
//         out = new PidClaim[](end - offset);
//         for (uint256 i = offset; i < end; i++) out[i - offset] = arr[i];
//     }

//     /// Per-day dynamic preview (freeze+cap aware)
//     function perDayPreview(
//         address user,
//         uint32 fromDay,
//         uint32 toDay
//     )
//         external
//         view
//         returns (
//             uint32[] memory dayIds,
//             uint256[] memory usdPerDay,
//             uint256[] memory ramaPerDay
//         )
//     {
//         require(toDay >= fromDay, "RANGE");
//         uint32 latestFin = oracle.latestFinalizedDayId();
//         if (toDay > latestFin) toDay = latestFin;

//         uint256 len = uint256(toDay) - uint256(fromDay) + 1;
//         dayIds = new uint32[](len);
//         usdPerDay = new uint256[](len);
//         ramaPerDay = new uint256[](len);

//         for (uint32 d = fromDay; d <= toDay; d++) {
//             uint256 usd = _userUsdForDay_FreezeCap(user, d);
//             uint256 price = usd == 0 ? 0 : oracle.getPrice6ForDay(d);

//             uint256 rama = usd == 0 ? 0 : (usd * 1e18) / price;

//             uint256 i = uint256(d - fromDay);
//             dayIds[i] = d;
//             usdPerDay[i] = usd;

//             ramaPerDay[i] = rama;
//         }
//     }

//     /// Portfolio-wise preview for window [lastClaim+1 .. yesterday]
//     function previewClaimPerPortfolio(
//         address user
//     )
//         external
//         view
//         returns (
//             uint256[] memory pids,
//             uint256[] memory usdTotals,
//             uint256[] memory ramaTotals,
//             uint32 fromDay,
//             uint32 lastDay
//         )
//     {
//         (fromDay, lastDay) = _autoWindow(user);
//         if (lastDay < fromDay) {
//             return (
//                 new uint256[](0),
//                 new uint256[](0),
//                 new uint256[](0),
//                 fromDay,
//                 lastDay
//             );
//         }

//         uint256[] memory userPids = pm.portfoliosOf(user);
//         pids = new uint256[](userPids.length);
//         usdTotals = new uint256[](userPids.length);
//         ramaTotals = new uint256[](userPids.length);

//         for (uint256 i = 0; i < userPids.length; i++) {
//             uint256 pid = userPids[i];
//             IPortfolioManager.Portfolio memory p = pm.getPortfolio(pid);
//             if (p.owner != user) continue;
//             uint256 usdSum;
//             uint256 ramaSum;
//             for (uint32 d = fromDay; d <= lastDay; d++) {
//                 uint256 usd = _portfolioUsdForDay(p, pid, d);
//                 if (usd == 0) continue;
//                 uint256 price = oracle.getPrice6ForDay(d);
//                 usdSum += usd;
//                 ramaSum += (usd * 1e18) / price;
//             }
//             pids[i] = pid;
//             usdTotals[i] = usdSum;
//             ramaTotals[i] = ramaSum;
//         }
//     }

//     // ----- CLAIM (no inputs; auto up to yesterday) -----
//     function claimROI() external {
//         (uint32 fromDay, uint32 lastDay) = _autoWindow(msg.sender);
//         require(lastDay >= fromDay, "NOTHING");

//         uint32 span = lastDay - fromDay + 1;
//         require(span <= maxDaysPerClaim, "TOO_MANY_DAYS");

//         uint256[] memory userPids = pm.portfoliosOf(msg.sender);
//         uint256[] memory perPidUsd = new uint256[](userPids.length);
//         uint256[] memory perPidRama = new uint256[](userPids.length);

//         uint32[] memory dayIds = new uint32[](span);
//         uint256[] memory usdAmounts = new uint256[](span);
//         uint256[] memory ramaAmounts = new uint256[](span);

//         uint256 usdTotal;
//         uint256 ramaTotal;

//         for (uint32 d = fromDay; d <= lastDay; d++) {
//             uint256 usdDay;
//             for (uint256 i = 0; i < userPids.length; i++) {
//                 uint256 pid = userPids[i];
//                 IPortfolioManager.Portfolio memory p = pm.getPortfolio(pid);
//                 if (p.owner != msg.sender) continue;

//                 uint256 usdPid = _portfolioUsdForDay(p, pid, d);
//                 if (usdPid == 0) continue;
//                 usdDay += usdPid;
//             }

//             uint256 idx = uint256(d - fromDay);
//             dayIds[idx] = d;

//             if (usdDay == 0) continue;

//             uint256 price = oracle.getPrice6ForDay(d);
//             uint256 ramaDay = (usdDay * 1e18) / price;

//             usdAmounts[idx] = usdDay;
//             ramaAmounts[idx] = ramaDay;
//             usdTotal += usdDay;
//             ramaTotal += ramaDay;

//             // advance per-pid ledgers/sums using same price
//             for (uint256 i = 0; i < userPids.length; i++) {
//                 uint256 pid = userPids[i];
//                 IPortfolioManager.Portfolio memory p = pm.getPortfolio(pid);
//                 if (p.owner != msg.sender) continue;

//                 uint256 usdPid = _portfolioUsdForDay(p, pid, d);
//                 if (usdPid == 0) continue;

//                 paidUsdByPid[pid] += usdPid;
//                 perPidUsd[i] += usdPid;
//                 perPidRama[i] += (usdPid * 1e18) / price;
//             }
//         }

//         ISafeWallet(cfg.safeWallet()).creditROIUSDBatch(
//             msg.sender,
//             dayIds,
//             usdAmounts,
//             ramaAmounts
//         );

//         lastClaimDay[msg.sender] = lastDay;
//         totalClaimedUsd[msg.sender] += usdTotal;
//         totalClaimedRama[msg.sender] += ramaTotal;

//         uint32 epoch = ++userClaimEpoch[msg.sender];

//         _history[msg.sender].push(
//             ClaimRec({
//                 fromDay: fromDay,
//                 toDay: lastDay,
//                 usdTotal: usdTotal,
//                 ramaTotal: ramaTotal,
//                 claimedAt: uint64(block.timestamp),
//                 epoch: epoch
//             })
//         );

//         for (uint256 i = 0; i < userPids.length; i++) {
//             if (perPidUsd[i] == 0 && perPidRama[i] == 0) continue;
//             _epochPidClaims[msg.sender][epoch].push(
//                 PidClaim({
//                     pid: userPids[i],
//                     usdTotal: perPidUsd[i],
//                     ramaTotal: perPidRama[i]
//                 })
//             );
//             emit ClaimedROIByPortfolio(
//                 msg.sender,
//                 epoch,
//                 userPids[i],
//                 perPidUsd[i],
//                 perPidRama[i]
//             );
//         }

//         emit ClaimedROI(
//             msg.sender,
//             fromDay,
//             lastDay,
//             usdTotal,
//             ramaTotal,
//             epoch
//         );
//     }

//     // ----- Internal window helpers -----
//     function _autoWindow(
//         address user
//     ) internal view returns (uint32 fromDay, uint32 lastDay) {
//         uint32 latestFin = oracle.latestFinalizedDayId(); // yesterday
//         if (latestFin == 0) return (1, 0); // empty window safeguard

//         uint32 prev = lastClaimDay[user];
//         fromDay = prev == 0 ? _firstEligibleDay(user) : (prev + 1);
//         lastDay = latestFin;
//     }

//     function _firstEligibleDay(address user) internal view returns (uint32) {
//         uint256[] memory pids = pm.portfoliosOf(user);
//         if (pids.length == 0) return oracle.latestFinalizedDayId();
//         uint256 tmin = type(uint256).max;
//         for (uint256 i = 0; i < pids.length; i++) {
//             IPortfolioManager.Portfolio memory p = pm.getPortfolio(pids[i]);
//             if (p.owner != user) continue;
//             if (p.createdAt < tmin) tmin = p.createdAt;
//         }
//         if (tmin == type(uint256).max) return oracle.latestFinalizedDayId();
//         return uint32(tmin / 1 days);
//     }

//     // ----- Math (freeze + cap aware) -----
//     function _userUsdForDay_FreezeCap(
//         address user,
//         uint32 dayId
//     ) internal view returns (uint256 usd) {
//         uint256[] memory pids = pm.portfoliosOf(user);
//         for (uint256 i = 0; i < pids.length; i++) {
//             IPortfolioManager.Portfolio memory p = pm.getPortfolio(pids[i]);
//             if (p.owner != user) continue;
//             usd += _portfolioUsdForDay(p, pids[i], dayId);
//         }
//     }

//     function _portfolioUsdForDay(
//         IPortfolioManager.Portfolio memory p,
//         uint256 pid,
//         uint32 dayId
//     ) internal view returns (uint256 usd) {
//         if (_isFrozenOnDay(pid, dayId)) return 0;

//         uint256 principalUsd = pm.getUSDPrincipal(pid);
//         if (principalUsd == 0) return 0;

//         uint256 rate = _rateWad(p.booster, p.tier);
//         usd = (principalUsd * rate) / 1e18;

//         uint256 rem = _remainingUsdCap(pid);
//         if (usd > rem) usd = rem;
//     }

//     function _remainingUsdCap(uint256 pid) internal view returns (uint256) {
//         IPortfolioManager.Portfolio memory p = pm.getPortfolio(pid);
//         uint256 principalUsd = pm.getUSDPrincipal(pid); // 1e18
//         uint256 capUsd = (principalUsd * p.capPct) / 100; // 200/250%
//         uint256 paid = paidUsdByPid[pid];
//         return paid >= capUsd ? 0 : (capUsd - paid);
//     }

//     function _isFrozenOnDay(
//         uint256 pid,
//         uint32 dayId
//     ) internal view returns (bool) {
//         uint256 total = pm.getFreezeIntervalsCount(pid);
//         if (total == 0) return false;

//         uint32 latestFin = oracle.latestFinalizedDayId();

//         uint256 cursor = 0;
//         while (cursor < total) {
//             uint256 chunk = total - cursor;
//             if (chunk > 200) chunk = 200;
//             IPortfolioManager.FreezeInterval[] memory slice = pm
//                 .getFreezeIntervalsSlice(pid, cursor, chunk);

//             for (uint256 i = 0; i < slice.length; i++) {
//                 uint32 s = slice[i].startDay;
//                 uint32 e = slice[i].endDay;
//                 if (e == 0) {
//                     uint32 tentativeEnd = s + 3; // ~72h
//                     if (tentativeEnd > latestFin) tentativeEnd = latestFin;
//                     e = tentativeEnd;
//                 }
//                 if (dayId >= s && dayId <= e) return true;
//             }
//             cursor += chunk;
//         }
//         return false;
//     }

//     function _rateWad(
//         bool booster,
//         uint8 tier
//     ) internal view returns (uint256) {
//         if (tier == 1) return booster ? dailyRateBoosterTier1 : dailyRateTier1;
//         return booster ? dailyRateBoosterTier0 : dailyRateTier0;
//     }

//     // get portfolio wise rois

//     function ROIForAPortfolio(
//         uint256 pid,
//         uint32 fromDay,
//         uint32 toDay
//     ) external view returns (uint256 usdTotal, uint256 ramaTotal) {
//         IPortfolioManager.Portfolio memory p = pm.getPortfolio(pid);
//         address user = p.owner;
//         require(user != address(0), "INVALID_PID");

//         uint32 latestFin = oracle.latestFinalizedDayId();
//         if (toDay > latestFin) toDay = latestFin;
//         require(toDay >= fromDay, "RANGE");

//         for (uint32 d = fromDay; d <= toDay; d++) {
//             uint256 usd = _portfolioUsdForDay(p, pid, d);
//             if (usd == 0) continue;
//             uint256 price = oracle.getPrice6ForDay(d);
//             usdTotal += usd;
//             ramaTotal += (usd * 1e18) / price;
//         }
//     }

//     // get prois of portfolios that have booster enabled

//     function ROIForBoosterPortfolios(
//         address user,
//         uint32 fromDay,
//         uint32 toDay
//     ) external view returns (uint256 usdTotal, uint256 ramaTotal) {
//         uint256[] memory pids = pm.portfoliosOf(user);
//         uint32 latestFin = oracle.latestFinalizedDayId();
//         if (toDay > latestFin) toDay = latestFin;
//         require(toDay >= fromDay, "RANGE");

//         for (uint256 i = 0; i < pids.length; i++) {
//             IPortfolioManager.Portfolio memory p = pm.getPortfolio(pids[i]);
//             if (p.owner != user) continue;
//             if (!p.booster) continue;

//             for (uint32 d = fromDay; d <= toDay; d++) {
//                 uint256 usd = _portfolioUsdForDay(p, pids[i], d);
//                 if (usd == 0) continue;
//                 uint256 price = oracle.getPrice6ForDay(d);
//                 usdTotal += usd;
//                 ramaTotal += (usd * 1e18) / price;
//             }
//         }
//     }
// }
