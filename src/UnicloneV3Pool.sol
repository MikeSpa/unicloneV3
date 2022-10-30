// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/IERC20.sol";
import "./interfaces/IUnicloneV3MintCallback.sol";
import "./interfaces/IUnicloneV3SwapCallback.sol";

import "./lib/Position.sol";
import "./lib/Tick.sol";
import "./lib/TickBitmap.sol";
import "./lib/TickMath.sol";
import "./lib/Math.sol";
import "./lib/SwapMath.sol";

contract UnicloneV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    using TickBitmap for mapping(int16 => uint256);
    mapping(int16 => uint256) public tickBitmap;

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    // Pool tokens
    address public immutable token0;
    address public immutable token1;

    // Packing variables that are read together
    struct Slot0 {
        // Current sqrt(P)
        uint160 sqrtPriceX96;
        // Current tick
        int24 tick;
    }
    Slot0 public slot0;

    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }

    struct SwapState {
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
    }

    struct StepState {
        uint160 sqrtPriceStartX96;
        int24 nextTick;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
    }

    // Amount of liquidity, L.
    uint128 public liquidity;

    // Ticks info: # -> (bool initialized, uint128 L)
    mapping(int24 => Tick.Info) public ticks;
    // Positions info: hash(owner, lowerTick, upperTick)-> L
    mapping(bytes32 => Position.Info) public positions;

    error InsufficientInputAmount();
    error InvalidTickRange();
    error ZeroLiquidity();

    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    //##########################  FUNCTIONs  ######################################

    constructor(
        address _token0,
        address _token1,
        uint160 _sqrtPriceX96,
        int24 _tick
    ) {
        token0 = _token0;
        token1 = _token1;

        slot0 = Slot0({sqrtPriceX96: _sqrtPriceX96, tick: _tick});
    }

    // provide liquidity
    function mint(
        address _owner,
        int24 _lowerTick, //bounds of price range
        int24 _upperTick,
        uint128 _amount, //L
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1) {
        if (
            _lowerTick >= _upperTick ||
            _lowerTick < MIN_TICK ||
            _upperTick > MAX_TICK
        ) revert InvalidTickRange();

        if (_amount == 0) revert ZeroLiquidity();

        // Update ticks and positions mappings

        Position.Info storage position = positions.get(
            _owner,
            _lowerTick,
            _upperTick
        );
        position.update(_amount);

        bool flippedLower = ticks.update(_lowerTick, _amount);
        bool flippedUpper = ticks.update(_upperTick, _amount);

        if (flippedLower) {
            tickBitmap.flipTick(_lowerTick, 1);
        }

        if (flippedUpper) {
            tickBitmap.flipTick(_upperTick, 1);
        }

        Slot0 memory slot0_ = slot0;

        // Calculate the amounts the user has to deposit
        amount0 = Math.calcAmount0Delta(
            slot0_.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_upperTick),
            _amount
        );

        amount1 = Math.calcAmount1Delta(
            slot0_.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lowerTick),
            _amount
        );
        //hardcoded for now
        // amount0 = 0.998976618347425280 ether;
        // amount1 = 5000 ether;

        // Update liquidity
        liquidity += uint128(_amount);

        // Check token transfer
        //current token balance
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        //caller msg.sender callback function where the token will be transfer to us
        IUnicloneV3MintCallback(msg.sender).unicloneV3MintCallback(
            amount0,
            amount1,
            data
        );
        // check that the balance has increase by at least amount0 and amount1
        if (amount0 > 0 && balance0Before + amount0 > balance0())
            revert InsufficientInputAmount();
        if (amount1 > 0 && balance1Before + amount1 > balance1())
            revert InsufficientInputAmount();

        // Emit event
        emit Mint(
            msg.sender,
            _owner,
            _lowerTick,
            _upperTick,
            _amount,
            amount0,
            amount1
        );
    }

    // _recipient: the address that should recieve the token
    function swap(
        address recipient,
        bool zeroForOne,
        uint256 amountSpecified,
        bytes calldata data
    ) public returns (int256 amount0, int256 amount1) {
        Slot0 memory slot0_ = slot0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick
        });

        while (state.amountSpecifiedRemaining > 0) {
            StepState memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                1,
                zeroForOne
            );

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);

            (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath
                .computeSwapStep(
                    step.sqrtPriceStartX96,
                    step.sqrtPriceNextX96,
                    liquidity,
                    state.amountSpecifiedRemaining
                );

            state.amountSpecifiedRemaining -= step.amountIn;
            state.amountCalculated += step.amountOut;
            state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
        }

        if (state.tick != slot0_.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        }

        (amount0, amount1) = zeroForOne
            ? (
                int256(amountSpecified - state.amountSpecifiedRemaining),
                -int256(state.amountCalculated)
            )
            : (
                -int256(state.amountCalculated),
                int256(amountSpecified - state.amountSpecifiedRemaining)
            );

        if (zeroForOne) {
            IERC20(token1).transfer(recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUnicloneV3SwapCallback(msg.sender).unicloneV3SwapCallback(
                amount0,
                amount1,
                data
            );
            if (balance0Before + uint256(amount0) > balance0())
                revert InsufficientInputAmount();
        } else {
            IERC20(token0).transfer(recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUnicloneV3SwapCallback(msg.sender).unicloneV3SwapCallback(
                amount0,
                amount1,
                data
            );
            if (balance1Before + uint256(amount1) > balance1())
                revert InsufficientInputAmount();
        }

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            slot0.sqrtPriceX96,
            liquidity,
            slot0.tick
        );
    }

    // ############################### PRIVATE AND INTERNAL ############################

    //return the balance of token0 on the contract
    function balance0() internal returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    //return the balance of token1 on the contract
    function balance1() internal returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }
}
