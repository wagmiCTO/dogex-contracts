// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

contract DogePriceOracle is Ownable {
    struct PriceData {
        uint256 price;
        uint256 timestamp;
    }

    PriceData public dogePrice;

    event DogePriceUpdated(uint256 price, uint256 timestamp);

    constructor() Ownable(msg.sender) {
        _updateDogePrice(7 * 1e16);
    }

    function updateDogePrice(uint256 price) external onlyOwner {
        require(price > 0, "Price must be positive");
        _updateDogePrice(price);
    }

    function _updateDogePrice(uint256 price) internal {
        dogePrice = PriceData(price, block.timestamp);
        emit DogePriceUpdated(price, block.timestamp);
    }

    function getDogePrice() external view returns (uint256 price, uint256 timestamp) {
        require(dogePrice.price > 0, "Dogecoin price not available");
        return (dogePrice.price, dogePrice.timestamp);
    }
}