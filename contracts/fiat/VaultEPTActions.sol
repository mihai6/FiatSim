// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICodex} from "../fiat/interfaces/ICodex.sol";
import {IVault} from "../fiat/interfaces/IVault.sol";
import {IMoneta} from "../fiat/interfaces/IMoneta.sol";
import {IFIAT} from "../fiat/interfaces/IFIAT.sol";
import {WAD, toInt256, wmul, wdiv, sub} from "../fiat/utils/Math.sol";

import {Vault20Actions} from "./Vault20Actions.sol";

interface IBalancerVault {
    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256);

    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (
            address[] memory tokens,
            uint256[] memory balances,
            uint256 lastChangeBlock
        );

    enum PoolSpecialization {
        GENERAL,
        MINIMAL_SWAP_INFO,
        TWO_TOKEN
    }

    function getPool(bytes32 poolId) external view returns (address, PoolSpecialization);
}

interface IConvergentCurvePool {
    function solveTradeInvariant(
        uint256 amountX,
        uint256 reserveX,
        uint256 reserveY,
        bool out
    ) external view returns (uint256);

    function percentFee() external view returns (uint256);

    function totalSupply() external view returns (uint256);
}

interface ITranche {
    function withdrawPrincipal(uint256 _amount, address _destination) external returns (uint256);
}

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// WARNING: These functions meant to be used as a a library for a PRBProxy. Some are unsafe if you call them directly.
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

