// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/ICoreConfig.sol";
import "./interfaces/IUserRegistry.sol";
import "./interfaces/IPortfolioManager.sol";

import "./libraries/OceanErrors.sol";
import "./libraries/FixedPoint.sol";
import "./interfaces/IRamaOracle.sol";

contract PortfolioManager is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IPortfolioManager
{
    using Address for address;
    using FixedPoint for uint256;
    // using IPortfolioManager.Portfolio;

    ICoreConfig public cfg;
    // IERC20 public RAMA;
    IUserRegistry public users;

    uint256 public constant WAD = 1e18;

    IPortfolioManager.Portfolio[] internal portfolios; // pid => data (pid starts at 1 with a dummy)
    mapping(address => uint256[]) public _portfoliosOf; // owner => pids

    // Booster tracking (window keyed off firstStakeAt)
    struct BoosterTrack {
        uint256 firstStakeAt; // when the user created their first portfolio
        uint256 directBusiness; // (legacy field, not used in new booster calc)
        uint32 directsCount; // (legacy field, not used in new booster calc)
    }
    mapping(address => BoosterTrack) public booster;

    // rates expressed per day in WAD

    uint256 public dailyRateTier0; // 0.33% normal
    uint256 public dailyRateTier1; // 0.40% normal
    uint256 public dailyRateBoosterTier0; // 0.66%
    uint256 public dailyRateBoosterTier1; // 0.80%

    event NoteNew50Direct(
        address indexed referrer,
        address indexed direct,
        uint256 amountUSD
    );
    event BoosterRecomputed(
        address indexed user,
        uint256 capacityUSD,
        uint256 sumSelectedUSD,
        uint256[] selectedPids
    );

    // // day-based freeze intervals per pid
    mapping(uint256 => FreezeInterval[]) internal _freezeByPid;

    // =========================
    // SafeWallet staking audit
    // =========================

    // pid => creation metadata (only for portfolios funded via SafeWallet entrypoints)
    struct SafeCreateInfo {
        uint256 pid;
        uint256 ramaAmount; // wei
        uint256 usdMicro; // 1e6
        address caller; // who paid in SafeWallet (self == beneficiary for createPortfolioFromSafe)
        address beneficiary; // portfolio owner
        uint64 createdAt; // block.timestamp
    }
    mapping(uint256 => SafeCreateInfo) public safeCreateByPid;
    mapping(address => uint256[]) public PortfoliosCreatedForOthers;

    // Indexes (for fast per-address queries)
    mapping(address => uint256[]) private _safeSelfPids; // user -> pids created by user for self (createPortfolioFromSafe)
    mapping(address => uint256[]) private _safeCallerPids; // caller -> pids created for others (createPortfolioForOthersFromSafe)
    mapping(address => uint256[]) private _safeReceivedPids; // beneficiary -> pids received from a caller (others)

    // Events
    event PortfolioCreatedFromSafe(
        address indexed user,
        uint256 indexed pid,
        uint256 ramaAmount,
        uint256 usdMicro
    );

    event PortfolioCreatedForOthersFromSafe(
        address indexed caller,
        address indexed beneficiary,
        uint256 indexed pid,
        uint256 ramaAmount,
        uint256 usdMicro
    );

    event FreezeIntervalOpened(uint256 indexed pid, uint32 startDay);
    event FreezeIntervalClosed(
        uint256 indexed pid,
        uint32 startDay,
        uint32 endDay
    );
    event BoosterActivated(
        address indexed activated_for,
        uint256 portfolioAmount,
        uint256 boosterPercentage,
        uint256 activatedAt
    );

    function initialize(address _cfg) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        cfg = ICoreConfig(_cfg);
        // RAMA = IERC20(cfg.rama());
        users = IUserRegistry(cfg.userRegistry());

        dailyRateTier0 = 33e14; // 0.33%
        dailyRateTier1 = 40e14; // 0.40%
        dailyRateBoosterTier0 = 66e14; // 0.66%
        dailyRateBoosterTier1 = 80e14; // 0.80%

        // push dummy so pids start at 1
        portfolios.push();
    }

    function _todayId() internal view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }

    modifier onlyRegistered() {
        require(users.isRegistered(msg.sender), OceanErrors.NotRegistered);
        _;
    }

    function checkWhetherUserIsRegistered() external view returns (bool) {
        return users.isRegistered(msg.sender);
    }

    function setContracts(address _userRegistry) external onlyOwner {
        require(_userRegistry != address(0), OceanErrors.ZeroAddress);

        users = IUserRegistry(_userRegistry);
    }

    function _ramaOfUsd(uint256 ramaAmount) internal view returns (uint256) {
        uint256 priceMicroUSD = IRamaOracle(cfg.priceOracle()).ramaToUSD(
            ramaAmount
        ); // 1e6 = $1.000000
        require(priceMicroUSD > 0, "Invalid oracle price");
        return priceMicroUSD;
    }

    function getPriceOracleAddress() external view returns (address) {
        return cfg.priceOracle();
    }

    function _usdOfRama(uint256 usdAmount) internal view returns (uint256) {
        uint256 finalAmount = IRamaOracle(cfg.priceOracle()).usdToRama(
            usdAmount
        );

        require(finalAmount > 0, "Invalid oracle price");

        return finalAmount;
    }

    function _readRamaPriceWad() internal view returns (uint256) {
        uint256 priceMicroUSD = IRamaOracle(cfg.priceOracle()).ramaPriceInUSD(); // e.g., 2_000_000 = $2.000000
        require(priceMicroUSD > 0, "Invalid oracle price");
        // convert micro-USD (1e6) -> 18-decimals
        return priceMicroUSD;
    }
    function _readRamaPriceMicroUSD() internal view returns (uint256) {
        uint256 priceMicroUSD = IRamaOracle(cfg.priceOracle()).ramaPriceInUSD(); // e.g., 2_000_000 = $2.000000
        require(priceMicroUSD > 0, "Invalid oracle price");
        // convert micro-USD (1e6) -> 18-decimals

        return priceMicroUSD;
    }
    function getRAMAPriceWad() external view returns (uint256) {
        return _readRamaPriceMicroUSD();
    }

    function getPackageValueInRAMA(
        uint256 usdAmount
    ) external view returns (uint256) {
        return _usdOfRama(usdAmount);
    }

    function getPackageValueInUSD(
        uint256 ramaAmount
    ) external view returns (uint256) {
        return _ramaOfUsd(ramaAmount);
    }

    function _tier(uint256 usdAmount) internal pure returns (uint8) {
        return usdAmount >= 5010e18 ? 1 : 0;
    }

    function _rate(bool booster_, uint8 tier_) internal view returns (uint256) {
        if (tier_ == 1)
            return booster_ ? dailyRateBoosterTier1 : dailyRateTier1;
        return booster_ ? dailyRateBoosterTier0 : dailyRateTier0;
    }

    function getValues(
        uint256 ramaWei
    ) external view returns (uint256 minStakeAmount, uint256 usdValue) {
        // Portfolio memory p = portfolios[pid];
        minStakeAmount = cfg.getUSDMinStake();
        usdValue = _ramaOfUsd(ramaWei);
    }

    function RegisterAndActivate(
        address referrer
    ) external payable returns (uint256 pid) {
        // require user to not be registered yet
        require(!users.isRegistered(msg.sender), OceanErrors.AlreadyRegistered);
        uint256 ramaWei = msg.value;
        // require(usdAmount > 0, OceanErrors.Insufficient);
        require(ramaWei > 0, "insufficient RAMA sent");

        // Convert sent RAMA → USD (micro-USD, 1e6)
        uint256 usdMicro = _ramaOfUsd(ramaWei);

        // Min stake check: cfg.getUSDMinStake() must be micro-USD (1e6)
        require(usdMicro >= cfg.getUSDMinStake(), "below min stake");

        // if not registered, register first
        if (!users.isRegistered(msg.sender)) {
            (bool okReg, ) = cfg.userRegistry().call(
                abi.encodeWithSignature(
                    "registerUser(address,address)",
                    referrer,
                    msg.sender
                )
            );
            require(okReg, "USER_REG_FAIL");
        }

        // Move native RAMA to SafeWallet

        address payable safe = payable(cfg.treasury());

        // <-- now this is a real wallet address
        (bool sent, ) = safe.call{value: ramaWei}(""); // sends native RAMA to wallet
        require(sent, "SAFE_DEPOSIT_FAIL");
        // determine tier

        uint8 tr = _tierUSD6(usdMicro);
        // uint8 tr = 1;

        Portfolio memory p = Portfolio({
            principal: uint128(ramaWei),
            principalUsd: uint128(usdMicro), // <--- NEW: store USD principal once
            credited: 0,
            createdAt: uint64(block.timestamp),
            lastAccrual: uint64(block.timestamp),
            frozenUntil: 0,
            booster: false, // recomputed later (per your booster knapsack) _recomputeBoosterFor(msg.sender)
            tier: tr,
            capPct: 200, // default; may turn 250 if booster-selected
            owner: msg.sender,
            activatedBy: msg.sender,
            isActivatedFromSafeWallet: false
        });

        portfolios.push(p);
        pid = portfolios.length - 1;
        _portfoliosOf[msg.sender].push(pid);

        // start 10-day window if this is the first stake
        if (booster[msg.sender].firstStakeAt == 0) {
            booster[msg.sender].firstStakeAt = block.timestamp;
        }

        emit PortfolioCreated(msg.sender, pid, ramaWei, tr);

        // // Direct 5% income
        (bool ok, ) = cfg.incomeDistributor().call(
            abi.encodeWithSignature(
                "recordDirectIncome(address,address,uint256,uint256,uint256)",
                msg.sender,
                users.getReferrer(msg.sender),
                p.principal,
                p.principalUsd,
                pid
            )
        );

        require(ok, "DIRECT_INCOME_FAIL");

        // // $50 new direct note hook (for slab gate)
        // // $50 micro-USD check
        address upline = users.getReferrer(msg.sender);
        if (usdMicro >= 50e6 && upline != address(0)) {
            (bool ok2, ) = cfg.slabManager().call(
                abi.encodeWithSignature(
                    "noteNew50Direct(address)",
                    users.getReferrer(msg.sender)
                )
            );
            require(ok2, "SLAB_NOTE_FAIL");
            emit NoteNew50Direct(
                users.getReferrer(msg.sender),
                msg.sender,
                usdMicro
            );
        }

        // ===========================>

        // // Bubble business for slab qual (positive delta)
        (bool ok3, ) = cfg.slabManager().call(
            abi.encodeWithSignature(
                "onBusinessDelta(address,int256)",
                msg.sender,
                uint256(usdMicro)
            )
        );
        require(ok3, "SLAB_BUS_ADD_FAIL");

        // ==============================================>
        // // --- Booster recompute ---
        // // 1) recompute for self (new item may be included in knapsack)
        _recomputeBoosterFor(msg.sender);

        // 2) recompute for referrer (this user is their direct; may improve their capacity T)
        // address upline = users.getReferrer(msg.sender);
        if (upline != address(0)) {
            _recomputeBoosterFor(upline);
        }
    }

    // --- external ---
    function createPortfolio()
        external
        payable
        onlyRegistered
        returns (uint256 pid)
    {
        // require user to be registered
        require(users.isRegistered(msg.sender), OceanErrors.NotRegistered);
        uint256 ramaWei = msg.value;
        // require(usdAmount > 0, OceanErrors.Insufficient);
        require(ramaWei > 0, "insufficient RAMA sent");

        // Convert sent RAMA → USD (micro-USD, 1e6)
        uint256 usdMicro = _ramaOfUsd(ramaWei);

        // Min stake check: cfg.getUSDMinStake() must be micro-USD (1e6)
        require(usdMicro >= cfg.getUSDMinStake(), "below min stake");

        // if not registered, register first

        // if (!users.isRegistered(msg.sender)) {
        //     (bool okReg, ) = cfg.userRegistry().call(
        //         abi.encodeWithSignature(
        //             "registerUser(address,address)",
        //             referrer,
        //             msg.sender
        //         )
        //     );
        //     require(okReg, "USER_REG_FAIL");
        // }

        // Move native RAMA to SafeWallet

        address payable safe = payable(cfg.treasury());

        // <-- now this is a real wallet address
        (bool sent, ) = safe.call{value: ramaWei}(""); // sends native RAMA to wallet
        require(sent, "SAFE_DEPOSIT_FAIL");
        // determine tier

        uint8 tr = _tierUSD6(usdMicro);
        // uint8 tr = 1;

        Portfolio memory p = Portfolio({
            principal: uint128(ramaWei),
            principalUsd: uint128(usdMicro), // <--- NEW: store USD principal once
            credited: 0,
            createdAt: uint64(block.timestamp),
            lastAccrual: uint64(block.timestamp),
            frozenUntil: 0,
            booster: false, // recomputed later (per your booster knapsack) _recomputeBoosterFor(msg.sender)
            tier: tr,
            capPct: 200, // default; may turn 250 if booster-selected
            owner: msg.sender,
            activatedBy: msg.sender,
            isActivatedFromSafeWallet: false
        });

        portfolios.push(p);
        pid = portfolios.length - 1;
        _portfoliosOf[msg.sender].push(pid);

        // start 10-day window if this is the first stake
        if (booster[msg.sender].firstStakeAt == 0) {
            booster[msg.sender].firstStakeAt = block.timestamp;
        }

        emit PortfolioCreated(msg.sender, pid, ramaWei, tr);

        // // Direct 5% income
        (bool ok, ) = cfg.incomeDistributor().call(
            abi.encodeWithSignature(
                "recordDirectIncome(address,address,uint256,uint256,uint256)",
                users.getReferrer(msg.sender),
                msg.sender,
                p.principal,
                p.principalUsd,
                pid
            )
        );


        require(ok, "DIRECT_INCOME_FAIL");

        // // $50 new direct note hook (for slab gate)
        // // $50 micro-USD check
        address upline = users.getReferrer(msg.sender);
        if (usdMicro >= 50e6 && upline != address(0)) {
            (bool ok2, ) = cfg.slabManager().call(
                abi.encodeWithSignature(
                    "noteNew50Direct(address)",
                    users.getReferrer(msg.sender)
                )
            );
            require(ok2, "SLAB_NOTE_FAIL");
            emit NoteNew50Direct(
                users.getReferrer(msg.sender),
                msg.sender,
                usdMicro
            );
        }

        // ===========================>

        // // Bubble business for slab qual (positive delta)
        (bool ok3, ) = cfg.slabManager().call(
            abi.encodeWithSignature(
                "onBusinessDelta(address,int256)",
                msg.sender,
                uint256(usdMicro)
            )
        );
        require(ok3, "SLAB_BUS_ADD_FAIL");

        // ==============================================>
        // // --- Booster recompute ---
        // // 1) recompute for self (new item may be included in knapsack)
        _recomputeBoosterFor(msg.sender);

        // 2) recompute for referrer (this user is their direct; may improve their capacity T)
        // address upline = users.getReferrer(msg.sender);
        if (upline != address(0)) {
            _recomputeBoosterFor(upline);
        }
    }

    function createPortfolioForOthers(
        address toBeActivatedUSer,
        address referrer
    ) external payable onlyRegistered returns (uint256 pid) {
        // require user to be registered
        require(users.isRegistered(msg.sender), OceanErrors.NotRegistered);
        // require(
        //     users.isRegistered(toBeActivatedUSer),
        //     OceanErrors.ToBeActivatedUserAlreadyRegistered
        // );
        uint256 ramaWei = msg.value;
        // require(usdAmount > 0, OceanErrors.Insufficient);
        require(ramaWei > 0, "insufficient RAMA sent");

        // Convert sent RAMA → USD (micro-USD, 1e6)
        uint256 usdMicro = _ramaOfUsd(ramaWei);

        // Min stake check: cfg.getUSDMinStake() must be micro-USD (1e6)
        require(usdMicro >= cfg.getUSDMinStake(), "below min stake");

        // if not registered, register first

        if (!users.isRegistered(toBeActivatedUSer)) {
            (bool okReg, ) = cfg.userRegistry().call(
                abi.encodeWithSignature(
                    "registerUser(address,address)",
                    referrer,
                    toBeActivatedUSer
                )
            );
            require(okReg, "USER_REG_FAIL");
        }

        // Move native RAMA to SafeWallet

        address payable safe = payable(cfg.treasury());

        // <-- now this is a real wallet address
        (bool sent, ) = safe.call{value: ramaWei}(""); // sends native RAMA to wallet
        require(sent, "SAFE_DEPOSIT_FAIL");
        // determine tier

        uint8 tr = _tierUSD6(usdMicro);
        // uint8 tr = 1;

        Portfolio memory p = Portfolio({
            principal: uint128(ramaWei),
            principalUsd: uint128(usdMicro), // <--- NEW: store USD principal once
            credited: 0,
            createdAt: uint64(block.timestamp),
            lastAccrual: uint64(block.timestamp),
            frozenUntil: 0,
            booster: false, // recomputed later (per your booster knapsack) _recomputeBoosterFor(msg.sender)
            tier: tr,
            capPct: 200, // default; may turn 250 if booster-selected
            owner: toBeActivatedUSer,
            activatedBy: msg.sender,
            isActivatedFromSafeWallet: false
        });

        portfolios.push(p);
        pid = portfolios.length - 1;
        _portfoliosOf[toBeActivatedUSer].push(pid);

        // start 10-day window if this is the first stake
        if (booster[toBeActivatedUSer].firstStakeAt == 0) {
            booster[toBeActivatedUSer].firstStakeAt = block.timestamp;
        }

        emit PortfolioCreated(toBeActivatedUSer, pid, ramaWei, tr);
        PortfoliosCreatedForOthers[msg.sender].push(pid);
        // // Direct 5% income
        (bool ok, ) = cfg.incomeDistributor().call(
            abi.encodeWithSignature(
                "recordDirectIncome(address,address,uint256,uint256,uint256)",
                toBeActivatedUSer,
                users.getReferrer(toBeActivatedUSer),
                p.principal,
                p.principalUsd,
                pid
            )
        );

        // ISafeWallet(cfg.safeWallet()).creditGeneral(
        //     users.getReferrer(msg.sender),
        //     ISafeWallet.TxKind.DirectIncome,
        //     usdAmount, // if computed from oracle; else 0
        //     ramaAmount, // RAMA wei commission
        //     bytes32(portfolioId) // memo: pid encoded in 32 bytes
        // );

        require(ok, "DIRECT_INCOME_FAIL");

        // // $50 new direct note hook (for slab gate)
        // // $50 micro-USD check
        address upline = users.getReferrer(toBeActivatedUSer);
        if (usdMicro >= 50e6 && upline != address(0)) {
            (bool ok2, ) = cfg.slabManager().call(
                abi.encodeWithSignature(
                    "noteNew50Direct(address)",
                    users.getReferrer(toBeActivatedUSer)
                )
            );
            require(ok2, "SLAB_NOTE_FAIL");
            emit NoteNew50Direct(
                users.getReferrer(toBeActivatedUSer),
                toBeActivatedUSer,
                usdMicro
            );
        }

        // ===========================>

        // // Bubble business for slab qual (positive delta)
        (bool ok3, ) = cfg.slabManager().call(
            abi.encodeWithSignature(
                "onBusinessDelta(address,int256)",
                toBeActivatedUSer,
                uint256(usdMicro)
            )
        );
        require(ok3, "SLAB_BUS_ADD_FAIL");

        // ==============================================>
        // // --- Booster recompute ---
        // // 1) recompute for self (new item may be included in knapsack)
        _recomputeBoosterFor(toBeActivatedUSer);

        // 2) recompute for referrer (this user is their direct; may improve their capacity T)
        // address upline = users.getReferrer(msg.sender);
        if (upline != address(0)) {
            _recomputeBoosterFor(upline);
        }
    }

    function accrue(uint256 pid) public override returns (uint256 creditedNow) {
        Portfolio storage p = portfolios[pid];
        require(p.owner == msg.sender, OceanErrors.NotAuthorized);

        require(
            p.frozenUntil == 0 || block.timestamp > p.frozenUntil,
            OceanErrors.Frozen
        );

        uint256 elapsed = block.timestamp - uint256(p.lastAccrual);
        if (elapsed == 0) return 0;
        uint256 rate = _rate(p.booster, p.tier);
        uint256 income = (uint256(p.principal) * rate * elapsed) /
            1e18 /
            1 days; // linear

        // cap check (200% or 250% of principal)
        uint256 cap = (uint256(p.principal) * p.capPct) / 100;
        uint256 maxLeft = cap > p.credited ? cap - p.credited : 0;
        if (income > maxLeft) income = maxLeft;
        require(income > 0, OceanErrors.CapReached);

        p.credited += uint128(income);
        p.lastAccrual = uint64(block.timestamp);
        emit Accrued(msg.sender, pid, income);

        // route growth to SafeWallet internal ledger
        (bool ok, ) = cfg.safeWallet().call(
            abi.encodeWithSignature(
                "creditGrowth(address,uint256)",
                msg.sender,
                income
            )
        );
        require(ok, "SAFE_CREDIT_FAIL");
        return income;
    }

    // function applyExit(uint256 pid) external override {
    //     Portfolio storage p = portfolios[pid];
    //     require(p.owner == msg.sender, OceanErrors.NotAuthorized);
    //     require(p.frozenUntil == 0, OceanErrors.Frozen);
    //     p.frozenUntil = uint64(block.timestamp + 72 hours);
    //     emit ExitApplied(msg.sender, pid, p.frozenUntil);

    //     (bool ok, ) = cfg.freezePolicy().call(
    //         abi.encodeWithSignature(
    //             "onFreeze(address,uint256)",
    //             msg.sender,
    //             pid
    //         )
    //     );
    //     require(ok, "FREEZE_NOTE_FAIL");
    // }

    function applyExit(uint256 pid) external {
        Portfolio storage p = portfolios[pid];

        require(p.owner == msg.sender, OceanErrors.NotAuthorized);
        require(p.frozenUntil == 0, OceanErrors.Frozen);

        p.frozenUntil = uint64(block.timestamp + 72 hours);
        emit ExitApplied(msg.sender, pid, p.frozenUntil);

        // record freeze interval start (day-based)
        _freezeByPid[pid].push(
            FreezeInterval({startDay: _todayId(), endDay: 0})
        );
        emit FreezeIntervalOpened(pid, _todayId());

        // notify FreezePolicy (unchanged)
        (bool ok, ) = cfg.freezePolicy().call(
            abi.encodeWithSignature(
                "onFreeze(address,uint256)",
                msg.sender,
                pid
            )
        );
        require(ok, "FREEZE_NOTE_FAIL");
    }

    function cancelExit(uint256 pid) external {
        Portfolio storage p = portfolios[pid];
        require(p.owner == msg.sender, OceanErrors.NotAuthorized);
        require(
            p.frozenUntil != 0 && block.timestamp < p.frozenUntil,
            "NO_ACTIVE_FREEZE"
        );

        p.frozenUntil = 0;
        p.lastAccrual = uint64(block.timestamp);
        emit ExitCancelled(msg.sender, pid);

        // close the last open interval
        FreezeInterval[] storage arr = _freezeByPid[pid];
        if (arr.length > 0 && arr[arr.length - 1].endDay == 0) {
            arr[arr.length - 1].endDay = _todayId(); // inclusive end at cancel day
            emit FreezeIntervalClosed(
                pid,
                arr[arr.length - 1].startDay,
                arr[arr.length - 1].endDay
            );
        }

        (bool ok, ) = cfg.freezePolicy().call(
            abi.encodeWithSignature(
                "onUnfreeze(address,uint256)",
                msg.sender,
                pid
            )
        );
        require(ok, "UNFREEZE_NOTE_FAIL");
    }

    function getPortfolio(
        uint256 pid
    ) external view override returns (Portfolio memory) {
        return portfolios[pid];
    }

    /// @notice True if `user` has at least one active (not frozen, not capped) portfolio whose principal USD value ≥ $50.
    function hasActiveMin50(
        address user
    ) external view override returns (bool) {
        uint256[] memory pids = _portfoliosOf[user];
        if (pids.length == 0) return false;

        // uint256 priceMicro = _readRamaPriceWad(); // micro-USD per RAMA
        uint256 priceMicro = _readRamaPriceMicroUSD(); // micro-USD per RAMA
        if (priceMicro == 0) return false;

        // uint256 priceWad = _readRamaPriceWad();
        // if (priceWad == 0) return false;

        for (uint256 i = 0; i < pids.length; i++) {
            Portfolio memory p = portfolios[pids[i]];
            if (p.owner != user) continue;
            if (p.frozenUntil != 0 && block.timestamp <= p.frozenUntil)
                continue;

            uint256 cap = (uint256(p.principal) * uint256(p.capPct)) / 100;
            if (uint256(p.credited) >= cap) continue;

            // uint256 principalUsd = (uint256(p.principal) * priceWad) / 1e18;
            // if (principalUsd >= 50e18) return true;

            // principalUsd in micro-USD = principal (wei) * priceMicro / 1e18
            uint256 principalUsdMicro = (uint256(p.principal) * priceMicro) /
                1e18;
            if (principalUsdMicro >= 50e6) return true; // $50.000000
        }
        return false;
    }

    // =========================
    // Booster core (private)
    // =========================

    /// @dev Recomputes per-portfolio booster selection for `u` using:
    ///      - T = min(best portfolio USD of top-5 directs within U's 10-day window)
    ///      - Select a subset of U's portfolios (0/1) with total USD <= T maximizing the sum.
    function _recomputeBoosterFor(address u) internal {
        uint256 firstAt = booster[u].firstStakeAt;
        if (firstAt == 0) return; // no window yet
        uint256 windowEnd = firstAt + 10 days;

        // If the window has not started or there are fewer than 5 qualifying directs, no booster.
        address[] memory directs = users.getDirects(u); // <-- requires IUserRegistry.getDirects
        if (directs.length < 5) {
            _applyBoosterSelection(u, 0, new uint256[](0));

            return;
        }

        // uint256 priceWad = _readRamaPriceWad();
        uint256 priceWad = _readRamaPriceMicroUSD();
        if (priceWad == 0) {
            _applyBoosterSelection(u, 0, new uint256[](0));
            return;
        }

        // 1) Build each direct's BEST portfolio USD within [firstAt, windowEnd]
        uint256[] memory bestUSD = new uint256[](directs.length);
        uint256 count = 0;
        for (uint256 i = 0; i < directs.length; i++) {
            address d = directs[i];
            uint256[] memory dpids = _portfoliosOf[d];
            uint256 best = 0;
            for (uint256 j = 0; j < dpids.length; j++) {
                Portfolio memory pD = portfolios[dpids[j]];
                if (pD.createdAt < firstAt || pD.createdAt > windowEnd)
                    continue;
                // consider principal at creation time
                uint256 usd = (uint256(pD.principal) * priceWad) / 1e18;
                if (usd > best) best = usd;
            }
            if (best > 0) {
                bestUSD[count++] = best;
            }
        }
        if (count < 5) {
            _applyBoosterSelection(u, 0, new uint256[](0));
            return;
        }

        // shrink to count
        assembly {
            mstore(bestUSD, count)
        }

        // sort desc
        for (uint256 i = 1; i < bestUSD.length; i++) {
            uint256 key = bestUSD[i];
            uint256 j = i;
            while (j > 0 && bestUSD[j - 1] < key) {
                bestUSD[j] = bestUSD[j - 1];
                j--;
            }
            bestUSD[j] = key;
        }

        // T = min of top-5 (i.e., 5th value in desc array)
        uint256 T = bestUSD.length >= 5 ? bestUSD[4] : 0;
        if (T == 0) {
            _applyBoosterSelection(u, 0, new uint256[](0));
            return;
        }

        // 2) Build U's own portfolio items (USD) to run 0/1 knapsack
        uint256[] memory pids = _portfoliosOf[u];
        if (pids.length == 0) {
            _applyBoosterSelection(u, 0, new uint256[](0));
            return;
        }

        uint256 n = pids.length;
        uint256[] memory vals = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            Portfolio memory pU = portfolios[pids[i]];
            vals[i] = (uint256(pU.principal) * priceWad) / 1e18; // USD
        }

        // 3) Bitmask DP: find subset with max sum <= T
        uint256 bestSum = 0;
        uint256 bestMask = 0;
        uint256 maxMask = (1 << n);
        // Limit to n<=12 to keep gas reasonable; typical is far smaller.
        if (n <= 12) {
            for (uint256 mask = 0; mask < maxMask; mask++) {
                uint256 sum = 0;
                unchecked {
                    for (uint256 i = 0; i < n; i++) {
                        if ((mask >> i) & 1 == 1) {
                            sum += vals[i];
                            if (sum > T) {
                                sum = T + 1;
                                break;
                            }
                        }
                    }
                }
                if (sum <= T && sum > bestSum) {
                    bestSum = sum;
                    bestMask = mask;
                    if (bestSum == T) break; // early perfect fit
                }
            }
        } else {
            // fallback greedy (sort asc and take till capacity)
            // simple because large N is extremely unlikely in practice
            // produce same output types
            // copy & sort indexes asc by vals
            uint256[] memory idx = new uint256[](n);
            for (uint256 i = 0; i < n; i++) idx[i] = i;
            // insertion sort asc
            for (uint256 i = 1; i < n; i++) {
                uint256 keyI = idx[i];
                uint256 j = i;
                while (j > 0 && vals[idx[j - 1]] > vals[keyI]) {
                    idx[j] = idx[j - 1];
                    j--;
                }
                idx[j] = keyI;
            }
            uint256 mask = 0;
            uint256 sum = 0;
            for (uint256 k = 0; k < n; k++) {
                uint256 iix = idx[k];
                if (sum + vals[iix] <= T) {
                    sum += vals[iix];
                    mask |= (1 << iix);
                }
            }
            bestSum = sum;
            bestMask = mask;
        }

        // Build selected PID list for event/debug
        uint256 selCount = 0;
        for (uint256 i = 0; i < n; i++)
            if ((bestMask >> i) & 1 == 1) selCount++;
        uint256[] memory selected = new uint256[](selCount);
        uint256 w = 0;
        for (uint256 i = 0; i < n; i++) {
            bool pick = ((bestMask >> i) & 1) == 1;
            if (pick) selected[w++] = pids[i];
        }

        _applyBoosterSelection(u, T, selected);
        emit BoosterRecomputed(u, T, bestSum, selected);
    }

    /// @dev Applies booster flags and capPct for user `u` portfolios:
    ///      selected pids -> booster=true, capPct=250; others -> booster=false, capPct=200.
    function _applyBoosterSelection(
        address u,
        uint256 /*T*/,
        uint256[] memory selectedPids
    ) internal {
        // map selected pids for O(1) check
        // (n is small; a double loop is fine too; keeping a tiny mapping in memory)
        // We'll use a simple double loop for minimal code.
        uint256[] memory pids = _portfoliosOf[u];
        for (uint256 i = 0; i < pids.length; i++) {
            uint256 pid = pids[i];
            bool picked = false;
            for (uint256 j = 0; j < selectedPids.length; j++) {
                if (selectedPids[j] == pid) {
                    picked = true;
                    break;
                }
            }
            Portfolio storage p = portfolios[pid];
            if (picked) {
                p.booster = true;
                p.capPct = 250;
                emit BoosterActivated(
                    p.owner,
                    p.principal,
                    250,
                    block.timestamp
                );
            } else {
                p.booster = false;
                p.capPct = 200;
            }
        }
    }

    function getUSDPrincipal(
        uint256 pid
    ) external view override returns (uint256) {
        return uint256(portfolios[pid].principalUsd);
    }

    function portfoliosOf(
        address user
    ) external view override returns (uint256[] memory) {
        return _portfoliosOf[user];
    }

    function _tierUSD6(uint256 usdMicro) internal pure returns (uint8) {
        // 5010e6 micro-USD = $5,010.00
        return usdMicro >= 5010e6 ? 1 : 0;
    }

    function getFreezeIntervalsCount(
        uint256 pid
    ) external view returns (uint256) {
        return _freezeByPid[pid].length;
    }

    function getFreezeIntervalsSlice(
        uint256 pid,
        uint256 offset,
        uint256 limit
    ) external view returns (FreezeInterval[] memory out) {
        FreezeInterval[] storage arr = _freezeByPid[pid];
        uint256 n = arr.length;
        if (offset >= n) return new FreezeInterval[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;
        out = new FreezeInterval[](end - offset);
        for (uint256 i = offset; i < end; i++) out[i - offset] = arr[i];
    }

    /// @notice Create a new portfolio using user's SafeWallet funds (already moved to Treasury by SafeWallet).
    /// @dev Only SafeWallet can call. `ramaAmount` is RAMA wei already debited from SafeWallet.
    /// @param user      The beneficiary/owner of the new portfolio.
    /// @param ramaAmount Amount of RAMA (wei) used for staking.
    /// @param referrer  Referrer to record if `user` is not yet registered.
    /// @return pid The newly created portfolio id.
    function createPortfolioFromSafe(
        address user,
        uint256 ramaAmount,
        address referrer
    ) external returns (uint256 pid) {
        require(msg.sender == cfg.safeWallet(), "NOT_SAFEWALLET");
        require(user != address(0), OceanErrors.ZeroAddress);
        require(ramaAmount > 0, OceanErrors.Insufficient);

        // Ensure registered (register user with provided referrer if needed)
        if (!users.isRegistered(user)) {
            (bool okReg, ) = cfg.userRegistry().call(
                abi.encodeWithSignature(
                    "registerUser(address,address)",
                    referrer,
                    user
                )
            );
            require(okReg, "USER_REG_FAIL");
        }

        // Convert RAMA→USD (micro-USD, 1e6)
        uint256 usdMicro = _ramaOfUsd(ramaAmount);
        require(usdMicro >= cfg.getUSDMinStake(), "below min stake");

        // Create portfolio
        Portfolio memory p = Portfolio({
            principal: uint128(ramaAmount),
            principalUsd: uint128(usdMicro),
            credited: 0,
            createdAt: uint64(block.timestamp),
            lastAccrual: uint64(block.timestamp),
            frozenUntil: 0,
            booster: false,
            tier: _tierUSD6(usdMicro), // 0 or 1
            capPct: 200, // default; booster may lift to 250 after recompute
            owner: user,
            activatedBy: user,
            isActivatedFromSafeWallet: true
        });

        portfolios.push(p);
        pid = portfolios.length - 1;
        _portfoliosOf[user].push(pid);

        // Start booster window if first-ever portfolio for this user
        if (booster[user].firstStakeAt == 0) {
            booster[user].firstStakeAt = block.timestamp;
        }

        emit PortfolioCreated(user, pid, ramaAmount, p.tier);

        // --- TRACK SAFE SELF ---
        safeCreateByPid[pid] = SafeCreateInfo({
            pid: pid,
            ramaAmount: ramaAmount,
            usdMicro: usdMicro,
            caller: user, // self == beneficiary
            beneficiary: user,
            createdAt: uint64(block.timestamp)
        });
        _safeSelfPids[user].push(pid);
        _safeReceivedPids[user].push(pid);

        emit PortfolioCreatedFromSafe(user, pid, ramaAmount, usdMicro);

        // Direct income (5%) record to IncomeDistributor (uses USD+RAMA+pid)
        (bool ok, ) = cfg.incomeDistributor().call(
            abi.encodeWithSignature(
                "recordDirectIncome(address,address,uint256,uint256,uint256)",
                user,
                users.getReferrer(user),
                p.principal,
                p.principalUsd,
                pid
            )
        );
        require(ok, "DIRECT_INCOME_FAIL");

        // $50 new-direct note (for Slab gates)
        address upline = users.getReferrer(user);
        if (usdMicro >= 50e6 && upline != address(0)) {
            (bool ok2, ) = cfg.slabManager().call(
                abi.encodeWithSignature("noteNew50Direct(address)", upline)
            );
            require(ok2, "SLAB_NOTE_FAIL");
            emit NoteNew50Direct(upline, user, usdMicro);
        }

        // Bubble business up the tree (positive delta, micro-USD)
        (bool ok3, ) = cfg.slabManager().call(
            abi.encodeWithSignature(
                "onBusinessDelta(address,int256)",
                user,
                int256(uint256(usdMicro))
            )
        );
        require(ok3, "SLAB_BUS_ADD_FAIL");

        // Booster recompute for user + upline
        _recomputeBoosterFor(user);
        if (upline != address(0)) {
            _recomputeBoosterFor(upline);
        }
    }

    /// @notice Create a portfolio for `beneficiary` using `caller`'s SafeWallet funds.
    /// @dev Only SafeWallet can call. Funds have already been transferred to Treasury by SafeWallet.
    /// @param caller       The SafeWallet owner who paid (for audit trails off-chain).
    /// @param beneficiary  The new portfolio owner.
    /// @param ramaAmount   RAMA wei used for staking (already debited in SafeWallet).
    /// @param referrer     Referrer to record if `beneficiary` is not yet registered.
    /// @return pid New portfolio id.
    function createPortfolioForOthersFromSafe(
        address caller,
        address beneficiary,
        uint256 ramaAmount,
        address referrer
    ) external returns (uint256 pid) {
        require(msg.sender == cfg.safeWallet(), "NOT_SAFEWALLET");
        require(beneficiary != address(0), OceanErrors.ZeroAddress);
        require(ramaAmount > 0, OceanErrors.Insufficient);

        // Ensure beneficiary registered (with provided referrer)
        if (!users.isRegistered(beneficiary)) {
            (bool okReg, ) = cfg.userRegistry().call(
                abi.encodeWithSignature(
                    "registerUser(address,address)",
                    referrer,
                    beneficiary
                )
            );
            require(okReg, "USER_REG_FAIL");
        }

        // Convert RAMA→USD (micro-USD)
        uint256 usdMicro = _ramaOfUsd(ramaAmount);
        require(usdMicro >= cfg.getUSDMinStake(), "below min stake");

        // Record portfolio to beneficiary
        Portfolio memory p = Portfolio({
            principal: uint128(ramaAmount),
            principalUsd: uint128(usdMicro),
            credited: 0,
            createdAt: uint64(block.timestamp),
            lastAccrual: uint64(block.timestamp),
            frozenUntil: 0,
            booster: false,
            tier: _tierUSD6(usdMicro),
            capPct: 200,
            owner: beneficiary,
            activatedBy: caller,
            isActivatedFromSafeWallet: true
        });

        portfolios.push(p);
        pid = portfolios.length - 1;
        _portfoliosOf[beneficiary].push(pid);

        if (booster[beneficiary].firstStakeAt == 0) {
            booster[beneficiary].firstStakeAt = block.timestamp;
        }

        emit PortfolioCreated(beneficiary, pid, ramaAmount, p.tier);

        // --- TRACK SAFE OTHERS ---
        safeCreateByPid[pid] = SafeCreateInfo({
            pid: pid,
            ramaAmount: ramaAmount,
            usdMicro: usdMicro,
            caller: caller,
            beneficiary: beneficiary,
            createdAt: uint64(block.timestamp)
        });
        _safeCallerPids[caller].push(pid);
        _safeReceivedPids[beneficiary].push(pid);

        emit PortfolioCreatedForOthersFromSafe(
            caller,
            beneficiary,
            pid,
            ramaAmount,
            usdMicro
        );

        PortfoliosCreatedForOthers[caller].push(pid);

        // Direct income for beneficiary’s upline
        (bool ok, ) = cfg.incomeDistributor().call(
            abi.encodeWithSignature(
                "recordDirectIncome(address,address,uint256,uint256,uint256)",
                beneficiary,
                users.getReferrer(beneficiary),
                p.principal,
                p.principalUsd,
                pid
            )
        );
        require(ok, "DIRECT_INCOME_FAIL");

        // $50 new-direct note to SlabManager
        address upline = users.getReferrer(beneficiary);
        if (usdMicro >= 50e6 && upline != address(0)) {
            (bool ok2, ) = cfg.slabManager().call(
                abi.encodeWithSignature("noteNew50Direct(address)", upline)
            );
            require(ok2, "SLAB_NOTE_FAIL");
            emit NoteNew50Direct(upline, beneficiary, usdMicro);
        }

        // Bubble team business
        (bool ok3, ) = cfg.slabManager().call(
            abi.encodeWithSignature(
                "onBusinessDelta(address,int256)",
                beneficiary,
                int256(uint256(usdMicro))
            )
        );
        require(ok3, "SLAB_BUS_ADD_FAIL");

        // Booster recompute for beneficiary + their upline
        _recomputeBoosterFor(beneficiary);
        if (upline != address(0)) {
            _recomputeBoosterFor(upline);
        }

        // `caller` is intentionally not used on-chain here; keep it in the event
        // or SafeWallet logs for off-chain audit tying funding source to the action.
    }

    // -------- Simple getters --------

    // Portfolios a user created for self via SafeWallet
    function getSafeSelfPids(
        address user
    ) external view returns (uint256[] memory) {
        return _safeSelfPids[user];
    }

    // Portfolios created by a caller for others via SafeWallet
    function getSafeCallerPids(
        address caller
    ) external view returns (uint256[] memory) {
        return _safeCallerPids[caller];
    }

    // Portfolios a beneficiary received via someone else’s SafeWallet
    function getSafeReceivedPids(
        address beneficiary
    ) external view returns (uint256[] memory) {
        return _safeReceivedPids[beneficiary];
    }

    // Creation metadata for a SafeWallet-funded portfolio
    function getSafeCreateInfo(
        uint256 pid
    ) external view returns (SafeCreateInfo memory) {
        return safeCreateByPid[pid];
    }

    // -------- Paginated variants (avoid huge arrays on-chain) --------

    function getSafeSelfPidsSlice(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory slice) {
        uint256[] storage arr = _safeSelfPids[user];
        uint256 n = arr.length;
        if (offset >= n) return new uint256[](0);

        uint256 end = offset + limit;
        if (end > n) end = n;
        slice = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) slice[i - offset] = arr[i];
    }

    function getSafeCallerPidsSlice(
        address caller,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory slice) {
        uint256[] storage arr = _safeCallerPids[caller];
        uint256 n = arr.length;
        if (offset >= n) return new uint256[](0);

        uint256 end = offset + limit;
        if (end > n) end = n;
        slice = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) slice[i - offset] = arr[i];
    }

    function getSafeReceivedPidsSlice(
        address beneficiary,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory slice) {
        uint256[] storage arr = _safeReceivedPids[beneficiary];
        uint256 n = arr.length;
        if (offset >= n) return new uint256[](0);

        uint256 end = offset + limit;
        if (end > n) end = n;
        slice = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) slice[i - offset] = arr[i];
    }

    // get total portfolio value of user in rama and usd

    function getTotalPortfolioValue(
        address user
    ) external view returns (uint256 totalRamaWei, uint256 totalUsdMicro) {
        uint256[] memory pids = _portfoliosOf[user];
        totalRamaWei = 0;
        totalUsdMicro = 0;
        for (uint256 i = 0; i < pids.length; i++) {
            Portfolio memory p = portfolios[pids[i]];
            if (p.owner == user) {
                totalRamaWei += uint256(p.principal);
                totalUsdMicro += uint256(p.principalUsd);
            }
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
