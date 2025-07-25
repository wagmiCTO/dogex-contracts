// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Oracle.sol";

contract Dogex is ReentrancyGuard, Ownable {
    IERC20 private immutable usdc;
    DogePriceOracle private immutable oracle;

    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 entryPrice;
        bool isLong;
        bool isActive;
    }

    mapping(address => Position) public positions;

    mapping(uint256 => address) public activePositions;
    mapping(address => uint256) public positionIndex;
    uint256 public activePositionCount;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MAX_LEVERAGE = 100;
    uint256 private constant MIN_LEVERAGE = 10;
    uint256 private constant LIQUIDATION_THRESHOLD = 90; // 90% of collateral

    event PositionOpened(address indexed user, uint256 size, uint256 collateral, uint256 entryPrice, bool isLong);
    event PositionClosed(address indexed user, int256 pnl, uint256 finalAmount);
    event LiquidityAdded(address indexed owner, uint256 amount, uint256 newBalance);
    event LiquidityRemoved(address indexed owner, uint256 amount, uint256 newBalance);
    event PositionLiquidated(address indexed user, uint256 collateral, int256 pnl);
    event BatchLiquidation(address[] liquidatedUsers, uint256 totalLiquidated);

    constructor(address _usdc, address _oracle) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        oracle = DogePriceOracle(_oracle);
    }

     function openPosition(
         uint256 _collateralAmount,
         uint256 _sizeDelta,
         bool _isLong
     ) external nonReentrant {
         require(!positions[msg.sender].isActive, "Position already exists");
         require(_sizeDelta <= _collateralAmount * MAX_LEVERAGE, "Leverage too high");
         require(_sizeDelta >= _collateralAmount * MIN_LEVERAGE, "Leverage too low");

         usdc.transferFrom(msg.sender, address(this), _collateralAmount);

         uint256 entryPrice = getCurrentPrice();

         positions[msg.sender] = Position({
             size: _sizeDelta,
             collateral: _collateralAmount,
             entryPrice: entryPrice,
             isLong: _isLong,
             isActive: true
         });

         _addToActivePositions(msg.sender); // Add this line

         emit PositionOpened(msg.sender, _sizeDelta, _collateralAmount, entryPrice, _isLong);
     }

     function closePosition() external nonReentrant {
         Position storage position = positions[msg.sender];
         require(position.isActive, "No active position");

         uint256 currentPriceNow = getCurrentPrice();
         int256 pnl = calculatePnL(position, currentPriceNow);

         uint256 finalAmount = uint256(int256(position.collateral) + pnl);

         position.isActive = false;
         _removeFromActivePositions(msg.sender); // Add this line

         if (finalAmount > 0) {
             usdc.transfer(msg.sender, finalAmount);
         }

         emit PositionClosed(msg.sender, pnl, finalAmount);
     }

    function calculatePnL(Position memory _position, uint256 _currentPrice)
    internal
    pure
    returns (int256)
    {
        int256 priceDiff = int256(_currentPrice) - int256(_position.entryPrice);

        if (!_position.isLong) {
            priceDiff = -priceDiff;
        }

        return (priceDiff * int256(_position.size)) / int256(_position.entryPrice);
    }

    //PRICE MANAGEMENT
    function getCurrentPrice() public view returns (uint256) {
        (uint256 price, ) = oracle.getDogePrice();
        return price;
    }
    //END OF PRICE MANAGEMENT

    //LIQUIDITY MANAGEMENT
    /**
     * @notice Add USDC liquidity to the vault (only owner)
     * @param _amount Amount of USDC to add to vault liquidity
     */
    function addLiquidity(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Amount must be greater than 0");

        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.transferFrom(msg.sender, address(this), _amount);
        uint256 balanceAfter = usdc.balanceOf(address(this));

        emit LiquidityAdded(msg.sender, _amount, balanceAfter);
    }

    /**
     * @notice Remove USDC liquidity from the vault (only owner)
     * @param _amount Amount of USDC to remove from vault
     */
    function removeLiquidity(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Amount must be greater than 0");
        require(usdc.balanceOf(address(this)) >= _amount, "Insufficient vault balance");

        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.transfer(msg.sender, _amount);
        uint256 balanceAfter = usdc.balanceOf(address(this));

        emit LiquidityRemoved(msg.sender, _amount, balanceAfter);
    }

    /**
     * @notice Emergency withdrawal of all USDC (only owner)
     * @dev Use only in case of emergency
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = usdc.balanceOf(address(this));
        require(balance > 0, "No funds to withdraw");

        usdc.transfer(msg.sender, balance);
        emit LiquidityRemoved(msg.sender, balance, 0);
    }

    function getContractLiquidityBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
    // END OF LIQUIDITY MANAGEMENT

    struct PositionWithPnL {
        uint256 size;
        uint256 collateral;
        uint256 entryPrice;
        bool isLong;
        bool isActive;
        int256 pnl;
    }

    // TESTING FUNCTIONS
    function getPosition(address user) external view returns (PositionWithPnL memory) {
        Position memory position = positions[user];
        int256 currentPnl = 0;

        if (position.isActive) {
            uint256 currentPriceNow = getCurrentPrice();
            currentPnl = calculatePnL(position, currentPriceNow);
        }

        return PositionWithPnL({
            size: position.size,
            collateral: position.collateral,
            entryPrice: position.entryPrice,
            isLong: position.isLong,
            isActive: position.isActive,
            pnl: currentPnl
        });
    }


    //LIQUIDATION FUNCTIONS

    /**
     * @notice Checks if a position can be liquidated
     * @param _user Address of the position owner
     * @return bool True if the position can be liquidated
     */
    function isLiquidatable(address _user) public view returns (bool) {
        Position memory position = positions[_user];

        if (!position.isActive) {
            return false;
        }

        uint256 currentPriceNow = getCurrentPrice();
        int256 pnl = calculatePnL(position, currentPriceNow);

        // If PnL is negative and its absolute value exceeds the liquidation threshold
        if (pnl < 0 && uint256(-pnl) >= position.collateral * LIQUIDATION_THRESHOLD / 100) {
            return true;
        }

        return false;
    }

    /**
     * @notice Liquidates a position if it meets the liquidation criteria
     * @param _user Address of the position owner
     */
    function liquidatePosition(address _user) external nonReentrant {
        require(isLiquidatable(_user), "Position cannot be liquidated");

        Position storage position = positions[_user];
        uint256 currentPriceNow = getCurrentPrice();
        int256 pnl = calculatePnL(position, currentPriceNow);

        position.isActive = false;
        _removeFromActivePositions(_user); // Add this line

        uint256 remainingCollateral = 0;
        if (uint256(-pnl) < position.collateral) {
            remainingCollateral = position.collateral - uint256(-pnl);

            uint256 liquidatorFee = remainingCollateral * 5 / 100;
            uint256 userRefund = remainingCollateral - liquidatorFee;

            if (liquidatorFee > 0) {
                usdc.transfer(msg.sender, liquidatorFee);
            }

            if (userRefund > 0) {
                usdc.transfer(_user, userRefund);
            }
        }

        emit PositionLiquidated(_user, position.collateral, pnl);
    }

        /**
     * @notice Adds position to active tracking when opened
     */
    function _addToActivePositions(address user) internal {
        positionIndex[user] = activePositionCount;
        activePositions[activePositionCount] = user;
        activePositionCount++;
    }

    /**
     * @notice Removes position from active tracking when closed/liquidated
     */
    function _removeFromActivePositions(address user) internal {
        uint256 index = positionIndex[user];
        uint256 lastIndex = activePositionCount - 1;

        if (index != lastIndex) {
            address lastUser = activePositions[lastIndex];
            activePositions[index] = lastUser;
            positionIndex[lastUser] = index;
        }

        delete activePositions[lastIndex];
        delete positionIndex[user];
        activePositionCount--;
    }

    /**
     * @notice Batch liquidate multiple positions at once
     * @param maxLiquidations Maximum number of positions to liquidate in one call
     * @return liquidatedCount Number of positions actually liquidated
     */
   function batchLiquidate(uint256 maxLiquidations) external nonReentrant returns (uint256 liquidatedCount) {
       require(maxLiquidations > 0 && maxLiquidations <= 50, "Invalid batch size");

       address[] memory liquidatedUsers = new address[](maxLiquidations);
       uint256 currentPrice = getCurrentPrice();

       uint256 i = activePositionCount;

       while (i > 0 && liquidatedCount < maxLiquidations) {
           i--;
           address user = activePositions[i];
           Position storage position = positions[user];

           if (position.isActive) {
               int256 pnl = calculatePnL(position, currentPrice);

               if (pnl < 0 && uint256(-pnl) >= position.collateral * LIQUIDATION_THRESHOLD / 100) {
                   liquidatedUsers[liquidatedCount] = user;
                   _executeLiquidation(user, position, pnl);
                   liquidatedCount++;
               }
           }
       }

       if (liquidatedCount > 0) {
           // Resize array to actual liquidated count
           assembly {
               mstore(liquidatedUsers, liquidatedCount)
           }
           emit BatchLiquidation(liquidatedUsers, liquidatedCount);
       }

       return liquidatedCount;
   }

    /**
     * @notice Internal function to execute liquidation
     */
    function _executeLiquidation(address user, Position storage position, int256 pnl) internal {
        position.isActive = false;
        _removeFromActivePositions(user);

        // Calculate liquidator fee and user refund
        uint256 remainingCollateral = 0;
        if (uint256(-pnl) < position.collateral) {
            remainingCollateral = position.collateral - uint256(-pnl);

            uint256 liquidatorFee = remainingCollateral * 5 / 100;
            uint256 userRefund = remainingCollateral - liquidatorFee;

            if (liquidatorFee > 0) {
                usdc.transfer(msg.sender, liquidatorFee);
            }

            if (userRefund > 0) {
                usdc.transfer(user, userRefund);
            }
        }

        emit PositionLiquidated(user, position.collateral, pnl);
    }

    /**
     * @notice Get all liquidatable positions (for external monitoring)
     * @param maxCheck Maximum positions to check
     * @return liquidatableUsers Array of users with liquidatable positions
     */
    function getLiquidatablePositions(uint256 maxCheck) external view returns (address[] memory liquidatableUsers) {
        require(maxCheck > 0 && maxCheck <= 100, "Invalid check limit");

        address[] memory temp = new address[](maxCheck);
        uint256 liquidatableCount = 0;
        uint256 currentPrice = getCurrentPrice();

        uint256 toCheck = maxCheck > activePositionCount ? activePositionCount : maxCheck;

        for (uint256 i = 0; i < toCheck; i++) {
            address user = activePositions[i];
            Position memory position = positions[user];

            if (position.isActive) {
                int256 pnl = calculatePnL(position, currentPrice);

                if (pnl < 0 && uint256(-pnl) >= position.collateral * LIQUIDATION_THRESHOLD / 100) {
                    temp[liquidatableCount] = user;
                    liquidatableCount++;
                }
            }
        }

        // Resize array to actual count
        liquidatableUsers = new address[](liquidatableCount);
        for (uint256 i = 0; i < liquidatableCount; i++) {
            liquidatableUsers[i] = temp[i];
        }

        return liquidatableUsers;
    }
}
