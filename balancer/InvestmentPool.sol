//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract InvestmentPool {
    function getPoolId() public view returns (bytes32) { }

    function getSwapEnabled() public view returns (bool) { }

    function getNormalizedWeights() public view returns (uint256[] memory) { }

    function updateWeightsGradually(
        uint256 startTime,
        uint256 endTime,
        uint256[] memory endWeights
    ) public { }

    function getCollectedManagementFees() public view returns (IERC20[] memory tokens, uint256[] memory collectedFees) { }

    function withdrawCollectedManagementFees(address recipient) public { }

    function getSwapFeePercentage() public view returns (uint256) { }

    function setSwapFeePercentage(uint256 swapFeePercentage) public { }
}
