// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

interface IUnicloneV3SwapCallback {
    function unicloneV3SwapCallback(
        int256 amount0,
        int256 amount1,
        bytes calldata data
    ) external;
}
