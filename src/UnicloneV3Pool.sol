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
    // SwapState maintains current swap’s state.
    struct SwapState {
        uint256 amountSpecifiedRemaining; // tracks the remaining amount of tokens that needs to be bought by the pool.
        uint256 amountCalculated; // the out amount calculated by the contract.
        uint160 sqrtPriceX96; // new current price after swap is done
        int24 tick; // new current tick after swap is done
    }
    //StepState maintains current swap step’s state. This structure tracks the state of one iteration of an “order filling”.
    struct StepState {
        uint160 sqrtPriceStartX96; // the price the iteration begins with
        int24 nextTick; // the next initialized tick that will provide liquidity for the swap
        uint160 sqrtPriceNextX96; // the price at the next tick.
        uint256 amountIn; // amounts that can be provided by the liquidity of the current iteration.
        uint256 amountOut; // amounts that can be provided by the liquidity of the current iteration.
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

    /// @param _recipient: the address that should recieve the token
    /// @param _zeroForOne the flag that controls swap direction: when true, token0 is traded in for token1; when false, it’s the opposite.
    /// @param _amountSpecified the amount of tokens user wants to sell.
    function swap(
        address _recipient,
        bool _zeroForOne,
        uint256 _amountSpecified,
        bytes calldata _data
    ) public returns (int256 amount0, int256 amount1) {
        Slot0 memory slot0_ = slot0;

        //Before filling an order, we initialize a SwapState instance.
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: _amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick
        });

        // We’ll loop until amountSpecifiedRemaining is 0, which will mean that the pool has enough liquidity to buy amountSpecified tokens from user.
        while (state.amountSpecifiedRemaining > 0) {
            // we set up a price range that should provide liquidity for the swap. The range is from state.sqrtPriceX96 to step.sqrtPriceNextX96

            StepState memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                1,
                _zeroForOne
            );

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);
            // calculating the amounts that can be provider by the current price range, and the new current price the swap will result in.

            (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath
                .computeSwapStep(
                    step.sqrtPriceStartX96,
                    step.sqrtPriceNextX96,
                    liquidity,
                    state.amountSpecifiedRemaining
                );
            //update SwapState
            state.amountSpecifiedRemaining -= step.amountIn; // - amount of tokens the price range can buy from user
            state.amountCalculated += step.amountOut; // + the related number of the other token the pool can sell to user
            state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
        }

        // set new price and tick
        if (state.tick != slot0_.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        }

        // calculate swap amounts based on swap direction and the amounts calculated during the swap loop
        (amount0, amount1) = _zeroForOne
            ? (
                int256(_amountSpecified - state.amountSpecifiedRemaining),
                -int256(state.amountCalculated)
            )
            : (
                -int256(state.amountCalculated),
                int256(_amountSpecified - state.amountSpecifiedRemaining)
            );

        // exchanging tokens with user, depending on swap direction
        if (_zeroForOne) {
            IERC20(token1).transfer(_recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUnicloneV3SwapCallback(msg.sender).unicloneV3SwapCallback(
                amount0,
                amount1,
                _data
            );
            if (balance0Before + uint256(amount0) > balance0())
                revert InsufficientInputAmount();
        } else {
            IERC20(token0).transfer(_recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUnicloneV3SwapCallback(msg.sender).unicloneV3SwapCallback(
                amount0,
                amount1,
                _data
            );
            if (balance1Before + uint256(amount1) > balance1())
                revert InsufficientInputAmount();
        }

        emit Swap(
            msg.sender,
            _recipient,
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
