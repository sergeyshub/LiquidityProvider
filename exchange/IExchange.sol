//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IExchange {
    event Bought(address tokenAddress, uint256 quantity);
    event Sold(address tokenAddress, uint256 quantity);

    // Buy token, quantity in native token
    function buy(address tokenAddress) payable external returns (uint256);

    // Sell token, quantity in token
    function sell(address tokenAddress, uint256 quantity) external returns (uint256);
}
