// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "../src/UnicloneV3Pool.sol";
import "../src/interfaces/IERC20.sol";

contract UnicloneV3Manager {
    function mint(
        address poolAddress_,
        int24 lowerTick,
        int24 upperTick,
        uint128 liquidity,
        bytes calldata data
    ) public {
        UnicloneV3Pool(poolAddress_).mint(
            msg.sender,
            lowerTick,
            upperTick,
            liquidity,
            data
        );
    }

    function swap(address poolAddress_, bytes calldata data) public {
        UnicloneV3Pool(poolAddress_).swap(msg.sender, data);
    }

    function unicloneV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) public {
        UnicloneV3Pool.CallbackData memory extra = abi.decode(
            data,
            (UnicloneV3Pool.CallbackData)
        );

        IERC20(extra.token0).transferFrom(extra.payer, msg.sender, amount0);
        IERC20(extra.token1).transferFrom(extra.payer, msg.sender, amount1);
    }

    function unicloneV3SwapCallback(
        int256 amount0,
        int256 amount1,
        bytes calldata data
    ) public {
        UnicloneV3Pool.CallbackData memory extra = abi.decode(
            data,
            (UnicloneV3Pool.CallbackData)
        );
        if (amount0 > 0) {
            IERC20(extra.token0).transferFrom(
                extra.payer,
                msg.sender,
                uint256(amount0)
            );
        }

        if (amount1 > 0) {
            IERC20(extra.token1).transferFrom(
                extra.payer,
                msg.sender,
                uint256(amount1)
            );
        }
    }
}