// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

interface IUnicloneV3SwapCallback {
    //gets call when contract calls unicloneV3Pool.swap()
    function unicloneV3SwapCallback(int256 amount0, int256 amount1) external;
}
