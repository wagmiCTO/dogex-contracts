# Dogex - Decentralized Derivatives Exchange

## Overview

Dogex is a decentralized derivatives exchange that enables users to trade leveraged positions on Dogecoin (DOGE) using USDC as collateral. The platform supports both long and short positions with leverage ranging from 10x to 200x.

## Key Features

- **Leveraged Trading**: Trade DOGE with 10x to 200x leverage
- **Long/Short Positions**: Bet on DOGE price going up (long) or down (short)
- **Collateral Management**: Uses USDC as collateral for all positions
- **Automated Liquidations**: Protects against excessive losses with 90% liquidation threshold
- **Oracle Integration**: Real-time DOGE price feeds from external oracle
- **Safety Mechanisms**: Reentrancy protection and access controls

## Contract Architecture

### Core Components

- **Position Management**: Each user can have one active position at a time
- **Collateral System**: USDC-based collateral with min/max limits
- **PnL Calculation**: Real-time profit/loss calculation based on price movements
- **Liquidation Engine**: Automated liquidation when losses exceed threshold

### Key Constants

- **MAX_LEVERAGE**: 200x maximum leverage
- **MIN_LEVERAGE**: 10x minimum leverage
- **LIQUIDATION_THRESHOLD**: 90% of collateral
- **MIN_COLLATERAL**: 1 USDC (1e6 units)
- **MAX_COLLATERAL**: 1000 USDC (1000e6 units)

## Functions

### User Functions

#### `openPosition(uint256 _collateralAmount, uint256 _sizeDelta, bool _isLong)`
Opens a new leveraged position on DOGE.

**Parameters:**
- `_collateralAmount`: Amount of USDC to deposit as collateral (1-1000 USDC)
- `_sizeDelta`: Notional size of the position in USDC terms
- `_isLong`: True for long position, false for short position

**Requirements:**
- No existing active position
- Leverage between 10x-200x
- Sufficient USDC balance and allowance

#### `closePosition()`
Closes the caller's active position and settles PnL.

**Requirements:**
- Must have an active position
- Contract must have sufficient liquidity for profitable positions

### Admin Functions

#### `addLiquidity(uint256 amount)`
Adds USDC liquidity to the contract (owner only).

#### `removeLiquidity(uint256 amount)`
Removes USDC liquidity from the contract (owner only).

#### `liquidatePosition(address user)`
Liquidates a single user's position if it meets liquidation criteria.

#### `batchLiquidate(uint256 startIndex, uint256 endIndex)`
Liquidates multiple positions in a single transaction for gas efficiency.

### View Functions

#### `calculatePnL(Position memory position, uint256 currentPrice)`
Calculates profit/loss for a given position at current price.

#### `getCurrentPrice()`
Gets the current DOGE price from the oracle.

#### `getPosition(address user)`
Returns the position details for a specific user.

## Events

- **PositionOpened**: Emitted when a new position is created
- **PositionClosed**: Emitted when a position is closed with PnL details
- **PositionLiquidated**: Emitted when a position is liquidated
- **BatchLiquidation**: Emitted for batch liquidation operations
- **LiquidityAdded/Removed**: Emitted for liquidity management operations

## Position Struct

```solidity
struct Position {
    uint256 size;        // Notional size in USDC terms
    uint256 collateral;  // USDC collateral amount
    uint256 entryPrice;  // DOGE price at position opening
    bool isLong;         // Position direction
    bool isActive;       // Position status
}
```

## Security Features

- **ReentrancyGuard**: Prevents reentrancy attacks
- **Ownable**: Access control for admin functions
- **Input Validation**: Comprehensive parameter validation
- **Liquidation Protection**: Automatic liquidation to prevent bad debt

## Dependencies

- OpenZeppelin Contracts (ERC20, ReentrancyGuard, Ownable)
- Custom Oracle contract for DOGE price feeds
- USDC token contract for collateral

## Usage Example

```solidity
// Open a 50x long position with 10 USDC collateral
dogex.openPosition(10e6, 500e6, true);

// Close the position
dogex.closePosition();
```

## Risk Considerations

- **Liquidation Risk**: Positions can be liquidated if losses exceed 90% of collateral
- **Oracle Risk**: Price feeds depend on external oracle accuracy
- **Leverage Risk**: High leverage amplifies both gains and losses
- **Liquidity Risk**: Contract must maintain sufficient USDC for settlements

## License

MIT License
