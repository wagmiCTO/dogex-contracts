// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1000000 * 10**6); // 1M USDC
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockDOGE is ERC20 {
    constructor() ERC20("Mock DOGE", "mDOGE") {
        _mint(msg.sender, 1000000 * 10**8); // 1M DOGE
    }
    
    function decimals() public pure override returns (uint8) {
        return 8;
    }
}