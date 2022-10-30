// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

library Tick {
    struct Info {
        bool initialized;
        uint128 liquidity;
    }

    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint128 liquidityDelta
    ) internal returns (bool flipped) {
        Tick.Info storage tickInfo = self[tick];
        uint128 liquidityBefore = tickInfo.liquidity;
        uint128 liquidityAfter = liquidityBefore + liquidityDelta;

        if (liquidityBefore == 0) {
            tickInfo.initialized = true;
        }

        tickInfo.liquidity = liquidityAfter;
        //true if liquidity is added to an empty tick or entire liquidity is removed from a tick
        flipped = (liquidityAfter == 0) != (liquidityBefore == 0);
    }
}
