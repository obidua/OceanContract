// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/ICoreConfig.sol";

/// Minimal interface your PM should expose for SafeWallet-driven staking.
/// Implement these in PortfolioManager and restrict them with `onlySafeWallet`.
interface IPortfolioManagerSafe {
    function createPortfolioFromSafe(
        address user,
        uint256 ramaAmount,
        address referrer
    ) external returns (uint256 pid);

    function topUpFromSafe(
        address user,
        uint256 pid,
        uint256 ramaAmount
    ) external;
}

/// @title SafeWallet (ledger + staking helpers)
/// @notice Tracks all credits/debits with typed purposes; can spend balance to create/top-up portfolios;
///         can withdraw to user’s external wallet. Still supports ROI USD+RAMA credits (single/batch).
contract SafeWallet is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    ICoreConfig public cfg;
    IERC20 public RAMA;

    // ---------------- Core balances / aggregates ----------------
    mapping(address => uint256) public ramaBalance; // RAMA wei available
    mapping(address => uint256) public roiUsdPaid; // lifetime USD ROI (WAD 1e18)
    mapping(uint32 => uint256) public dayUsdTotal; // per-day ROI USD aggregate
    mapping(uint32 => uint256) public dayRamaTotal; // per-day ROI RAMA aggregate

    // ---------------- Access control ----------------
    // modifier onlyAuthorized() {
    //     address sender = msg.sender;
    //     require(
    //         sender == cfg.incomeDistributor() ||
    //             sender == cfg.portfolioManager() ||
    //             sender == cfg.adminControl() || // optional
    //             sender == cfg.treasury() || // optional
    //             sender == _roiDistributor(),
    //         "NOT_AUTH"
    //     );
    //     _;
    // }

    modifier onlyAuthorized() {
        address s = msg.sender;
        require(
            s == cfg.incomeDistributor() ||
                s == cfg.portfolioManager() ||
                s == cfg.slabManager() ||
                s == cfg.royaltyManager() ||
                s == cfg.rewardVault() ||
                s == cfg.adminControl() || // optional ops
                s == cfg.treasury() || // optional ops
                s == _roiDistributor(), // explicit ROIDistributor set
            "NOT_AUTH"
        );
        _;
    }

    // --- ROIDistributor explicit allow-list slot (optional) ---
    address private _roiDist;
    function setRoiDistributor(address a) external onlyOwner {
        require(a != address(0), "ZERO");
        _roiDist = a;
    }
    function _roiDistributor() internal view returns (address) {
        return _roiDist;
    }

    // ----------------- Typed Ledger -----------------
    // What happened & why (purpose code). Kept small (uint8) to save gas.
    enum TxKind {
        // credits
        ROI, // daily ROI credited (per day / batch)
        Growth, // internal growth credit (legacy hook)
        Royalty, // royalty payout (if you choose to record here)
        Slab, // slab payout (if you choose to record here)
        Reward, // one-time reward
        DirectIncome, // direct income commissions
        ManualCredit, // admin/manual credit
        // debits
        StakeSpend, // balance used to stake (moved to Treasury/PM)
        PortfolioCreate, // portfolio created using SafeWallet funds
        PortfolioTopUp, // portfolio topped up using SafeWallet funds
        ExternalWithdraw // user withdrew RAMA to external wallet
    }

    struct LedgerEntry {
        uint8 kind; // TxKind
        bool isCredit; // true = credit, false = debit
        uint256 usdAmount; // 1e18 WAD (0 if N/A)
        uint256 ramaAmount; // wei
        uint32 dayId; // ROI day, if applicable (0 otherwise)
        uint64 timestamp; // block.timestamp
        address related; // referrer/upline/recipient/PM/etc
        uint256 pid; // portfolio id (create/top-up), else 0
        bytes32 memo; // optional tag (free-form hashed label)
    }

    // User -> ledger
    mapping(address => LedgerEntry[]) private _ledger;
    // Fast totals (for dashboards)
    mapping(address => uint256) public totalCreditsUSD;
    mapping(address => uint256) public totalCreditsRAMA;
    mapping(address => uint256) public totalDebitsUSD;
    mapping(address => uint256) public totalDebitsRAMA;

    // ---------------- Events ----------------
    event ROIUSDRecorded(
        address indexed user,
        uint32 indexed dayId,
        uint256 usdAmount,
        uint256 ramaAmount
    );
    event GrowthCredited(address indexed user, uint256 ramaAmount);
    event Debited(address indexed user, uint256 amount, address to);

    event LedgerRecorded(
        address indexed user,
        uint8 kind,
        bool isCredit,
        uint256 usdAmount,
        uint256 ramaAmount,
        uint32 dayId,
        address indexed related,
        uint256 pid,
        bytes32 memo
    );

    /* ------------------------- Init / Upgrade ------------------------- */
    function initialize(address _cfg) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        cfg = ICoreConfig(_cfg);
        RAMA = IERC20(cfg.rama());
    }
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /* ========================= CREDIT HOOKS ========================== */
    /// Single-day ROI credit (kept for compatibility)
    function creditROIUSD(
        address user,
        uint256 usdAmount, // 1e18 WAD
        uint256 ramaAmount, // wei
        uint32 dayId
    ) external onlyAuthorized {
        // balance
        ramaBalance[user] += ramaAmount;
        // analytics
        roiUsdPaid[user] += usdAmount;
        dayUsdTotal[dayId] += usdAmount;
        dayRamaTotal[dayId] += ramaAmount;

        // ledger
        _recordCredit(
            user,
            TxKind.ROI,
            usdAmount,
            ramaAmount,
            dayId,
            address(0),
            0,
            bytes32(0)
        );
        emit ROIUSDRecorded(user, dayId, usdAmount, ramaAmount);
    }

    /// Batch ROI credit
    function creditROIUSDBatch(
        address user,
        uint32[] calldata dayIds,
        uint256[] calldata usdAmounts,
        uint256[] calldata ramaAmounts
    ) external onlyAuthorized {
        require(
            dayIds.length == usdAmounts.length &&
                dayIds.length == ramaAmounts.length,
            "ARRAY_LEN"
        );

        uint256 usdSum;
        uint256 ramaSum;
        for (uint256 i = 0; i < dayIds.length; i++) {
            roiUsdPaid[user] += usdAmounts[i];
            dayUsdTotal[dayIds[i]] += usdAmounts[i];
            dayRamaTotal[dayIds[i]] += ramaAmounts[i];
            usdSum += usdAmounts[i];
            ramaSum += ramaAmounts[i];

            // per-day ledger rows (optional but useful for analytics drill-down)
            _recordCredit(
                user,
                TxKind.ROI,
                usdAmounts[i],
                ramaAmounts[i],
                dayIds[i],
                address(0),
                0,
                bytes32(0)
            );
            emit ROIUSDRecorded(user, dayIds[i], usdAmounts[i], ramaAmounts[i]);
        }
        // credit user's balance once
        ramaBalance[user] += ramaSum;
    }

    /// Legacy growth credit
    function creditGrowth(
        address user,
        uint256 ramaAmount
    ) external onlyAuthorized {
        ramaBalance[user] += ramaAmount;
        _recordCredit(
            user,
            TxKind.Growth,
            0,
            ramaAmount,
            0,
            msg.sender,
            0,
            bytes32("growth")
        );
        emit GrowthCredited(user, ramaAmount);
    }

    /// General-purpose credits (royalty, slab, reward, direct income, manual)
    function creditGeneral(
        address user,
        TxKind kind, // must be ROI..ManualCredit but not a debit kind
        uint256 usdAmount, // 1e18 WAD
        uint256 ramaAmount, // wei
        bytes32 memo
    ) external onlyAuthorized {
        require(uint8(kind) <= uint8(TxKind.ManualCredit), "BAD_KIND");
        ramaBalance[user] += ramaAmount;
        _recordCredit(
            user,
            kind,
            usdAmount,
            ramaAmount,
            0,
            msg.sender,
            0,
            memo
        );
    }

    /* ========================= DEBITS / ACTIONS ======================= */

    /// @notice Create a new portfolio for msg.sender using SafeWallet balance.
    /// @param ramaAmount amount to stake (wei) — must be <= ramaBalance[msg.sender]
    /// @param referrer referrer (if your PM requires it)
    function createPortfolioFromSafe(
        uint256 ramaAmount,
        address referrer
    ) external returns (uint256 pid) {
        require(ramaAmount > 0, "AMOUNT_0");
        require(ramaBalance[msg.sender] >= ramaAmount, "INSUFFICIENT");

        // move tokens to Treasury (or PM) then call PM to create portfolio record
        ramaBalance[msg.sender] -= ramaAmount;
        require(RAMA.transfer(cfg.treasury(), ramaAmount), "TRANSFER_FAIL");

        pid = IPortfolioManagerSafe(cfg.portfolioManager())
            .createPortfolioFromSafe(msg.sender, ramaAmount, referrer);

        // ledger: one debit row for the spend and a typed "PortfolioCreate"
        _recordDebit(
            msg.sender,
            TxKind.StakeSpend,
            0,
            ramaAmount,
            0,
            cfg.treasury(),
            pid,
            bytes32("stake_spend")
        );
        _recordDebit(
            msg.sender,
            TxKind.PortfolioCreate,
            0,
            0,
            0,
            cfg.portfolioManager(),
            pid,
            bytes32("pm_record")
        );
        emit Debited(msg.sender, ramaAmount, cfg.treasury());
    }

    /// @notice Create a new portfolio for another user (sponsor funds).
    function createPortfolioFor(
        address beneficiary,
        uint256 ramaAmount,
        address referrer
    ) external returns (uint256 pid) {
        require(beneficiary != address(0), "ZERO_BENEFICIARY");
        require(ramaAmount > 0, "AMOUNT_0");
        require(ramaBalance[msg.sender] >= ramaAmount, "INSUFFICIENT");

        ramaBalance[msg.sender] -= ramaAmount;
        require(RAMA.transfer(cfg.treasury(), ramaAmount), "TRANSFER_FAIL");

        pid = IPortfolioManagerSafe(cfg.portfolioManager())
            .createPortfolioFromSafe(beneficiary, ramaAmount, referrer);

        _recordDebit(
            msg.sender,
            TxKind.StakeSpend,
            0,
            ramaAmount,
            0,
            cfg.treasury(),
            pid,
            bytes32("stake_for_other")
        );
        _recordDebit(
            msg.sender,
            TxKind.PortfolioCreate,
            0,
            0,
            0,
            cfg.portfolioManager(),
            pid,
            bytes32("pm_record")
        );
        emit Debited(msg.sender, ramaAmount, cfg.treasury());
    }

    /// @notice Top-up an existing portfolio owned by msg.sender using SafeWallet funds.
    function topUpPortfolioFromSafe(uint256 pid, uint256 ramaAmount) external {
        require(ramaAmount > 0, "AMOUNT_0");
        require(ramaBalance[msg.sender] >= ramaAmount, "INSUFFICIENT");

        ramaBalance[msg.sender] -= ramaAmount;
        require(RAMA.transfer(cfg.treasury(), ramaAmount), "TRANSFER_FAIL");

        IPortfolioManagerSafe(cfg.portfolioManager()).topUpFromSafe(
            msg.sender,
            pid,
            ramaAmount
        );

        _recordDebit(
            msg.sender,
            TxKind.StakeSpend,
            0,
            ramaAmount,
            0,
            cfg.treasury(),
            pid,
            bytes32("topup_spend")
        );
        _recordDebit(
            msg.sender,
            TxKind.PortfolioTopUp,
            0,
            0,
            0,
            cfg.portfolioManager(),
            pid,
            bytes32("pm_topup")
        );
        emit Debited(msg.sender, ramaAmount, cfg.treasury());
    }

    /// @notice Withdraw RAMA from SafeWallet to an external address (user’s main wallet).
    function claimToExternal(uint256 amount, address to) external {
        require(to != address(0), "ZERO_TO");
        require(amount > 0, "AMOUNT_0");
        require(ramaBalance[msg.sender] >= amount, "INSUFFICIENT");

        ramaBalance[msg.sender] -= amount;
        require(RAMA.transfer(to, amount), "TRANSFER_FAIL");

        _recordDebit(
            msg.sender,
            TxKind.ExternalWithdraw,
            0,
            amount,
            0,
            to,
            0,
            bytes32("external_withdraw")
        );
        emit Debited(msg.sender, amount, to);
    }

    /* ========================= Ledger Views ========================== */

    function getLedgerCount(address user) external view returns (uint256) {
        return _ledger[user].length;
    }

    function getLedgerSlice(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (LedgerEntry[] memory out) {
        LedgerEntry[] storage arr = _ledger[user];
        uint256 n = arr.length;
        if (offset >= n) return new LedgerEntry[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;

        out = new LedgerEntry[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = arr[i];
        }
    }

    /* ========================= Internal: Ledger ====================== */

    function _recordCredit(
        address user,
        TxKind kind,
        uint256 usdAmount,
        uint256 ramaAmount,
        uint32 dayId,
        address related,
        uint256 pid,
        bytes32 memo
    ) internal {
        _ledger[user].push(
            LedgerEntry({
                kind: uint8(kind),
                isCredit: true,
                usdAmount: usdAmount,
                ramaAmount: ramaAmount,
                dayId: dayId,
                timestamp: uint64(block.timestamp),
                related: related,
                pid: pid,
                memo: memo
            })
        );
        totalCreditsUSD[user] += usdAmount;
        totalCreditsRAMA[user] += ramaAmount;

        emit LedgerRecorded(
            user,
            uint8(kind),
            true,
            usdAmount,
            ramaAmount,
            dayId,
            related,
            pid,
            memo
        );
    }

    function _recordDebit(
        address user,
        TxKind kind,
        uint256 usdAmount,
        uint256 ramaAmount,
        uint32 dayId,
        address related,
        uint256 pid,
        bytes32 memo
    ) internal {
        _ledger[user].push(
            LedgerEntry({
                kind: uint8(kind),
                isCredit: false,
                usdAmount: usdAmount,
                ramaAmount: ramaAmount,
                dayId: dayId,
                timestamp: uint64(block.timestamp),
                related: related,
                pid: pid,
                memo: memo
            })
        );
        totalDebitsUSD[user] += usdAmount;
        totalDebitsRAMA[user] += ramaAmount;

        emit LedgerRecorded(
            user,
            uint8(kind),
            false,
            usdAmount,
            ramaAmount,
            dayId,
            related,
            pid,
            memo
        );
    }

    // ========= Simple getters =========
    function balanceOf(address user) external view returns (uint256) {
        return ramaBalance[user];
    }

    function getDayTotals(
        uint32 dayId
    ) external view returns (uint256 usdTotal_, uint256 ramaTotal_) {
        return (dayUsdTotal[dayId], dayRamaTotal[dayId]);
    }

    function getTotals(
        address user
    )
        external
        view
        returns (
            uint256 _ramaBalance,
            uint256 _roiUsdPaid,
            uint256 _totalCreditsUSD,
            uint256 _totalCreditsRAMA,
            uint256 _totalDebitsUSD,
            uint256 _totalDebitsRAMA
        )
    {
        return (
            ramaBalance[user],
            roiUsdPaid[user],
            totalCreditsUSD[user],
            totalCreditsRAMA[user],
            totalDebitsUSD[user],
            totalDebitsRAMA[user]
        );
    }

    /// @notice Sum of user’s ROI (USD & RAMA) for a specific dayId (from ledger rows).
    function getUserRoiForDay(
        address user,
        uint32 dayId
    ) external view returns (uint256 usdSum, uint256 ramaSum) {
        LedgerEntry[] storage arr = _ledger[user];
        uint256 n = arr.length;
        for (uint256 i = 0; i < n; i++) {
            LedgerEntry storage e = arr[i];
            if (e.isCredit && e.kind == uint8(TxKind.ROI) && e.dayId == dayId) {
                usdSum += e.usdAmount;
                ramaSum += e.ramaAmount;
            }
        }
    }

    /// @notice Return up to `limit` latest ledger entries (most recent first).
    function getLastTransactions(
        address user,
        uint256 limit
    ) external view returns (LedgerEntry[] memory out) {
        LedgerEntry[] storage arr = _ledger[user];
        uint256 n = arr.length;
        if (limit > n) limit = n;
        out = new LedgerEntry[](limit);
        // copy newest first
        for (uint256 i = 0; i < limit; i++) {
            out[i] = arr[n - 1 - i];
        }
    }

    /// @notice Paginated scan of entries that match `kind` and `isCredit`.
    /// @dev `offset`/`limit` apply to the MATCHED list (not raw ledger).
    function getTransactionsByKind(
        address user,
        uint8 kind,
        bool isCredit,
        uint256 offset,
        uint256 limit
    ) external view returns (LedgerEntry[] memory slice, uint256 totalMatched) {
        LedgerEntry[] storage arr = _ledger[user];
        uint256 n = arr.length;

        // First pass: count matches
        for (uint256 i = 0; i < n; i++) {
            if (arr[i].kind == kind && arr[i].isCredit == isCredit)
                totalMatched++;
        }
        if (offset >= totalMatched) return (new LedgerEntry[](0), totalMatched);

        // Second pass: collect matches into a compact temp buffer
        LedgerEntry[] memory tmp = new LedgerEntry[](totalMatched);
        uint256 k = 0;
        for (uint256 i = 0; i < n; i++) {
            if (arr[i].kind == kind && arr[i].isCredit == isCredit) {
                tmp[k++] = arr[i];
            }
        }

        // Apply pagination on the matched array
        uint256 end = offset + limit;
        if (end > totalMatched) end = totalMatched;
        slice = new LedgerEntry[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            slice[i - offset] = tmp[i];
        }
    }

    /// @notice Sum user totals for a given kind (credit or debit) from ledger.
    function getTotalsByKind(
        address user,
        uint8 kind,
        bool isCredit
    ) external view returns (uint256 usdSum, uint256 ramaSum, uint256 count) {
        LedgerEntry[] storage arr = _ledger[user];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i].kind == kind && arr[i].isCredit == isCredit) {
                usdSum += arr[i].usdAmount;
                ramaSum += arr[i].ramaAmount;
                count++;
            }
        }
    }

    function getTotalsSince(
        address user,
        uint64 sinceTs,
        bool creditSide
    ) external view returns (uint256 usdSum, uint256 ramaSum, uint256 count) {
        LedgerEntry[] storage arr = _ledger[user];
        for (uint256 i = 0; i < arr.length; i++) {
            LedgerEntry storage e = arr[i];
            if (e.isCredit == creditSide && e.timestamp >= sinceTs) {
                usdSum += e.usdAmount;
                ramaSum += e.ramaAmount;
                count++;
            }
        }
    }

    /// @notice Withdraw the user’s entire SafeWallet balance to `to`.
    function claimAllTo(address to) external {
        require(to != address(0), "ZERO_TO");
        uint256 amt = ramaBalance[msg.sender];
        require(amt > 0, "NOTHING");
        ramaBalance[msg.sender] = 0;
        require(RAMA.transfer(to, amt), "TRANSFER_FAIL");

        _recordDebit(
            msg.sender,
            TxKind.ExternalWithdraw,
            0,
            amt,
            0,
            to,
            0,
            bytes32("external_withdraw_all")
        );
        emit Debited(msg.sender, amt, to);
    }

    /// @notice Top-up someone else’s portfolio using the caller’s SafeWallet funds.
    /// @dev Requires PortfolioManagerSafe.topUpFromSafe to accept `user` param.
    function topUpPortfolioFor(
        address beneficiary,
        uint256 pid,
        uint256 ramaAmount
    ) external {
        require(beneficiary != address(0), "ZERO_BENEFICIARY");
        require(ramaAmount > 0, "AMOUNT_0");
        require(ramaBalance[msg.sender] >= ramaAmount, "INSUFFICIENT");

        ramaBalance[msg.sender] -= ramaAmount;
        require(RAMA.transfer(cfg.treasury(), ramaAmount), "TRANSFER_FAIL");

        IPortfolioManagerSafe(cfg.portfolioManager()).topUpFromSafe(
            beneficiary, // <-- tops up on beneficiary's pid
            pid,
            ramaAmount
        );

        _recordDebit(
            msg.sender,
            TxKind.StakeSpend,
            0,
            ramaAmount,
            0,
            cfg.treasury(),
            pid,
            bytes32("topup_for_other")
        );
        _recordDebit(
            msg.sender,
            TxKind.PortfolioTopUp,
            0,
            0,
            0,
            cfg.portfolioManager(),
            pid,
            bytes32("pm_topup_for_other")
        );
        emit Debited(msg.sender, ramaAmount, cfg.treasury());
    }
}

