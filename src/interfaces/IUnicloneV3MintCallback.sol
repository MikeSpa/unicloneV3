// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

interface IUnicloneV3MintCallback {
    function unicloneV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}
