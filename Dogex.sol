// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Oracle.sol";

/**
 * @title Dogex
 * @notice A decentralized derivatives exchange for trading Dogecoin (DOGE) with leverage
 * @dev This contract allows users to open leveraged long/short positions on DOGE using USDC as collateral.
 *      It includes features for position management, liquidations, and liquidity management.
 *      The contract uses an external oracle for DOGE price feeds and implements safety mechanisms
 *      including liquidation thresholds and leverage limits.
 * @author Dogex Team
 */
contract Dogex is ReentrancyGuard, Ownable {
    /// @notice USDC token contract used as collateral
    IERC20 private immutable usdc;

    /// @notice Oracle contract for DOGE price feeds
    DogePriceOracle private immutable oracle;

    /**
     * @notice Represents a trading position
     * @param id Unique identifier for the position
     * @param size The notional size of the position in USDC terms
     * @param collateral The amount of USDC collateral deposited
     * @param entryPrice The DOGE price when the position was opened
     * @param isLong True for long positions, false for short positions
     * @param isActive Whether the position is currently active
     */
    struct Position {
        uint256 id;
        uint256 size;
        uint256 collateral;
        uint256 entryPrice;
        bool isLong;
        bool isActive;
    }

    /// @notice Mapping from user address to their position
    mapping(address => Position) public positions;

    /// @notice Mapping from position ID to user address for reverse lookup
    mapping(uint256 => address) public positionIdToUser;

    /// @notice Counter for generating unique position IDs
    uint256 private nextPositionId = 1;

    /// @notice Mapping from index to user address for active position tracking
    mapping(uint256 => address) public activePositions;

    /// @notice Mapping from user address to their index in activePositions array
    mapping(address => uint256) public positionIndex;

    /// @notice Total number of active positions
    uint256 public activePositionCount;

    /// @notice Precision constant for calculations (18 decimals)
    uint256 private constant PRECISION = 1e18;

    /// @notice Maximum allowed leverage (200x)
    uint256 private constant MAX_LEVERAGE = 200;

    /// @notice Minimum allowed leverage (10x)
    uint256 private constant MIN_LEVERAGE = 10;

    /// @notice Liquidation threshold as percentage of collateral (90%)
    uint256 private constant LIQUIDATION_THRESHOLD = 90;

    /// @notice Minimum collateral amount (1 USDC)
    uint256 private constant MIN_COLLATERAL = 1e6;

    /// @notice Maximum collateral amount (1000 USDC)
    uint256 private constant MAX_COLLATERAL = 1000e6;

    /**
     * @notice Emitted when a new position is opened
     * @param user The address of the user who opened the position
     * @param positionId The unique ID assigned to the position
     * @param size The notional size of the position
     * @param collateral The amount of collateral deposited
     * @param entryPrice The DOGE price at position opening
     * @param isLong True if it's a long position, false if short
     */
    event PositionOpened(address indexed user, uint256 indexed positionId, uint256 size, uint256 collateral, uint256 entryPrice, bool isLong);

    /**
     * @notice Emitted when a position is closed
     * @param user The address of the user who closed the position
     * @param positionId The unique ID of the closed position
     * @param pnl The profit/loss of the position (positive for profit, negative for loss)
     * @param finalAmount The final amount returned to the user
     */
    event PositionClosed(address indexed user, uint256 indexed positionId, int256 pnl, uint256 finalAmount);

    /**
     * @notice Emitted when liquidity is added to the contract
     * @param owner The address that added liquidity
     * @param amount The amount of USDC added
     * @param newBalance The new total balance after addition
     */
    event LiquidityAdded(address indexed owner, uint256 amount, uint256 newBalance);

    /**
     * @notice Emitted when liquidity is removed from the contract
     * @param owner The address that removed liquidity
     * @param amount The amount of USDC removed
     * @param newBalance The new total balance after removal
     */
    event LiquidityRemoved(address indexed owner, uint256 amount, uint256 newBalance);

    /**
     * @notice Emitted when a position is liquidated
     * @param user The address of the user whose position was liquidated
     * @param positionId The unique ID of the liquidated position
     * @param collateral The original collateral amount
     * @param pnl The profit/loss at liquidation
     */
    event PositionLiquidated(address indexed user, uint256 indexed positionId, uint256 collateral, int256 pnl);

    /**
     * @notice Emitted when multiple positions are liquidated in a batch
     * @param liquidatedUsers Array of user addresses that were liquidated
     * @param totalLiquidated The total number of positions liquidated
     */
    event BatchLiquidation(address[] liquidatedUsers, uint256 totalLiquidated);

    /**
     * @notice Initializes the Dogex contract
     * @param _usdc Address of the USDC token contract
     * @param _oracle Address of the DOGE price oracle contract
     */
    constructor(address _usdc, address _oracle) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        oracle = DogePriceOracle(_oracle);
    }

    /**
     * @notice Opens a new leveraged position on DOGE
     * @dev Users can only have one active position at a time. The function validates leverage
     *      limits, collateral bounds, and transfers USDC from the user as collateral.
     * @param _collateralAmount Amount of USDC to deposit as collateral (must be between MIN_COLLATERAL and MAX_COLLATERAL)
     * @param _sizeDelta The notional size of the position (determines leverage when combined with collateral)
     * @param _isLong True to open a long position (bet on price increase), false for short (bet on price decrease)
     * @custom:requirements
     * - User must not have an existing active position
     * - Leverage must be between MIN_LEVERAGE (10x) and MAX_LEVERAGE (200x)
     * - Collateral must be between 1 and 1000 USDC
     * - User must have sufficient USDC balance and allowance
     */
    function openPosition(
        uint256 _collateralAmount,
        uint256 _sizeDelta,
        bool _isLong
    ) external nonReentrant {
        require(!positions[msg.sender].isActive, "Position already exists");
        require(_sizeDelta <= _collateralAmount * MAX_LEVERAGE, "Leverage too high");
        require(_sizeDelta >= _collateralAmount * MIN_LEVERAGE, "Leverage too low");
        require(_collateralAmount >= MIN_COLLATERAL, "Collateral below minimum");
        require(_collateralAmount <= MAX_COLLATERAL, "Collateral above maximum");

        usdc.transferFrom(msg.sender, address(this), _collateralAmount);

        uint256 entryPrice = getCurrentPrice();
        uint256 currentPositionId = nextPositionId;

        positions[msg.sender] = Position({
            id: currentPositionId,
            size: _sizeDelta,
            collateral: _collateralAmount,
            entryPrice: entryPrice,
            isLong: _isLong,
            isActive: true
        });

        positionIdToUser[currentPositionId] = msg.sender;
        nextPositionId++;

        _addToActivePositions(msg.sender);

        emit PositionOpened(msg.sender, currentPositionId, _sizeDelta, _collateralAmount, entryPrice, _isLong);
    }

    /**
     * @notice Closes the caller's active position
     * @dev Calculates current PnL based on current DOGE price and returns the final amount to the user.
     *      If the final amount is positive, USDC is transferred back to the user.
     * @custom:requirements
     * - User must have an active position
     * - Contract must have sufficient USDC balance if position is profitable
     */
    function closePosition() external nonReentrant {
        Position storage position = positions[msg.sender];
        require(position.isActive, "No active position");

        uint256 currentPriceNow = getCurrentPrice();
        int256 pnl = calculatePnL(position, currentPriceNow);

        uint256 finalAmount = uint256(int256(position.collateral) + pnl);
        uint256 positionId = position.id;

        position.isActive = false;
        _removeFromActivePositions(msg.sender);

        if (finalAmount > 0) {
            usdc.transfer(msg.sender, finalAmount);
        }

        emit PositionClosed(msg.sender, positionId, pnl, finalAmount);
    }

    /**
     * @notice Calculates the profit and loss (PnL) for a given position
     * @dev PnL is calculated based on the difference between current price and entry price,
     *      scaled by the position size. For short positions, the price difference is inverted.
     * @param _position The position struct to calculate PnL for
     * @param _currentPrice The current DOGE price to use for calculation
     * @return The PnL in USDC terms (positive for profit, negative for loss)
     */
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

    /**
     * @notice Gets the current DOGE price from the oracle
     * @dev Fetches the latest DOGE price from the connected oracle contract
     * @return The current DOGE price
     */
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

    /**
     * @notice Get the current USDC balance of the contract
     * @dev Returns the total USDC liquidity available in the contract
     * @return The USDC balance of the contract
     */
    function getContractLiquidityBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
    // END OF LIQUIDITY MANAGEMENT

    /**
     * @notice Extended position struct that includes current PnL
     * @param id Unique identifier for the position
     * @param size The notional size of the position
     * @param collateral The amount of collateral deposited
     * @param entryPrice The entry price of the position
     * @param isLong True for long positions, false for short
     * @param isActive Whether the position is currently active
     * @param pnl The current profit/loss of the position
     */
    struct PositionWithPnL {
        uint256 id;
        uint256 size;
        uint256 collateral;
        uint256 entryPrice;
        bool isLong;
        bool isActive;
        int256 pnl;
    }

    // BACKEND MANAGEMENT FUNCTIONS

    /**
     * @notice Get a position by its unique ID
     * @dev This function allows backends to look up positions using the position ID
     * @param positionId The unique ID of the position
     * @return A PositionWithPnL struct containing all position data including current PnL
     */
    function getPositionById(uint256 positionId) external view returns (PositionWithPnL memory) {
        address user = positionIdToUser[positionId];
        require(user != address(0), "Position does not exist");

        return getPosition(user);
    }

    /**
     * @notice Get the user address associated with a position ID
     * @dev Helper function for backend systems to resolve position IDs to user addresses
     * @param positionId The position ID to look up
     * @return The user address that owns the position
     */
    function getPositionOwner(uint256 positionId) external view returns (address) {
        return positionIdToUser[positionId];
    }

    /**
     * @notice Get the current next position ID that will be assigned
     * @dev Useful for backend systems to predict the next position ID
     * @return The next position ID that will be used
     */
    function getNextPositionId() external view returns (uint256) {
        return nextPositionId;
    }

    /**
     * @notice Check if a position ID exists and is active
     * @dev Utility function for backend validation
     * @param positionId The position ID to check
     * @return True if the position exists and is active
     */
    function isPositionActive(uint256 positionId) external view returns (bool) {
        address user = positionIdToUser[positionId];
        if (user == address(0)) return false;
        return positions[user].isActive;
    }

    /**
     * @notice Get a user's position with current PnL calculated
     * @dev This function is useful for frontend applications to display current position status
     * @param user The address of the user whose position to retrieve
     * @return A PositionWithPnL struct containing all position data including current PnL
     */
    function getPosition(address user) public view returns (PositionWithPnL memory) {
        Position memory position = positions[user];
        int256 currentPnl = 0;

        if (position.isActive) {
            uint256 currentPriceNow = getCurrentPrice();
            currentPnl = calculatePnL(position, currentPriceNow);
        }

        return PositionWithPnL({
            id: position.id,
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
        uint256 positionId = position.id;

        position.isActive = false;
        _removeFromActivePositions(_user);

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

        emit PositionLiquidated(_user, positionId, position.collateral, pnl);
    }

    /**
     * @notice Adds position to active tracking when opened
     * @dev Internal function to manage the activePositions array and positionIndex mapping
     * @param user The user address to add to active position tracking
     */
    function _addToActivePositions(address user) internal {
        positionIndex[user] = activePositionCount;
        activePositions[activePositionCount] = user;
        activePositionCount++;
    }

    /**
     * @notice Removes position from active tracking when closed/liquidated
     * @dev Internal function that efficiently removes a position from tracking by swapping
     *      with the last element and decrementing the count
     * @param user The user address to remove from active position tracking
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
     * @dev Efficiently liquidates multiple positions in a single transaction to save gas.
     *      Iterates through active positions and liquidates those that meet the criteria.
     * @param maxLiquidations Maximum number of positions to liquidate in one call (capped at 50)
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
     * @dev Handles the liquidation process including fee calculation and fund distribution
     * @param user The address of the user being liquidated
     * @param position The position being liquidated (storage reference for gas efficiency)
     * @param pnl The current profit/loss of the position
     */
    function _executeLiquidation(address user, Position storage position, int256 pnl) internal {
        uint256 positionId = position.id;

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

        emit PositionLiquidated(user, positionId, position.collateral, pnl);
    }

    /**
     * @notice Get all liquidatable positions (for external monitoring)
     * @dev Useful for liquidation bots and monitoring systems to identify positions
     *      that can be liquidated. Limited to prevent gas issues.
     * @param maxCheck Maximum positions to check (capped at 100)
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
