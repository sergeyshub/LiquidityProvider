//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "./IExchange.sol";

contract Exchange is IExchange {
    uint256 public price = 2;

    function buy(address tokenAddress) payable public override returns (uint256) {
        uint256 quantity = msg.value;

        console.log("Buying %s token for %s native token", tokenAddress, quantity);

        require(0 < quantity, "The quantity must be greater than zero");

        IERC20 token = IERC20(tokenAddress);

        uint256 quantityToken = quantity / price;
        uint256 balanceToken = token.balanceOf(address(this));

        require(quantityToken <= balanceToken, "Insufficient liquidity for the token");

        token.approve(address(this), quantityToken);
        token.transferFrom(address(this), msg.sender, quantityToken);

        emit Bought(tokenAddress, quantityToken);

        return quantityToken;
    }

    function sell(address tokenAddress, uint256 quantity) public override returns (uint256) {
        console.log("Selling %s of %s token", quantity, tokenAddress);

        require(0 < quantity, "The quantity must be greater than zero");

        IERC20 token = IERC20(tokenAddress);

        uint256 quantityNative = quantity * price;
        uint256 balanceNative = address(this).balance;

        require(quantityNative <= balanceNative, "Insufficient liquidity for the native token");

        token.transferFrom(msg.sender, address(this), quantity);
        
        payable(msg.sender).transfer(quantityNative);

        emit Sold(tokenAddress, quantity);

        return quantityNative;
    }

    // TEST
    /*
    receive() external payable {
        console.log("Received %s native token", msg.value);
    }
    */

    // TEST
    function getNativeTokenBalance() public view returns (uint) {
        return address(this).balance;
    }

    // TEST
    function getTokenBalance(address tokenAddress) public view returns (uint256) {
       return IERC20(tokenAddress).balanceOf(address(this));
    }

    // TEST
    function withdrawNativeToken() public {
        uint256 balance = address(this).balance;
        if (0 < balance) payable(msg.sender).transfer(balance);
    }

    // TEST
    function withdrawToken(address tokenAddress) public {
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        if (0 < balance) {
            token.approve(address(this), balance); 
            token.transferFrom(address(this), msg.sender, balance);
        }
    }
}
