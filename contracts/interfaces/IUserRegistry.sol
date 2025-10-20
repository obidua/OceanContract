// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

interface IUserRegistry {
    struct UserInfo {
        bool registered;
        uint32 id;
        address referrer;
        uint32 directsCount;
        uint64 createdAt;
    }

    function getUser(address user) external view returns (UserInfo memory);
    function getId(address user) external view returns (uint32);
    function getReferrer(address user) external view returns (address);
    function registerUser(
        address referrer,
        address toBeRegisterdUser
    ) external returns (uint32);
    function isRegistered(address user) external view returns (bool);
    function getDirects(address user) external view returns (address[] memory);
    // function directsOf(address who) external view returns (address[] memory);
}
