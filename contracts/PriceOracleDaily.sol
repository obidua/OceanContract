// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/IPriceOracleDaily.sol";

/// @title PriceOracleDaily (6-decimal storage with WAD view)
/// @notice Stores a single RAMA/USD price per UTC day.
///         - Storage & inputs: 6 decimals (1e6) => e.g., $1.234567 = 1_234_567
///         - getPrice6ForDay(dayId) returns 6-dec price with fallback:
///             * If querying a finalized day earlier than the first ever set day,
///               returns that first-ever price (exactly as you wanted).
///             * If querying a day between known set days, returns the latest
///               earlier set price (back-fill).
///         - getPriceWadForDay(dayId) returns 1e18 WAD by multiplying 6-dec price by 1e12.
///         - A day is considered FINAL once it is <= yesterday (UTC).
contract PriceOracleDaily is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IPriceOracleDaily
{
    struct DayPrice {
        uint256 price6; // USD per RAMA, 6 decimals (1e6 scale)
        uint64 setAt; // block.timestamp when last set
        bool isSet; // set at least once
    }

    /// @dev dayId = uint32(timestamp / 1 days) in UTC.
    mapping(uint32 => DayPrice) private prices;

    /// @dev Track first ever set day & price (for fallback)
    uint32 public firstSetDayId; // 0 if never set
    uint256 public firstSetPrice6; // 0 if never set, 6-decimals

    /// @dev Addresses allowed to push the daily price (your bot(s))
    mapping(address => bool) public isUpdater;

    event UpdaterSet(address indexed updater, bool allowed);
    event PriceSet(uint32 indexed dayId, uint256 price6, uint64 setAt);
    event BackfillSet(uint32 indexed dayId, uint256 price6, uint64 setAt);

    modifier onlyUpdater() {
        require(isUpdater[msg.sender] || msg.sender == owner(), "NOT_UPDATER");
        _;
    }

    /* -------------------------------- Init / Upgrade ------------------------------- */

    function initialize(address initialUpdater) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        if (initialUpdater != address(0)) {
            isUpdater[initialUpdater] = true;
            emit UpdaterSet(initialUpdater, true);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /* --------------------------------- Admin -------------------------------------- */

    /// @notice Allow/revoke an updater (your off-chain publisher).
    function setUpdater(address who, bool allow) external onlyOwner {
        require(who != address(0), "ZERO_ADDR");
        isUpdater[who] = allow;
        emit UpdaterSet(who, allow);
    }

    /// @notice Owner backfill for past days or corrections (use cautiously).
    /// @dev Can write any dayId, even finalized ones (for emergencies/audits).
    ///      Price is 6-decimals (1e6).
    function ownerBackfill(uint32 dayId, uint256 price6) external onlyOwner {
        require(price6 > 0, "PRICE_ZERO");
        DayPrice storage d = prices[dayId];
        d.price6 = price6;
        d.setAt = uint64(block.timestamp);
        d.isSet = true;

        // update "first set" tracker if needed
        if (firstSetDayId == 0 || dayId < firstSetDayId) {
            firstSetDayId = dayId;
            firstSetPrice6 = price6;
        }

        emit BackfillSet(dayId, price6, d.setAt);
    }

    /* -------------------------------- Updater flow -------------------------------- */

    /// @notice Set price (6-decimals) for a given UTC day. Can be called at any time before finalization.
    function setPrice6ForDay(uint32 dayId, uint256 price6) public onlyUpdater {
        require(price6 > 0, "PRICE_ZERO");
        // Block normal updates on finalized days (immutability after D+1 midnight)
        require(!_finalized(dayId), "DAY_FINALIZED");

        DayPrice storage d = prices[dayId];
        d.price6 = price6;
        d.setAt = uint64(block.timestamp);
        d.isSet = true;

        // set first-ever if not set yet, or if this is earlier than recorded first
        if (firstSetDayId == 0 || dayId < firstSetDayId) {
            firstSetDayId = dayId;
            firstSetPrice6 = price6;
        }

        emit PriceSet(dayId, price6, d.setAt);
    }

    /// @notice Convenience: set today's price (UTC) in 6 decimals.
    function setTodayPrice6(uint256 price6) external onlyUpdater {
        setPrice6ForDay(todayId(), price6);
    }

    /* --------------------------------- Views -------------------------------------- */

    /// @notice 6-dec reader with fallback as requested.
    function getPrice6ForDay(uint32 dayId) public view returns (uint256) {
        // A day is finalized if it's <= latest finalized (yesterday)
        uint32 latestFin = _latestFinalizedDayId();
        require(dayId <= latestFin, "NOT_FINALIZED");

        // If no price has ever been set, we cannot answer
        require(firstSetDayId != 0 && firstSetPrice6 != 0, "NO_PRICE_HISTORY");

        // If querying a day strictly before the first ever set day,
        // return the very first price (exact requirement).
        if (dayId < firstSetDayId) {
            return firstSetPrice6;
        }

        // Try exact day
        DayPrice memory dpExact = prices[dayId];
        if (dpExact.isSet) return dpExact.price6;

        // Search backward down to (and including) firstSetDayId.
        // There MUST be a set price at firstSetDayId, so loop will succeed.
        for (uint32 d = dayId; d > firstSetDayId; d--) {
            DayPrice memory dp = prices[d - 1]; // check previous day
            if (dp.isSet) return dp.price6;
        }

        // If nothing in between was found, return the first ever price.
        return firstSetPrice6;
    }

    /// @inheritdoc IPriceOracleDaily
    /// @dev Backward compatibility: convert stored 6-dec price to 1e18 WAD by *1e12.
    function getPriceWadForDay(uint32 dayId) external view returns (uint256) {
        uint256 p6 = getPrice6ForDay(dayId);
        return p6 * 1e12; // 1e6 -> 1e18
    }

    /// @inheritdoc IPriceOracleDaily
    function getRaw(
        uint32 dayId
    ) external view returns (uint256 priceWad, bool isSet, uint64 setAt) {
        DayPrice memory d = prices[dayId];
        // expose 1e18 WAD for compatibility in this raw view
        return (d.price6 == 0 ? 0 : d.price6 * 1e12, d.isSet, d.setAt);
    }

    /// @inheritdoc IPriceOracleDaily
    function isFinalized(uint32 dayId) external view returns (bool) {
        return _finalized(dayId);
    }

    /// @inheritdoc IPriceOracleDaily
    function todayId() public view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }

    /// @inheritdoc IPriceOracleDaily
    function latestFinalizedDayId() external view returns (uint32) {
        return _latestFinalizedDayId();
    }

    /* ------------------------------- Internal ------------------------------------- */

    function _latestFinalizedDayId() internal view returns (uint32) {
        // The most recent finalized day is yesterday (todayId() - 1)
        uint32 t = uint32(block.timestamp / 1 days);
        return t == 0 ? 0 : t - 1;
    }

    function _finalized(uint32 dayId) internal view returns (bool) {
        // finalized when current time is at/after start of NEXT day
        return block.timestamp >= (uint256(dayId) + 1) * 1 days;
    }
}