// pragma solidity ^0.8.24;

// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// import "./interfaces/IERC20.sol";
// import "./interfaces/ICoreConfig.sol";

// contract SafeWallet is Initializable, OwnableUpgradeable, UUPSUpgradeable {
//     ICoreConfig public cfg;
//     IERC20 public RAMA;

//     // Internal ledgers
//     mapping(address => uint256) public ramaBalance; // RAMA wei credited to user inside SafeWallet
//     mapping(address => uint256) public roiUsdPaid; // lifetime USD ROI (1e18 WAD)
//     mapping(uint32 => uint256) public dayUsdTotal; // per-day USD aggregate
//     mapping(uint32 => uint256) public dayRamaTotal; // per-day RAMA aggregate

//     event ROIUSDRecorded(
//         address indexed user,
//         uint32 indexed dayId,
//         uint256 usdAmount,
//         uint256 ramaAmount
//     );
//     event GrowthCredited(address indexed user, uint256 ramaAmount);
//     event Debited(address indexed user, uint256 amount, address to);

//     modifier onlyAuthorized() {
//         address sender = msg.sender;
//         require(
//             sender == cfg.incomeDistributor() ||
//                 sender == cfg.portfolioManager() ||
//                 sender == cfg.adminControl() || // optional
//                 sender == cfg.treasury() || // optional
//                 sender == _roiDistributor(),
//             "NOT_AUTH"
//         );
//         _;
//     }

