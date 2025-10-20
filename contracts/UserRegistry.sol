// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IUserRegistry.sol";
import "./interfaces/ICoreConfig.sol";
import "./interfaces/IPortfolioManager.sol";
import "./libraries/OceanErrors.sol";

contract UserRegistry is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IUserRegistry
{
    mapping(address => UserInfo) private users;
    mapping(uint32 => address) public idToAddress;
    uint32 public lastId;
    address public root; // company root

    // NEW: store direct children for each user
    mapping(address => address[]) public directsOf;

    // address public cfg;

    ICoreConfig public cfg;
    IPortfolioManager public pm;

    event Registered(address indexed user, address indexed referrer, uint32 id);

    function initialize(address _root, address _cfg) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        require(_root != address(0), OceanErrors.ZeroAddress);
        root = _root;
        // cfg = _cfg;

        cfg = ICoreConfig(_cfg);
        pm = IPortfolioManager(cfg.portfolioManager());
        lastId = 0;
        // Bootstrap root as ID 1
        users[_root] = UserInfo({
            registered: true,
            id: 1,
            referrer: address(0),
            directsCount: 0,
            createdAt: uint64(block.timestamp)
        });
        idToAddress[1] = _root;
        lastId = 1;
        emit Registered(_root, address(0), 1);
    }

    // set contracts
    function setPortfolioManager(address _pm) external onlyOwner {
        require(_pm != address(0), OceanErrors.ZeroAddress);
        pm = IPortfolioManager(_pm);
    }

    function setCongig(address _cfg) external onlyOwner {
        require(_cfg != address(0), OceanErrors.ZeroAddress);
        cfg = ICoreConfig(_cfg);
    }

    // only callable by authorized contracts (e.g., PortfolioManager)
    modifier onlyAuthorized() {
        require(msg.sender == address(pm), OceanErrors.NotAuthorized);
        _;
    }

    function registerUser(
        address referrer,
        address toBeRegsiteredUser
    ) external onlyAuthorized returns (uint32) {
        require(toBeRegsiteredUser != address(0), OceanErrors.ZeroAddress);
        require(referrer != address(0), OceanErrors.InvalidReferrer);
        require(
            referrer != toBeRegsiteredUser,
            OceanErrors.SelfReferralNotAllowed
        );
        require(
            !users[toBeRegsiteredUser].registered,
            OceanErrors.AlreadyRegistered
        );
        require(users[referrer].registered, OceanErrors.InvalidReferrer);

        // EOA-only (optional, see caveat)
        uint32 sizeUser;
        uint32 sizeRef;
        assembly {
            sizeUser := extcodesize(toBeRegsiteredUser)
        }

        assembly {
            sizeRef := extcodesize(referrer)
        }
        require(
            sizeUser == 0 && sizeRef == 0,
            OceanErrors.ContractAddForbidden
        );

        require(referrer != address(0), OceanErrors.InvalidReferrer);

        require(users[referrer].registered, OceanErrors.InvalidReferrer);

        uint32 newId = ++lastId;
        users[toBeRegsiteredUser] = UserInfo({
            registered: true,
            id: newId,
            referrer: referrer,
            directsCount: 0,
            createdAt: uint64(block.timestamp)
        });
        idToAddress[newId] = toBeRegsiteredUser;

        // increment referrer directs + store child
        users[referrer].directsCount += 1;
        directsOf[referrer].push(toBeRegsiteredUser);

        emit Registered(toBeRegsiteredUser, referrer, newId);
        return newId;
    }

    // ======= Existing views =======
    function getUser(address user) external view returns (UserInfo memory) {
        return users[user];
    }
    function getId(address user) external view returns (uint32) {
        return users[user].id;
    }
    function getReferrer(address user) external view returns (address) {
        return users[user].referrer;
    }
    function isRegistered(address user) external view returns (bool) {
        return users[user].registered;
    }

    // ======= NEW: Team getters =======

    /// @notice Get all direct (level-1) team members for `user`.
    function getDirectTeam(
        address user
    ) external view returns (address[] memory) {
        return directsOf[user];
    }

    /// @notice Get all team members at a specific level (level >= 1) for `user`.
    /// @dev Uses a breadth-first expansion level by level. Beware: very large teams
    ///      can exceed view gas limits if called on-chain; intended for off-chain reads.
    function getLevelTeam(
        address user,
        uint8 level
    ) external view returns (address[] memory) {
        require(level >= 1, OceanErrors.MinLevelRequired);

        // Level 1 is just the direct team
        address[] memory current = directsOf[user];
        if (level == 1) return current;

        // Iteratively build up to the requested level
        for (uint8 l = 2; l <= level; l++) {
            // count next level size
            uint256 nextCount = 0;
            for (uint256 i = 0; i < current.length; i++) {
                nextCount += directsOf[current[i]].length;
            }

            // assemble next level array
            address[] memory nextLevel = new address[](nextCount);
            uint256 k = 0;
            for (uint256 i = 0; i < current.length; i++) {
                address[] storage ch = directsOf[current[i]];
                for (uint256 j = 0; j < ch.length; j++) {
                    nextLevel[k++] = ch[j];
                }
            }

            current = nextLevel;
        }
        return current;
    }

    /// @notice Get counts per level from 1..maxDepth (inclusive).
    /// @dev Useful when you only need sizes, not addresses, saving some gas.
    function getLevelTeamCounts(
        address user,
        uint8 maxDepth
    ) external view returns (uint256[] memory counts) {
        require(maxDepth >= 1, OceanErrors.MinDepthRequired);

        counts = new uint256[](maxDepth);

        // Level 1
        address[] memory current = directsOf[user];
        counts[0] = current.length;

        for (uint8 l = 2; l <= maxDepth; l++) {
            uint256 nextCount = 0;
            for (uint256 i = 0; i < current.length; i++) {
                nextCount += directsOf[current[i]].length;
            }
            counts[l - 1] = nextCount;

            // Build next frontier only if more levels remain
            if (l != maxDepth) {
                address[] memory nextLevel = new address[](nextCount);
                uint256 k = 0;
                for (uint256 i = 0; i < current.length; i++) {
                    address[] storage ch = directsOf[current[i]];
                    for (uint256 j = 0; j < ch.length; j++) {
                        nextLevel[k++] = ch[j];
                    }
                }
                current = nextLevel;
            }
        }
    }

    // ---------- LEG-WISE HELPERS ----------

    /// @notice Return all top-level legs (directs) of `user`.
    function getTopLegs(address user) external view returns (address[] memory) {
        return directsOf[user];
    }

    /// @notice True if `leg` is a direct leg (first-hop child) of `user`.
    function isDirectLeg(address user, address leg) public view returns (bool) {
        address[] storage ds = directsOf[user];
        for (uint256 i = 0; i < ds.length; i++) if (ds[i] == leg) return true;
        return false;
    }

    /// @notice Return the direct children of a given `leg` under `user` (i.e., leg's level-1).
    /// @dev Reverts if `leg` is not a direct child of `user` (to avoid misuse).
    function getLegDirects(
        address user,
        address leg
    ) external view returns (address[] memory) {
        require(isDirectLeg(user, leg), OceanErrors.DirectLegRequired);
        return directsOf[leg];
    }

    /// @notice Return all addresses at `level` under a given direct `leg`.
    /// @dev level=1 => directs of leg; level>=2 => deeper descendants.
    ///      Breadth-first per level. Intended primarily for off-chain reads.
    function getLegLevelTeam(
        address user,
        address leg,
        uint8 level
    ) external view returns (address[] memory) {
        require(level >= 1, OceanErrors.MinLevelRequired);
        require(isDirectLeg(user, leg), OceanErrors.DirectLegRequired);

        // Level 1 = directs of leg
        address[] memory current = directsOf[leg];
        if (level == 1) return current;

        for (uint8 l = 2; l <= level; l++) {
            uint256 nextCount = 0;
            for (uint256 i = 0; i < current.length; i++) {
                nextCount += directsOf[current[i]].length;
            }
            address[] memory nextLevel = new address[](nextCount);
            uint256 k = 0;
            for (uint256 i = 0; i < current.length; i++) {
                address[] storage ch = directsOf[current[i]];
                for (uint256 j = 0; j < ch.length; j++) nextLevel[k++] = ch[j];
            }
            current = nextLevel;
        }
        return current;
    }

    /// @notice Counts per level (1..maxDepth) for the subtree under a given `leg`.
    function getLegSubtreeCounts(
        address user,
        address leg,
        uint8 maxDepth
    ) external view returns (uint256[] memory counts) {
        require(maxDepth >= 1, OceanErrors.MinDepthRequired);

        require(isDirectLeg(user, leg), OceanErrors.DirectLegRequired);

        counts = new uint256[](maxDepth);
        address[] memory current = directsOf[leg];
        counts[0] = current.length;

        for (uint8 l = 2; l <= maxDepth; l++) {
            uint256 nextCount = 0;
            for (uint256 i = 0; i < current.length; i++)
                nextCount += directsOf[current[i]].length;
            counts[l - 1] = nextCount;

            if (l != maxDepth) {
                address[] memory nextLevel = new address[](nextCount);
                uint256 k = 0;
                for (uint256 i = 0; i < current.length; i++) {
                    address[] storage ch = directsOf[current[i]];
                    for (uint256 j = 0; j < ch.length; j++)
                        nextLevel[k++] = ch[j];
                }
                current = nextLevel;
            }
        }
    }

    /// @notice Flatten the subtree under `leg` up to `maxDepth` (BFS order).
    /// @dev For large trees, prefer the paginated variant to avoid view gas limits.
    function getLegSubtreeFlat(
        address user,
        address leg,
        uint8 maxDepth
    ) external view returns (address[] memory) {
        require(maxDepth >= 1, OceanErrors.MinDepthRequired);

        require(isDirectLeg(user, leg), OceanErrors.DirectLegRequired);

        // First pass: compute total size up to maxDepth
        uint256 total = 0;
        address[] memory current = directsOf[leg];
        total += current.length;

        for (uint8 l = 2; l <= maxDepth; l++) {
            uint256 nextCount = 0;
            for (uint256 i = 0; i < current.length; i++)
                nextCount += directsOf[current[i]].length;
            total += nextCount;

            if (l != maxDepth) {
                address[] memory nextLevel = new address[](nextCount);
                uint256 k = 0;
                for (uint256 i = 0; i < current.length; i++) {
                    address[] storage ch = directsOf[current[i]];
                    for (uint256 j = 0; j < ch.length; j++)
                        nextLevel[k++] = ch[j];
                }
                current = nextLevel;
            }
        }

        // Second pass: fill flat array
        address[] memory flat = new address[](total);
        uint256 idx = 0;
        // Level 1
        current = directsOf[leg];
        for (uint256 i = 0; i < current.length; i++) flat[idx++] = current[i];

        for (uint8 l = 2; l <= maxDepth; l++) {
            uint256 nextCount = 0;
            for (uint256 i = 0; i < current.length; i++)
                nextCount += directsOf[current[i]].length;

            address[] memory nextLevel = new address[](nextCount);
            uint256 k = 0;
            for (uint256 i = 0; i < current.length; i++) {
                address[] storage ch = directsOf[current[i]];
                for (uint256 j = 0; j < ch.length; j++) {
                    address child = ch[j];
                    flat[idx++] = child;
                    nextLevel[k++] = child;
                }
            }
            current = nextLevel;
        }

        return flat;
    }

    /// @notice Paginated BFS over the subtree under `leg`.
    /// @param cursor  start index in BFS order (0-based)
    /// @param limit   max items to return
    /// @return slice  addresses [cursor, cursor+limit) in BFS order
    /// @return next   next cursor (== total if end)
    function getLegSubtreeSlice(
        address user,
        address leg,
        uint256 cursor,
        uint256 limit,
        uint8 maxDepth
    ) external view returns (address[] memory slice, uint256 next) {
        require(limit > 0, OceanErrors.InvalidLimit);
        address[] memory flat = this.getLegSubtreeFlat(user, leg, maxDepth);
        uint256 n = flat.length;

        if (cursor >= n) return (new address[](n), n);

        uint256 end = cursor + limit;
        if (end > n) end = n;

        slice = new address[](end - cursor);
        for (uint256 i = cursor; i < end; i++) slice[i - cursor] = flat[i];
        next = end;
    }

    // get directs

    function getDirects(address user) external view returns (address[] memory) {
        return directsOf[user];
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