/// @title VaultEPTActions
/// @notice A set of vault actions for modifying positions collateralized by Element Finance pTokens
contract VaultEPTActions is Vault20Actions {
    using SafeERC20 for IERC20;

    /// ======== Custom Errors ======== ///

    error VaultEPTActions__buyCollateralAndModifyDebt_zeroUnderlierAmount();
    error VaultEPTActions__sellCollateralAndModifyDebt_zeroPTokenAmount();
    error VaultEPTActions__redeemCollateralAndModifyDebt_zeroPTokenAmount();
    error VaultEPTActions__solveTradeInvariant_tokenMismatch();

    /// ======== Types ======== ///

    // Swap data
    struct SwapParams {
        // Address of the Balancer Vault
        address balancerVault;
        // Id of the Element Convergent Curve Pool containing the collateral token
        bytes32 poolId;
        // Underlier token address when adding collateral and `collateral` when removing
        address assetIn;
        // Collateral token address when adding collateral and `underlier` when removing
        address assetOut;
        // Min. amount of tokens we would accept to receive from the swap, whether it is collateral or underlier
        uint256 minOutput; // The
        // Timestamp at which swap must be confirmed by [seconds]
        uint256 deadline;
        // Amount of `assetIn` to approve for `balancerVault` for swapping `assetIn` for `assetOut`
        uint256 approve;
    }

    constructor(
        address codex_,
        address moneta_,
        address fiat_,
        address publican_
    ) Vault20Actions(codex_, moneta_, fiat_, publican_) {}

    /// ======== Position Management ======== ///

    /// @notice Buys pTokens from underliers before it modifies a Position's collateral
    /// and debt balances and mints/burns FIAT using the underlier token.
    /// The underlier is swapped to pTokens token used as collateral.
    /// @dev The user needs to previously approve the UserProxy for spending collateral tokens or FIAT tokens
    /// If `position` is not the UserProxy, the `position` owner needs grant a delegate to UserProxy via Codex
    /// @param vault Address of the Vault
    /// @param position Address of the position's owner
    /// @param collateralizer Address of who puts up or receives the collateral delta as underlier tokens
    /// @param creditor Address of who provides or receives the FIAT delta for the debt delta
    /// @param underlierAmount Amount of underlier to swap for pTokens to put up for collateral [underlierScale]
    /// @param deltaNormalDebt Amount of normalized debt (gross, before rate is applied) to generate (+) or
    /// settle (-) on this Position [wad]
    /// @param swapParams Parameters of the underlier to pToken swap
    function buyCollateralAndModifyDebt(
        address vault,
        address position,
        address collateralizer,
        address creditor,
        uint256 underlierAmount,
        int256 deltaNormalDebt,
        SwapParams calldata swapParams
    ) public {
        if (underlierAmount == 0) revert VaultEPTActions__buyCollateralAndModifyDebt_zeroUnderlierAmount();

        // buy pToken according to `swapParams` data and transfer tokens to be used as collateral into VaultEPT
        uint256 pTokenAmount = _buyPToken(underlierAmount, collateralizer, swapParams);
        int256 deltaCollateral = toInt256(wdiv(pTokenAmount, IVault(vault).tokenScale()));

        // enter pToken and collateralize position
        modifyCollateralAndDebt(
            vault,
            swapParams.assetOut,
            0,
            position,
            address(this),
            creditor,
            deltaCollateral,
            deltaNormalDebt
        );
    }

    /// @notice Sells pTokens for underliers after it modifies a Position's collateral and debt balances
    /// and mints/burns FIAT using the underlier token. This method allows for selling pTokens even after maturity.
    /// @dev The user needs to previously approve the UserProxy for spending collateral tokens or FIAT tokens
    /// If `position` is not the UserProxy, the `position` owner needs grant a delegate to UserProxy via Codex
    /// @param vault Address of the Vault
    /// @param position Address of the position's owner
    /// @param collateralizer Address of who puts up or receives the collateral delta as underlier tokens
    /// @param creditor Address of who provides or receives the FIAT delta for the debt delta
    /// @param pTokenAmount Amount of pToken to remove as collateral and to swap for underlier [tokenScale]
    /// @param deltaNormalDebt Amount of normalized debt (gross, before rate is applied) to generate (+) or
    /// settle (-) on this Position [wad]
    /// @param swapParams Parameters of the underlier to pToken swap
    function sellCollateralAndModifyDebt(
        address vault,
        address position,
        address collateralizer,
        address creditor,
        uint256 pTokenAmount,
        int256 deltaNormalDebt,
        SwapParams calldata swapParams
    ) public {
        if (pTokenAmount == 0) revert VaultEPTActions__sellCollateralAndModifyDebt_zeroPTokenAmount();

        int256 deltaCollateral = -toInt256(wdiv(pTokenAmount, IVault(vault).tokenScale()));

        // withdraw pToken from the position
        modifyCollateralAndDebt(
            vault,
            swapParams.assetIn,
            0,
            position,
            address(this),
            creditor,
            deltaCollateral,
            deltaNormalDebt
        );

        // sell pToken according to `swapParams`
        _sellPToken(pTokenAmount, collateralizer, swapParams);
    }

    /// @notice Redeems pTokens for underliers after it modifies a Position's collateral
    /// and debt balances and mints/burns FIAT using the underlier token. Fails if pToken hasn't matured yet.
    /// @dev The user needs to previously approve the UserProxy for spending collateral tokens or FIAT tokens
    /// If `position` is not the UserProxy, the `position` owner needs grant a delegate to UserProxy via Codex
    /// @param vault Address of the Vault
    /// @param token Address of the collateral token (pToken)
    /// @param position Address of the position's owner
    /// @param collateralizer Address of who puts up or receives the collateral delta as underlier tokens
    /// @param creditor Address of who provides or receives the FIAT delta for the debt delta
    /// @param pTokenAmount Amount of pToken to remove as collateral and to swap or redeem for underlier [tokenScale]
    /// @param deltaNormalDebt Amount of normalized debt (gross, before rate is applied) to generate (+) or
    /// settle (-) on this Position [wad]
    function redeemCollateralAndModifyDebt(
        address vault,
        address token,
        address position,
        address collateralizer,
        address creditor,
        uint256 pTokenAmount,
        int256 deltaNormalDebt
    ) public {
        if (pTokenAmount == 0) revert VaultEPTActions__redeemCollateralAndModifyDebt_zeroPTokenAmount();

        int256 deltaCollateral = -toInt256(wdiv(pTokenAmount, IVault(vault).tokenScale()));

        // withdraw pToken from the position
        modifyCollateralAndDebt(vault, token, 0, position, address(this), creditor, deltaCollateral, deltaNormalDebt);

        // redeem pToken for underlier
        ITranche(token).withdrawPrincipal(pTokenAmount, collateralizer);
    }

    function _buyPToken(
        uint256 underlierAmount,
        address from,
        SwapParams calldata swapParams
    ) internal returns (uint256) {
        // if `from` is set to an external address then transfer amount to the proxy first
        // requires `from` to have set an allowance for the proxy
        if (from != address(0) && from != address(this)) {
            IERC20(swapParams.assetIn).safeTransferFrom(from, address(this), underlierAmount);
        }

        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap(
            swapParams.poolId,
            IBalancerVault.SwapKind.GIVEN_IN,
            swapParams.assetIn,
            swapParams.assetOut,
            underlierAmount, // note precision
            new bytes(0)
        );
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement(
            address(this),
            false,
            payable(address(this)),
            false
        );

        if (swapParams.approve != 0) {
            // approve balancer vault to transfer underlier tokens on behalf of proxy
            IERC20(swapParams.assetIn).approve(swapParams.balancerVault, swapParams.approve);
        }

        // kind == `GIVE_IN` use `minOutput` as `limit` to enforce min. amount of pTokens to receive
        return
            IBalancerVault(swapParams.balancerVault).swap(singleSwap, funds, swapParams.minOutput, swapParams.deadline);
    }

    function _sellPToken(
        uint256 pTokenAmount,
        address to,
        SwapParams calldata swapParams
    ) internal returns (uint256) {
        // approve Balancer to transfer PToken
        IERC20(swapParams.assetIn).approve(swapParams.balancerVault, pTokenAmount);

        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap(
            swapParams.poolId,
            IBalancerVault.SwapKind.GIVEN_IN,
            swapParams.assetIn,
            swapParams.assetOut,
            pTokenAmount,
            new bytes(0)
        );
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement(
            address(this),
            false,
            payable(to),
            false
        );

        if (swapParams.approve != 0) {
            // approve balancer vault to transfer pTokens on behalf of proxy
            IERC20(swapParams.assetIn).approve(swapParams.balancerVault, swapParams.approve);
        }

        // kind == `GIVE_IN` use `minOutput` as `limit` to enforce min. amount of underliers to receive
        return
            IBalancerVault(swapParams.balancerVault).swap(singleSwap, funds, swapParams.minOutput, swapParams.deadline);
    }

    /// ======== View Methods ======== ///

    /// @notice Returns an amount of pToken for a given an amount of the pTokens underlier token (e.g. USDC)
    /// @param vault Address of the Vault (FIAT)
    /// @param balancerVault Address of the Balancer V2 vault
    /// @param curvePoolId Id of the ConvergentCurvePool
    /// @param underlierAmount Amount of underlier [underlierScale]
    /// @return Amount of pToken [tokenScale]
    function underlierToPToken(
        address vault,
        address balancerVault,
        bytes32 curvePoolId,
        uint256 underlierAmount
    ) external view returns (uint256) {
        return _solveTradeInvariant(underlierAmount, vault, balancerVault, curvePoolId, true);
    }

    /// @notice Returns an amount of the pTokens underlier token for a given an amount of pToken (e.g. USDC pToken)
    /// @param vault Address of the Vault (FIAT)
    /// @param balancerVault Address of the Balancer V2 vault
    /// @param curvePoolId Id of the ConvergentCurvePool
    /// @param pTokenAmount Amount of token [tokenScale]
    /// @return Amount of underlier [underlierScale]
    function pTokenToUnderlier(
        address vault,
        address balancerVault,
        bytes32 curvePoolId,
        uint256 pTokenAmount
    ) external view returns (uint256) {
        return _solveTradeInvariant(pTokenAmount, vault, balancerVault, curvePoolId, false);
    }

    /// @dev Adapted from https://github.com/element-fi/elf-contracts/blob/main/contracts/ConvergentCurvePool.sol#L150
    function _solveTradeInvariant(
        uint256 amountIn_,
        address vault,
        address balancerVault,
        bytes32 poolId,
        bool fromUnderlier
    ) internal view returns (uint256) {
        uint256 tokenScale = IVault(vault).tokenScale();
        uint256 underlierScale = IVault(vault).underlierScale();

        // convert from either underlierScale or tokenScale to scale used by elf (== wad)
        uint256 amountIn = (fromUnderlier) ? wdiv(amountIn_, underlierScale) : wdiv(amountIn_, tokenScale);

        uint256 currentBalanceTokenIn;
        uint256 currentBalanceTokenOut;
        {
            (address[] memory tokens, uint256[] memory balances, ) = IBalancerVault(balancerVault).getPoolTokens(
                poolId
            );
            address token = IVault(vault).token();
            address underlier = IVault(vault).underlierToken();

            if (tokens[0] == underlier && tokens[1] == token) {
                currentBalanceTokenIn = (fromUnderlier)
                    ? wdiv(balances[0], underlierScale)
                    : wdiv(balances[1], tokenScale);
                currentBalanceTokenOut = (fromUnderlier)
                    ? wdiv(balances[1], tokenScale)
                    : wdiv(balances[0], underlierScale);
            } else if (tokens[0] == token && tokens[1] == underlier) {
                currentBalanceTokenIn = (fromUnderlier)
                    ? wdiv(balances[1], underlierScale)
                    : wdiv(balances[0], tokenScale);
                currentBalanceTokenOut = (fromUnderlier)
                    ? wdiv(balances[0], tokenScale)
                    : wdiv(balances[1], underlierScale);
            } else {
                revert VaultEPTActions__solveTradeInvariant_tokenMismatch();
            }
        }

        (address pool, ) = IBalancerVault(balancerVault).getPool(poolId);
        IConvergentCurvePool ccp = IConvergentCurvePool(pool);

        // https://github.com/element-fi/elf-contracts/blob/main/contracts/ConvergentCurvePool.sol#L680
        if (fromUnderlier) {
            unchecked {
                currentBalanceTokenOut += ccp.totalSupply();
            }
        } else {
            unchecked {
                currentBalanceTokenIn += ccp.totalSupply();
            }
        }

        uint256 amountOut = ccp.solveTradeInvariant(amountIn, currentBalanceTokenIn, currentBalanceTokenOut, true);
        uint256 impliedYieldFee = wmul(
            ccp.percentFee(),
            fromUnderlier
                ? sub(amountOut, amountIn) // If the output is token the implied yield is out - in
                : sub(amountIn, amountOut) // If the output is underlier the implied yield is in - out
        );

        // convert from wad to either tokenScale or underlierScale
        return wmul(sub(amountOut, impliedYieldFee), (fromUnderlier) ? tokenScale : underlierScale);
    }
}