//     function initialize(address _cfg) external initializer {
//         __Ownable_init();
//         __UUPSUpgradeable_init();
//         cfg = ICoreConfig(_cfg);
//         RAMA = IERC20(cfg.rama());
//     }

//     // ---- hook used by ROIDistributor ----
//     function creditROIUSD(
//         address user,
//         uint256 usdAmount, // 1e18 WAD USD
//         uint256 ramaAmount, // RAMA wei
//         uint32 dayId // uint32(block.timestamp / 1 days)
//     ) external onlyAuthorized {
//         // credit RAMA to internal balance
//         ramaBalance[user] += ramaAmount;

//         // track USD+RAMA analytics
//         roiUsdPaid[user] += usdAmount;
//         dayUsdTotal[dayId] += usdAmount;
//         dayRamaTotal[dayId] += ramaAmount;

//         emit ROIUSDRecorded(user, dayId, usdAmount, ramaAmount);
//     }

//     // Optional: growth credit (from internal accrue if you still use it)
//     function creditGrowth(
//         address user,
//         uint256 ramaAmount
//     ) external onlyAuthorized {
//         ramaBalance[user] += ramaAmount;
//         emit GrowthCredited(user, ramaAmount);
//     }

//     // --- wiring: store ROIDistributor address locally (or keep it in CoreConfig if you prefer) ---
//     address private _roiDist;

