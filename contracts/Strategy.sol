// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/math/Math.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/curve/IStableSwapExchange.sol";
import "../interfaces/yearn/IVault.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // Investment vault to deposit converted stablecoin
    IVault public yVault;

    // Maximum loss on withdrawal from yVault
    uint256 public maxLoss;

    // IStableSwapExchange curvePool
    IStableSwapExchange public curvePool;

    // Curve pool indexes
    int128 internal curvePoolWantIndex;
    int128 internal curvePoolInvestmentIndex;

    // Min expected output when swapping via the Curve pool
    // This should be relative to MAX_BPS representing 100%
    uint256 public minExpectedSwapPercentage;

    // 100%
    uint256 internal constant MAX_BPS = 10000;

    // Name of the strategy
    string internal strategyName;

    constructor(
        address _vault,
        address _yVault,
        string memory _strategyName,
        address _curvePool,
        int128 _curvePoolWantIndex,
        int128 _curvePoolInvestmentIndex
    ) public BaseStrategy(_vault) {
        yVault = IVault(_yVault);
        curvePool = IStableSwapExchange(_curvePool);

        // TODO: require from / to to be valid vault and yVault tokens
        curvePoolWantIndex = _curvePoolWantIndex;
        curvePoolInvestmentIndex = _curvePoolInvestmentIndex;
    }

    // ----------------- SETTERS & EXTERNAL CONFIGURATION -----------------

    // Ideally we would receive fair market value by performing every swap
    // through Flashbots. However, since we will be swapping capital and not
    // only profits, it is important to do our best to avoid bad swaps or
    // sandwiches in case we end up in an uncle block.
    function setMinExpectedSwapPercentage(uint256 _minExpectedSwapPercentage)
        external
        onlyEmergencyAuthorized
    {
        require(_minExpectedSwapPercentage <= MAX_BPS); // dev: invalid value for min out
        minExpectedSwapPercentage = _minExpectedSwapPercentage;
    }

    // Max slippage to accept when withdrawing from yVault
    function setMaxLoss(uint256 _maxLoss) external onlyVaultManagers {
        require(_maxLoss <= MAX_BPS); // dev: invalid value for max loss
        maxLoss = _maxLoss;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return strategyName;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // Here we are assuming 1 unit of want = 1 unit of investment
        // For usd-pegged stablecoins this Is Probably Right (TM)
        return want.balanceOf(address(this)).add(valueOfInvestment());
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // How much do we owe to the vault?
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        // Claim profit from investment in yVault
        _takeYVaultProfit();

        uint256 totalAssetsAfterProfit = estimatedTotalAssets();

        _profit = totalAssetsAfterProfit > totalDebt
            ? totalAssetsAfterProfit.sub(totalDebt)
            : 0;

        uint256 _amountFreed;
        (_amountFreed, _loss) = liquidatePosition(
            _debtOutstanding.add(_profit)
        );
        _debtPayment = Math.min(_amountFreed, _debtOutstanding);

        if (_loss > _profit) {
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            _profit = _profit.sub(_loss);
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // Deposit excess want balance to yVault
        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _debtOutstanding) {
            _convertAndDepositToYVault(wantBalance.sub(_debtOutstanding));
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBalance = balanceOfWant();

        // Check if we can handle it without withdrawing from yVault
        if (wantBalance >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        // Only need to free the amount of want not readily available
        uint256 amountToWithdraw = _amountNeeded.sub(wantBalance);

        _withdrawFromYVault(amountToWithdraw);
        _convertInvestmentTokenToWant();

        uint256 looseWant = balanceOfWant();
        if (_amountNeeded > looseWant) {
            _liquidatedAmount = looseWant;
            _loss = _amountNeeded.sub(looseWant);
        } else {
            _liquidatedAmount = _amountNeeded;
            _loss = 0;
        }
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidatePosition(estimatedTotalAssets());
    }

    function prepareMigration(address _newStrategy) internal override {
        // Move yVault balance to the new strategy
        IERC20(yVault).safeTransfer(
            _newStrategy,
            IERC20(yVault).balanceOf(address(this))
        );
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return 0;
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfInvestmentToken() public view returns (uint256) {
        return IERC20(yVault.token()).balanceOf(address(this));
    }

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, type(uint256).max);
        }
    }

    function valueOfInvestment() public view virtual returns (uint256) {
        return
            yVault.balanceOf(address(this)).mul(yVault.pricePerShare()).div(
                10**yVault.decimals()
            );
    }

    function _investmentTokenToYShares(uint256 amount)
        internal
        view
        returns (uint256)
    {
        return amount.mul(10**yVault.decimals()).div(yVault.pricePerShare());
    }

    function _withdrawFromYVault(uint256 _amountIT) internal {
        if (_amountIT == 0) {
            return;
        }

        // No need to check allowance because the contract == token
        uint256 sharesToWithdraw =
            Math.min(
                _investmentTokenToYShares(_amountIT),
                yVault.balanceOf(address(this))
            );

        if (sharesToWithdraw == 0) {
            return;
        }

        yVault.withdraw(sharesToWithdraw, address(this), maxLoss);
    }

    function _takeYVaultProfit() internal {
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 valueOfInvestment = valueOfInvestment();

        if (valueOfInvestment > totalDebt) {
            uint256 investmentToWithdraw = valueOfInvestment.sub(totalDebt);
            uint256 sharesToWithdraw =
                _investmentTokenToYShares(investmentToWithdraw);

            yVault.withdraw(sharesToWithdraw, address(this), maxLoss);
        }

        _convertInvestmentTokenToWant();
    }

    function _convertInvestmentTokenToWant() internal {
        uint256 balanceIT = balanceOfInvestmentToken();
        if (balanceIT > 0) {
            _convertFromAToB(
                curvePoolInvestmentIndex,
                curvePoolWantIndex,
                balanceIT
            );
        }
    }

    function _convertAndDepositToYVault(uint256 amount) internal {
        _convertFromAToB(curvePoolWantIndex, curvePoolInvestmentIndex, amount);

        uint256 balanceIT = balanceOfInvestmentToken();
        if (balanceIT > 0) {
            _checkAllowance(address(yVault), yVault.token(), balanceIT);
            yVault.deposit();
        }
    }

    function _convertFromAToB(
        int128 from,
        int128 to,
        uint256 amount
    ) internal {
        // TODO: refactor me please... please
        _checkAllowance(address(curvePool), address(want), amount);
        _checkAllowance(address(curvePool), yVault.token(), amount);

        // TODO: take into account decimals :D
        curvePool.exchange_underlying(
            from,
            to,
            amount,
            amount.mul(minExpectedSwapPercentage).div(MAX_BPS)
        );
    }
}
