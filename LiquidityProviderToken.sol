// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LiquidityProviderToken is ERC20, Ownable {
    constructor(string memory name, string memory ticker) ERC20(name, ticker) {
    }
    
    function Mint(address account, uint256 amount) onlyOwner public {
        _mint(account, amount);
    }
    
    function Burn(address account, uint256 amount) onlyOwner public {
        _burn(account, amount);
    }
}