//     function setRoiDistributor(address a) external onlyOwner {
//         require(a != address(0), "ZERO");
//         _roiDist = a;
//     }

//     function _roiDistributor() internal view returns (address) {
//         return _roiDist;
//     }

//     /// @notice Spend user's SafeWallet RAMA balance for staking (internal transfer).
//     /// Called only by PortfolioManager. Transfers RAMA held by this contract to `to`.
//     function spendForStake(address user, uint256 amount, address to) external {
//         require(msg.sender == cfg.portfolioManager(), "NOT_PM");
//         require(ramaBalance[user] >= amount, "INSUFFICIENT");
//         ramaBalance[user] -= amount;

//         require(RAMA.transfer(to, amount), "TRANSFER_FAIL");
//         emit Debited(user, amount, to);
//     }

//     function creditROIUSDBatch(
//         address user,
//         uint32[] calldata dayIds,
//         uint256[] calldata usdAmounts,
//         uint256[] calldata ramaAmounts
//     ) external onlyAuthorized {
//         require(
//             dayIds.length == usdAmounts.length &&
//                 dayIds.length == ramaAmounts.length,
//             "ARRAY_LEN"
//         );

//         uint256 usdSum;
//         uint256 ramaSum;
//         for (uint256 i = 0; i < dayIds.length; i++) {
//             // same internal accounting you do in creditROIUSD(...)
//             roiUsdPaid[user] += usdAmounts[i];
//             dayUsdTotal[dayIds[i]] += usdAmounts[i];
//             dayRamaTotal[dayIds[i]] += ramaAmounts[i];
//             usdSum += usdAmounts[i];
//             ramaSum += ramaAmounts[i];
//             emit ROIUSDRecorded(user, dayIds[i], usdAmounts[i], ramaAmounts[i]);
//         }
//         // credit user's RAMA balance once for the total
//         ramaBalance[user] += ramaSum;
//     }

//     function _authorizeUpgrade(address) internal override onlyOwner {}
// }
