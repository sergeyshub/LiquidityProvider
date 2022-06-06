// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "./balancer/Vault.sol";
import "./balancer/InvestmentPool.sol";
import "./balancer/InvestmentPoolFactory.sol";
import "./exchange/Exchange.sol";
import "./LiquidityProviderToken.sol";

contract LiquidityProvider is Ownable {
    string public Ticker;
    LpToken public lpToken;
    uint256 public assetCount;
    address public exchangeAddress = ZERO_ADDRESS;
    address public exchangeTokenAddress = ZERO_ADDRESS;

    event Transacted(address assetAddress, int256 amount, address user);
    event AddedLpAsset(address assetAddress);
    event RemovedLpAsset(address assetAddress);
    event ChangedAssetWeights(uint256[] newWeights, uint256 changeTime);

    address constant VAULT_ADDRESS = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant INVESTMENT_POOL_FACTORY_ADDRESS = 0x48767F9F868a4A7b86A90736632F6E44C2df7fa9;
    // address constant INVESTMENT_POOL_FACTORY_ADDRESS = 0x0f7bb7ce7b6ed9366F9b6B910AdeFE72dC538193; // Polygon
    uint256 constant MAX_UNIT256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    address constant ZERO_ADDRESS = 0x0000000000000000000000000000000000000000;
    uint256 constant MAX_ASSETS = 50; // max assets per lp (a Balancer limitation)

    uint256 constant SWAP_FEE = 3000000000000000; // 0.3%, range 0.0001% - 10%
    uint256 constant MANAGEMENT_FEE = 1000000000000000000; // 100%, we take all fees

    address[MAX_ASSETS] private assetAddresses;
    uint256[MAX_ASSETS] private assetWeights;
    IERC20 private bptToken;
    uint256 private bptTokenBalance = 0;
    uint256 private swapFeePercentage;
    address private poolAddress;
    bytes32 private poolId;

    // The addresses must be presorted, as we don't want to spend gas on sorting
    // weights are in fractions multiplied by 10^18. Must add up to 10^18. Example: [300000000000000000, 700000000000000000]
    // Minimum asset weight is 1%
    constructor(string memory newTicker, string memory newName, address[] memory addresses, uint256[] memory weights) {
        require(addresses.length == weights.length, "The number of addresses does not match the number of weights");

        lpTicker = newTicker;
        lpToken = new LpToken(newName, lpTicker);
        swapFeePercentage = SWAP_FEE;

        assetCount = addresses.length;

        for (uint256 i = 0; i < assetCount; i++) {
            assetAddresses[i] = addresses[i];
            assetWeights[i] = weights[i];
            IERC20(addresses[i]).approve(address(this), MAX_UNIT256);

            console.log("EVENT: AddedLpAsset, assetAddress %s", addresses[i]);
            emit AddedLpAsset(addresses[i]);
        }
        
        console.log("EVENT: ChangedAssetWeights, changeTime 0");
        emit ChangedAssetWeights(weights, 0);

        _createPool();
    }

    // Deposit one of the lp's assets to the lp. 
    // Asset must be approved first.
    function depositAsset(address assetAddress, uint256 amount) public {
        console.log("Depositing asset: %s, amount: %s, from: %s", assetAddress, amount, msg.sender);

        require(0 < amount, "The amount must be greater than zero");

        address[] memory tokenAddresses = new address[](assetCount);
        uint256[] memory tokenBalances = new uint256[](assetCount);
        IERC20 assetToken;
        bool isFound = false;

        for (uint256 i = 0; i < assetCount; i++) {
            tokenAddresses[i] = assetAddresses[i];

            if (assetAddresses[i] == assetAddress) {
                assetToken = IERC20(assetAddresses[i]);
                tokenBalances[i] = amount;
                isFound = true;
            }
            else {
                tokenBalances[i] = 0;
            }
        }
        require(isFound, "assetAddress must be one of the lp assets");

        assetToken.transferFrom(msg.sender, address(this), amount);
        _depositToBalancer(tokenAddresses, tokenBalances, false, true);

        console.log("EVENT: Transacted, assetAddress %s, amount +%s, user %s", assetAddress, amount, msg.sender);
        emit Transacted(assetAddress, int256(amount), msg.sender);
    }

    // Deposit native token by converting it into one of the lp assets via an exchange
    function depositNativeToken() payable public {
        uint256 amount = msg.value;

        console.log("Depositing %s native token", amount);

        require(0 < amount, "The amount must be greater than zero");
        require(exchangeAddress != ZERO_ADDRESS, "The exchange address is not set");
        require(exchangeTokenAddress != ZERO_ADDRESS, "The exchange token address is not set");

        Exchange exchange = Exchange(exchangeAddress);
        uint256 amountToken = exchange.buy{value: amount}(exchangeTokenAddress);

        console.log("Exchanged for %s of %s token", amountToken, exchangeTokenAddress);

        address[] memory tokenAddresses = new address[](assetCount);
        uint256[] memory tokenBalances = new uint256[](assetCount);

        for (uint256 i = 0; i < assetCount; i++) {
            tokenAddresses[i] = assetAddresses[i];
            if (assetAddresses[i] == exchangeTokenAddress) tokenBalances[i] = amountToken;
            else tokenBalances[i] = 0;

            console.log("Asset: %s, balance: %s", assetAddresses[i], tokenBalances[i]);
        }

        _depositToBalancer(tokenAddresses, tokenBalances, false, true);

        console.log("EVENT: Transacted, assetAddress %s, amount +%s, user %s", exchangeTokenAddress, amountToken, msg.sender);
        emit Transacted(exchangeTokenAddress, int256(amountToken), msg.sender);
    }

    // Processes a withdraw in the amount of lpToken (not the assetToken). It does not need to be approved first.
    // This will fail if there is not enough of the asset in the pool
    function withdrawAsset(address assetAddress, uint256 amount) public {
       console.log("Withdrawing asset %s for %s lp token", assetAddress, amount);

       require(0 < amount, "The amount must be greater than 0");

       _withdrawAsset(assetAddress, amount, payable(msg.sender));
    }

    // Processes a withdraw of a fraction of all assets in the amount of lpToken
    function withdrawMultipleAssets(uint256 amount) public {
        console.log("Withdrawing multiple assets for %s lp token", amount);

        require(0 < amount, "The amount must be greater than 0");

        IERC20[] memory tokens = new IERC20[](assetCount);
        uint256[] memory oldBalances = new uint256[](assetCount);

        for (uint256 i = 0; i < assetCount; i++) {
            tokens[i] = IERC20(assetAddresses[i]);
            oldBalances[i] = tokens[i].balanceOf(msg.sender);
        }

        _withdrawFromBalancer(amount, -1, true, msg.sender);

        for (uint256 i = 0; i < assetCount; i++) {
            uint256 balanceChange = tokens[i].balanceOf(msg.sender) - oldBalances[i];
            if (0 < balanceChange) {
                console.log("EVENT: Transacted, assetAddress %s, amount -%s, user %s", assetAddresses[i], balanceChange, msg.sender);
                emit Transacted(assetAddresses[i], -int256(balanceChange), msg.sender);
            }
        }
    }

    // Processes a withdraw in native token in the amount of lpToken (not the native token)
    // This will fail if there is not enough of the exchangeToken in the pool
    function withdrawNativeToken(uint256 amount) public {
        console.log("Withdrawing native token for %s lp token", amount);

        require(0 < amount, "The amount must be greater than zero");
        require(exchangeAddress != ZERO_ADDRESS, "The exchange address is not set");
        require(exchangeTokenAddress != ZERO_ADDRESS, "The exchange token address is not set");

        IERC20 exchangeToken = IERC20(exchangeTokenAddress);
        uint256 exchangeTokenQuantity = exchangeToken.balanceOf(address(this));

        _withdrawAsset(exchangeTokenAddress, amount, payable(address(this)));

        exchangeTokenQuantity = exchangeToken.balanceOf(address(this)) - exchangeTokenQuantity;

        console.log("Got from Balancer %s of exchange token", exchangeTokenQuantity);

        Exchange exchange = Exchange(exchangeAddress);
        exchangeToken.approve(exchangeAddress, exchangeTokenQuantity);
        uint256 amountNative = exchange.sell(exchangeTokenAddress, exchangeTokenQuantity);

        console.log("Exchanged for %s of native token", amountNative);

        payable(msg.sender).transfer(amountNative);
    }

    function getAssetBalances() public view returns (IERC20[] memory, uint256[] memory) {
       Vault vault = Vault(VAULT_ADDRESS);

       (IERC20[] memory tokens, uint256[] memory balances, ) = vault.getPoolTokens(poolId);

       return (tokens, balances);
    }

    function getAssetWeights() public view returns (uint256[] memory) {
       InvestmentPool pool = InvestmentPool(poolAddress);

       uint256[] memory weights = pool.getNormalizedWeights();

       return weights;
    }

    // All tokens need to be sent to the Lp contract first.
    function initializeLp() onlyOwner public {
        _depositAllToBalancer(true, true, true);
    }

    // newWeights are in fractions multiplied by 10^18. Must add up to 10^18. Example: ["300000000000000000", "700000000000000000"] (add quotes for Scaffold-Eth)
    // Minimum asset weight is 1%
    // changeTime is how long to change to new weights in seconds starting from now, 86400 (1 day) minimum
    function changeAssetWeights(uint256[] memory newWeights, uint256 changeTime) onlyOwner public {
        uint256 startTime = block.timestamp;
        uint256 finishTime = startTime + changeTime;

        console.log("Changing weights, start time: %s, finish time: %s", startTime, finishTime);

        InvestmentPool pool = InvestmentPool(poolAddress);

        // Not validating the weights, as Balancer does it for us
        pool.updateWeightsGradually(startTime, finishTime, newWeights);

        console.log("EVENT: ChangedAssetWeights, changeTime %s", changeTime);
        emit ChangedAssetWeights(newWeights, changeTime);
    }

    function getSwapFeePercentage() onlyOwner public view returns (uint256) {
        return InvestmentPool(poolAddress).getSwapFeePercentage();
    }

    function setSwapFeePercentage(uint256 newSwapFeePercentage) onlyOwner public {
        swapFeePercentage = newSwapFeePercentage;
        InvestmentPool(poolAddress).setSwapFeePercentage(swapFeePercentage);
    }

    // Adds an asset to the lp. A new token must be sent to the lp contract prior to calling this.
    function addLpAsset(address assetAddress, uint256 assetWeight) onlyOwner public {
        console.log("Adding asset: %s", assetAddress, assetWeight);

        require(assetCount < MAX_ASSETS, "Max number of assets exceeded");

        _withdrawAllFromBalancer();

        uint256 i;
        uint256 totalWeight = 0;
        uint256 remainingWeight = 1000000000000000000 - assetWeight;

        for (i = 0; i < assetCount; i++) {
            require(assetAddress != assetAddresses[i], "Asset is already in the lp");
            if (assetAddress < assetAddresses[i]) break;
            assetWeights[i] = (assetWeights[i] * remainingWeight) / 1000000000000000000;
            totalWeight += assetWeights[i];
        }

        for (uint256 j = assetCount; j > i; j--) {
            assetAddresses[j] = assetAddresses[j - 1];
            assetWeights[j] = (assetWeights[j - 1] * remainingWeight) / 1000000000000000000;
            totalWeight += assetWeights[j];
        }

        assetAddresses[i] = assetAddress;
        assetWeights[i] = 1000000000000000000 - totalWeight;

        assetCount++;

        IERC20 assetToken = IERC20(assetAddress);
        assetToken.approve(address(this), MAX_UNIT256);
        uint256 assetBalance = assetToken.balanceOf(address(this));

        _createPool();
        _depositAllToBalancer(true, true, false);

        console.log("EVENT: Transacted, assetAddress %s, amount +%s, user %s", assetAddress, assetBalance, msg.sender);
        emit Transacted(assetAddress, int256(assetBalance), msg.sender);

        console.log("EVENT: AddedLpAsset, assetAddress %s", assetAddress);
        emit AddedLpAsset(assetAddress);
    }

    // Removes an asset from the lp. 
    // The removed asset will withdrawn and sent to the sender.
    // May need to send some other assets to the lp first, or there may be not enough lp token in the sender's wallet to be burned.
    function removeLpAsset(address assetAddress) onlyOwner public {
        console.log("Removing asset: %s", assetAddress);

        require(2 < assetCount, "Must have at least 3 assets");

        _withdrawAllFromBalancer();

        uint256 i;
        for (i = 0; i < assetCount; i++) if (assetAddress == assetAddresses[i]) break;
        require(i < assetCount, "The asset must be one of the lp assets");
        uint256 totalWeight = 0;
        uint256 remainingWeight = 1000000000000000000 - assetWeights[i];

        assetCount--;

        for (uint256 j = 0; j < assetCount; j++) {
            if (i <= j) {
                assetAddresses[j] = assetAddresses[j + 1];
                assetWeights[j] = assetWeights[j + 1];
            }

            if (j == assetCount - 1) {
                assetWeights[j] = 1000000000000000000 - totalWeight;
            } else {
                assetWeights[j] = (assetWeights[j] * 1000000000000000000) / remainingWeight;
            }

            totalWeight += assetWeights[j];
        }

        IERC20 assetToken = IERC20(assetAddress);
        uint256 assetBalance = assetToken.balanceOf(address(this));
        console.log("Returning %s of %s to sender", assetBalance, assetAddress);
        assetToken.transferFrom(address(this), msg.sender, assetBalance);

        _createPool();
        _depositAllToBalancer(true, true, false);

        console.log("EVENT: Transacted, assetAddress %s, amount -%s, user %s", assetAddress, assetBalance, msg.sender);
        emit Transacted(assetAddress, -int256(assetBalance), msg.sender);

        console.log("EVENT: RemovedLpAsset, assetAddress %s", assetAddress);
        emit RemovedLpAsset(assetAddress);
    }

    // Get all accumulated management fees in different tokens
    function getManagementFees() onlyOwner public view returns (IERC20[] memory, uint256[] memory) {
       (IERC20[] memory tokens, uint256[] memory fees) = InvestmentPool(poolAddress).getCollectedManagementFees();

       return (tokens, fees);
    }

    // Withdraw accumulated fees in different tokens, redeposit them to Balancer, and send a corresponding amount of lp token to the owner.
    // Note that management fees are counted in the total Balancer pool balance, so this method does not change the balances, only mints the lp token.
    // This can probably be done more gas efficiently with Balancer internal balances. However, there is no way to check internal balances.
    function withdrawManagementFees() onlyOwner public {
        _withdrawBalancerManagementFees();

        // Redeposit all fee tokens back to the pool and send the lp token to msg.sender
        _depositAllToBalancer(false, true, true);
    }

    function setExchangeAddress(address newExchangeAddress) onlyOwner public {
        exchangeAddress = newExchangeAddress;
    }

    function setExchangeTokenAddress(address newExchangeTokenAddress) onlyOwner public {
        bool isFound = false;

        for (uint256 i = 0; i < assetCount; i++) {
            if (assetAddresses[i] == newExchangeTokenAddress) {
                isFound = true;
                break;
            }
        }

        require(isFound, "assetAddress must be one of the lp assets");

        exchangeTokenAddress = newExchangeTokenAddress;
    }

    // Withdraws all contract tokens not deposited in Balancer.
    function withdrawAllUninvestedTokens() onlyOwner public {
        console.log("Withdrawing all uninvested tokens to %s", address(this));

        for (uint256 i = 0; i < assetCount; i++) {
            IERC20 assetToken = IERC20(assetAddresses[i]);
            console.log("Asset: %s, balance: %s", assetAddresses[i], assetToken.balanceOf(address(this)));
            assetToken.transferFrom(address(this), msg.sender, assetToken.balanceOf(address(this)));
        }
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {
        console.log("Received %s native token", msg.value);
    }

    // Fallback function is called when msg.data is not empty
    fallback() external payable {
        console.log("Fallback");
    }

    /*
    // TEST: get native token balance
    function getNativeTokenBalance() public view returns (uint) {
        return address(this).balance;
    }

    // TEST: get Balancer pool token balance
    function getBptBalance() public view returns (uint256) {
       return bptToken.balanceOf(address(this));
    }

    // TEST: get lp token balance of an address
    function getLpTokenBalance(address account) public view returns (uint) {
        return lpToken.balanceOf(account);
    }
    */
    
    function _createPool() internal {
        IERC20[] memory tokens = new IERC20[](assetCount);
        uint256[] memory tokenWeights = new uint256[](assetCount);
        
        // Not validating the weights as Balancer does it for us
        for (uint256 i = 0; i < assetCount; i++) {
            tokens[i] = IERC20(assetAddresses[i]);
            tokenWeights[i] =  assetWeights[i];
            console.log("Asset: %s, weight: %s", assetAddresses[i], assetWeights[i]);
        }

        // Create a Balancer pool
        InvestmentPoolFactory poolFactory = InvestmentPoolFactory(INVESTMENT_POOL_FACTORY_ADDRESS);

        // This automatically registers a pool with the Balancer Vault
        poolAddress = poolFactory.create(lpTicker, lpTicker, tokens, tokenWeights, swapFeePercentage, address(this), true, MANAGEMENT_FEE);
        console.log("Created a Balancer pool at address: %s", poolAddress);

        // Get poolId from InvestmentPool
        InvestmentPool pool = InvestmentPool(poolAddress);
        poolId = pool.getPoolId();

        // Get Balancer pool token
        bptToken = IERC20(poolAddress); // the Balancer pool token has the same address as the balancer pool
    }

    // This will fail if there is not enough of the asset in the pool
    function _withdrawAsset(address assetAddress, uint256 amount, address receiver) private {
        int256 assetTokenIndex = -1;
        for (uint256 i = 0; i < assetCount; i++) {
            if (assetAddresses[i] == assetAddress) {
                assetTokenIndex = int256(i);
                break;
            }
        }
        require(assetTokenIndex != -1, "assetAddress must be one of the lp assets");

        IERC20 assetToken = IERC20(assetAddress);
        uint256 oldBalance = assetToken.balanceOf(msg.sender);

        _withdrawFromBalancer(amount, assetTokenIndex, true, receiver);
    
        uint256 balanceChange = assetToken.balanceOf(msg.sender) - oldBalance;

        console.log("EVENT: Transacted, assetAddress %s, amount -%s, user %s", assetAddress, balanceChange, msg.sender);
        emit Transacted(assetAddress, -int256(balanceChange), msg.sender);
    }

    function _depositAllToBalancer(bool isNewPool, bool isMint, bool isEvent) internal {
        console.log("Depositing all assets to Balancer, new pool: %s, mint: %s", isNewPool, isMint);

        address[] memory tokenAddresses = new address[](assetCount);
        uint256[] memory tokenBalances = new uint256[](assetCount);

        for (uint256 i = 0; i < assetCount; i++) {
            IERC20 assetToken = IERC20(assetAddresses[i]);

            tokenAddresses[i] = assetAddresses[i];
            tokenBalances[i] = assetToken.balanceOf(address(this));

            console.log("Asset: %s, balance: %s", assetAddresses[i], tokenBalances[i]);

            if (isNewPool) {
                // When initializing a pool, none of the token balances can be 0
                require(0 < tokenBalances[i], "All token balances must be greater than zero");

                // Need to allow the Vault to access (not the pool), use max unit256 to allow once and for all
                assetToken.approve(VAULT_ADDRESS, MAX_UNIT256);
            }

            if (isEvent && 0 < tokenBalances[i]) {
                console.log("EVENT: Transacted, assetAddress %s, amount +%s, user %s", tokenAddresses[i], tokenBalances[i], msg.sender);
                emit Transacted(tokenAddresses[i], int256(tokenBalances[i]), msg.sender);
            }
        }

        _depositToBalancer(tokenAddresses, tokenBalances, isNewPool, isMint);
    }

    // Balancer leaves behind some of each token (maybe because zero balances are not allowed)
    function _withdrawAllFromBalancer() internal {
        _withdrawBalancerManagementFees();
        _withdrawFromBalancer(bptToken.balanceOf(address(this)), -1, false, address(this));
    }

    function _depositToBalancer(address[] memory tokenAddresses, uint256[] memory tokenBalances, bool isNewPool, bool isMint) internal {
        bytes memory userDataEncoded;
        // If pass INIT for an existing pool, Balancer will return error BAL#310 (UNHANDLED_JOIN_KIND)
        if (isNewPool) userDataEncoded = abi.encode(JoinKind.INIT, tokenBalances);
        else userDataEncoded = abi.encode(JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, tokenBalances, 0);

        VaultStructs.JoinPoolRequest memory joinPoolRequest = VaultStructs.JoinPoolRequest({
            assets: tokenAddresses,
            maxAmountsIn: tokenBalances,
            userData: userDataEncoded,
            fromInternalBalance: false
        });

        // The recipient can be any account without authorization
        Vault(VAULT_ADDRESS).joinPool(poolId, address(this), address(this), joinPoolRequest);

        if (isMint) _adjustLpTokenUserBalance();
    }

    // amount is in pool token
    // Set tokenAssetIndex to -1 to withdraw all assets.
    function _withdrawFromBalancer(uint256 amount, int256 assetTokenIndex, bool isBurn, address receiver) internal {
        console.log("Withdrawing tokens form Balancer for %s BPT, burn: %s", amount, isBurn);

        address[] memory tokenAddresses = new address[](assetCount);
        uint256[] memory minAmounts = new uint256[](assetCount);

        for (uint256 i = 0; i < assetCount; i++) {
            tokenAddresses[i] = assetAddresses[i];
            minAmounts[i] = 0;
        }

        bytes memory userDataEncoded;
        if (assetTokenIndex != -1) userDataEncoded = abi.encode(ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT, amount, assetTokenIndex);
        else userDataEncoded = abi.encode(ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, amount);

        VaultStructs.ExitPoolRequest memory exitPoolRequest = VaultStructs.ExitPoolRequest({
            assets: tokenAddresses,
            minAmountsOut: minAmounts,
            userData: userDataEncoded,
            toInternalBalance: false
        });

        // The recipient can be any account without authorization
        Vault(VAULT_ADDRESS).exitPool(poolId, address(this), payable(receiver), exitPoolRequest);

        if (isBurn) _adjustLpTokenUserBalance();
    }

    function _withdrawBalancerManagementFees() internal {
        InvestmentPool(poolAddress).withdrawCollectedManagementFees(address(this));
    }

    // This will fail if the user does not have enough lp token balance to burn
    function _adjustLpTokenUserBalance() internal {
        uint256 bptTokenBalanceNew = bptToken.balanceOf(address(this)); 

        console.log("Adjusting user balance, old balance: %s, new balance: %s", bptTokenBalance, bptTokenBalanceNew);

        if (bptTokenBalance == bptTokenBalanceNew) return;

        if (bptTokenBalance < bptTokenBalanceNew) {
            lpToken.Mint(msg.sender, bptTokenBalanceNew - bptTokenBalance);
        } else {
            lpToken.Burn(msg.sender, bptTokenBalance - bptTokenBalanceNew);
        }

        bptTokenBalance = bptTokenBalanceNew;
    }
}
