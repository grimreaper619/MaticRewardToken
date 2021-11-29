// SPDX-License-Identifier: MIT

pragma solidity ^0.8.8;

import "./misc/DividendPayingToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./math/IterableMapping.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract TOKEN is ERC20, Ownable {
    using SafeMath for uint256;

    struct BuyFee {
        uint16 autoLp;
        uint16 reward;
        uint16 marketing;
        uint16 dev;
        uint16 giveAway;
    }

    struct SellFee {
        uint16 autoLp;
        uint16 reward;
        uint16 marketing;
        uint16 dev;
        uint16 giveAway;
        uint16 buyBack;
    }

    BuyFee public buyFee;
    SellFee public sellFee;

    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;

    bool private swapping;
    bool public enableTrading;

    uint16 private totalBuyFee;
    uint16 private totalSellFee;

    uint256 public timeDelay = 12 hours;

    TOKENDividendTracker public dividendTracker;

    address private constant deadWallet = address(0xdead);

    address private RewardToken =
        address(0x77c21c770Db1156e271a3516F89380BA53D594FA); //RewardToken

    uint256 public swapTokensAtAmount = 2 * 10**6 * (10**18);
    uint256 public maxBuyAmount = 1 * 10**7 * 10**18;
    uint256 public maxSellAmount = 1 * 10**7 * 10**18;
    uint256 public maxWalletAmount = 1 * 10**8 * 10**18;

    address public marketing = address(0x1);
    address public dev = address(0x2);
    address public giveAway = address(0x3);

    // use by default 300,000 gas to process auto-claiming dividends
    uint256 public gasForProcessing = 300000;

    // exlcude from fees and max transaction amount
    mapping(address => bool) private _isExcludedFromFees;

    mapping(address => uint256) private coolDown;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;

    event UpdateDividendTracker(
        address indexed newAddress,
        address indexed newTracker
    );

    event UpdateUniswapV2Router(
        address indexed newAddress,
        address indexed oldAddress
    );

    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    event LiquidityWalletUpdated(
        address indexed newLiquidityWallet,
        address indexed oldLiquidityWallet
    );

    event GasForProcessingUpdated(
        uint256 indexed newValue,
        uint256 indexed oldValue
    );

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    event SendDividends(uint256 tokensSwapped, uint256 amount);

    event ProcessedDividendTracker(
        uint256 iterations,
        uint256 claims,
        uint256 lastProcessedIndex,
        bool indexed automatic,
        uint256 gas,
        address indexed processor
    );

    constructor() ERC20("TOKEN", "TKN") {
        dividendTracker = new TOKENDividendTracker(RewardToken);

        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3
        );
        // Create a uniswap pair for this new token
        address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());

        uniswapV2Router = _uniswapV2Router;
        uniswapV2Pair = _uniswapV2Pair;
        enableTrading = true;

        buyFee.autoLp = 20;
        buyFee.reward = 20;
        buyFee.marketing = 20;
        buyFee.dev = 20;
        buyFee.giveAway = 20;
        totalBuyFee =
            buyFee.autoLp +
            buyFee.reward +
            buyFee.marketing +
            buyFee.dev +
            buyFee.giveAway;

        sellFee.autoLp = 30;
        sellFee.reward = 30;
        sellFee.marketing = 30;
        sellFee.dev = 30;
        sellFee.giveAway = 30;
        sellFee.buyBack = 30;
        totalSellFee =
            sellFee.autoLp +
            sellFee.reward +
            sellFee.marketing +
            sellFee.dev +
            sellFee.giveAway +
            sellFee.buyBack;

        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);

        // exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(owner());
        dividendTracker.excludeFromDividends(deadWallet);
        dividendTracker.excludeFromDividends(address(_uniswapV2Router));

        // exclude from paying fees or having max transaction amount
        excludeFromFees(owner(), true);
        excludeFromFees(marketing, true);
        excludeFromFees(address(this), true);

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(owner(), 1 * 10**9 * (10**18));
    }

    receive() external payable {}

    function updateDividendTracker(address newToken) public onlyOwner {
        TOKENDividendTracker newDividendTracker = new TOKENDividendTracker(
            newToken
        );

        newDividendTracker.excludeFromDividends(address(newDividendTracker));
        newDividendTracker.excludeFromDividends(address(this));
        newDividendTracker.excludeFromDividends(owner());
        newDividendTracker.excludeFromDividends(address(uniswapV2Router));

        RewardToken = newToken;
        dividendTracker = newDividendTracker;

        emit UpdateDividendTracker(newToken, address(dividendTracker));
    }

    function updateUniswapV2Router(address newAddress) public onlyOwner {
        
        emit UpdateUniswapV2Router(newAddress, address(uniswapV2Router));
        uniswapV2Router = IUniswapV2Router02(newAddress);
        address _uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
            .createPair(address(this), uniswapV2Router.WETH());
        uniswapV2Pair = _uniswapV2Pair;
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {

        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(
        address[] calldata accounts,
        bool excluded
    ) public onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    function setWallets(
        address _w1,
        address _w2,
        address _w3
    ) external onlyOwner {
        marketing = _w1;
        dev = _w2;
        giveAway = _w3;
    }

    function setBuyFees(
        uint16 lp,
        uint16 reward,
        uint16 market,
        uint16 develop,
        uint16 giveaway
    ) external onlyOwner {
        buyFee.autoLp = lp;
        buyFee.reward = reward;
        buyFee.marketing = market;
        buyFee.dev = develop;
        buyFee.giveAway = giveaway;

        totalBuyFee =
            buyFee.autoLp +
            buyFee.reward +
            buyFee.marketing +
            buyFee.dev +
            buyFee.giveAway;
    }

    function setSellFees(
        uint16 lp,
        uint16 reward,
        uint16 market,
        uint16 develop,
        uint16 giveaway,
        uint16 buyback
    ) external onlyOwner {
        sellFee.autoLp = lp;
        sellFee.reward = reward;
        sellFee.marketing = market;
        sellFee.dev = develop;
        sellFee.giveAway = giveaway;
        sellFee.buyBack = buyback;

        totalSellFee =
            sellFee.autoLp +
            sellFee.reward +
            sellFee.marketing +
            sellFee.dev +
            sellFee.giveAway +
            sellFee.buyBack;
    }

    function setAutomatedMarketMakerPair(address pair, bool value)
        public
        onlyOwner
    {

        _setAutomatedMarketMakerPair(pair, value);
    }

    function setSwapTokens(uint256 amount) external onlyOwner {
        swapTokensAtAmount = amount;
    }

    function setMaxBuy(uint256 amount) external onlyOwner {
        maxBuyAmount = amount;
    }

    function setCoolDown( uint256 timePeriod) external onlyOwner {
        timeDelay = timePeriod;
    }

    function setTrading(bool value) external onlyOwner {
        enableTrading = value;
    }

    function setMaxSell(uint256 amount) external onlyOwner {
        maxSellAmount = amount;
    }

    function setMaxWallet(uint256 amount) external onlyOwner {
        maxWalletAmount = amount;
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {

        automatedMarketMakerPairs[pair] = value;

        if (value) {
            dividendTracker.excludeFromDividends(pair);
        }

        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function updateGasForProcessing(uint256 newValue) public onlyOwner {
        require(
            newValue >= 200000 && newValue <= 500000
        );

        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    function updateClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }

    function getClaimWait() external view returns (uint256) {
        return dividendTracker.claimWait();
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function isExcludedFromFees(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function withdrawableDividendOf(address account)
        public
        view
        returns (uint256)
    {
        return dividendTracker.withdrawableDividendOf(account);
    }

    function dividendTokenBalanceOf(address account)
        public
        view
        returns (uint256)
    {
        return dividendTracker.balanceOf(account);
    }

    function excludeFromDividends(address account) external onlyOwner {
        dividendTracker.excludeFromDividends(account);
    }

    function getAccountDividendsInfo(address account)
        external
        view
        returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return dividendTracker.getAccount(account);
    }

    function getAccountDividendsInfoAtIndex(uint256 index)
        external
        view
        returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return dividendTracker.getAccountAtIndex(index);
    }

    function processDividendTracker(uint256 gas) external {
        (
            uint256 iterations,
            uint256 claims,
            uint256 lastProcessedIndex
        ) = dividendTracker.process(gas);

        emit ProcessedDividendTracker(
            iterations,
            claims,
            lastProcessedIndex,
            false,
            gas,
            tx.origin
        );
    }

    function claim() external {
        dividendTracker.processAccount(payable(msg.sender), false);
    }

    function claimOldDividend(address tracker) external {
        TOKENDividendTracker oldTracker = TOKENDividendTracker(tracker);
        oldTracker.processAccount(payable(msg.sender), false);
    }

    function getLastProcessedIndex() external view returns (uint256) {
        return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns (uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        uint256 contractTokenBalance = balanceOf(address(this));

        bool canSwap = contractTokenBalance >= swapTokensAtAmount;

        if (
            canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from] &&
            from != owner() &&
            to != owner()
        ) {
            swapping = true;

            uint256 balance = address(this).balance;
            if (balance > uint256(1 * 10**16)) {
                swapETHForTokens(balance.div(10));
            }

            uint16 totalFees = totalBuyFee + totalSellFee;
            uint16 walletFees = sellFee.marketing +
                sellFee.dev +
                sellFee.giveAway +
                sellFee.buyBack +
                buyFee.marketing +
                buyFee.dev +
                buyFee.giveAway;

            contractTokenBalance = swapTokensAtAmount;

            uint256 walletTokens = contractTokenBalance.mul(walletFees).div(
                totalFees
            );
            swapAndSendToFee(walletTokens, walletFees);

            uint256 swapTokens = contractTokenBalance
                .mul(buyFee.autoLp + sellFee.autoLp)
                .div(totalFees);

            swapAndLiquify(swapTokens);

            uint256 sellTokens = contractTokenBalance
                .mul(buyFee.reward + sellFee.reward)
                .div(totalFees);
            swapAndSendDividends(sellTokens);

            uint256 buyBackTokens = contractTokenBalance
                .mul(sellFee.buyBack)
                .div(totalFees);
            swapTokensForEth(buyBackTokens);

            swapping = false;
        }

        bool takeFee = !swapping;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if (_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if (takeFee) {
            uint256 fees;
            require(enableTrading, "Trading disabled");

            if (automatedMarketMakerPairs[from]) {
                require(amount <= maxBuyAmount, "Buy exceeds limit");
                require(
                    coolDown[to] + timeDelay <= block.timestamp
                );

                fees = amount.mul(totalBuyFee).div(1000);
                coolDown[to] = block.timestamp;
            } else if (automatedMarketMakerPairs[to]) {
                require(amount <= maxSellAmount, "Sell exceeds limit");
                require(
                    coolDown[from] + timeDelay <= block.timestamp
                );

                fees = amount.mul(totalSellFee).div(1000);
                coolDown[from] = block.timestamp;
            }

            if (!automatedMarketMakerPairs[to]) {
                require(
                    amount + balanceOf(to) <= maxWalletAmount,
                    "Wallet exceeds limit"
                );
                if (!automatedMarketMakerPairs[from]) {
                    require(
                        coolDown[from] + timeDelay <= block.timestamp
                    );
                    coolDown[from] = block.timestamp;
                }
            }

            if (fees > 0) {
                amount = amount.sub(fees);
                super._transfer(from, address(this), fees);
            }
        }

        super._transfer(from, to, amount);

        try
            dividendTracker.setBalance(payable(from), balanceOf(from))
        {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

        if (!swapping) {
            uint256 gas = gasForProcessing;

            try dividendTracker.process(gas) returns (
                uint256 iterations,
                uint256 claims,
                uint256 lastProcessedIndex
            ) {
                emit ProcessedDividendTracker(
                    iterations,
                    claims,
                    lastProcessedIndex,
                    true,
                    gas,
                    tx.origin
                );
            } catch {}
        }
    }

    function swapAndSendToFee(uint256 tokens, uint16 fees) private {
        uint256 initialRewardTokenBalance = IERC20(RewardToken).balanceOf(
            address(this)
        );

        swapTokensForRewardToken(tokens);

        uint256 newBalance = (IERC20(RewardToken).balanceOf(address(this))).sub(
            initialRewardTokenBalance
        );

        uint256 marketingShare = newBalance
            .mul(buyFee.marketing + sellFee.marketing)
            .div(fees);
        uint256 devShare = newBalance.mul(buyFee.dev + sellFee.dev).div(fees);
        uint256 giveAwayShare = newBalance
            .mul(buyFee.giveAway + sellFee.giveAway)
            .div(fees);

        IERC20(RewardToken).transfer(marketing, marketingShare);
        IERC20(RewardToken).transfer(dev, devShare);
        IERC20(RewardToken).transfer(giveAway, giveAwayShare);
    }

    function swapAndLiquify(uint256 tokens) private {
        // split the contract balance into halves
        uint256 half = tokens.div(2);
        uint256 otherHalf = tokens.sub(half);

        // swap tokens for ETH
        swapTokensForEth(half); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance;

        // add liquidity to uniswap
        addLiquidity(otherHalf, newBalance);

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function swapETHForTokens(uint256 amount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = address(this);
 
      // make the swap
        uniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            0, // accept any amount of Tokens
            path,
            address(0xdead), // Burn address
            block.timestamp.add(300)
        );
 
    }

    function swapTokensForRewardToken(uint256 tokenAmount) private {
        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        path[2] = RewardToken;

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // add the liquidity
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(0),
            block.timestamp
        );
    }

    function swapAndSendDividends(uint256 tokens) private {
        uint256 initialRewardTokenBalance = IERC20(RewardToken).balanceOf(
            address(this)
        );

        swapTokensForRewardToken(tokens);

        uint256 newBalance = (IERC20(RewardToken).balanceOf(address(this))).sub(
            initialRewardTokenBalance
        );

        bool success = IERC20(RewardToken).transfer(
            address(dividendTracker),
            newBalance
        );

        if (success) {
            dividendTracker.distributeRewardToken(newBalance);
            emit SendDividends(tokens, newBalance);
        }
    }
}

contract TOKENDividendTracker is Ownable, DividendPayingToken {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using IterableMapping for IterableMapping.Map;

    IterableMapping.Map private tokenHoldersMap;
    uint256 public lastProcessedIndex;

    mapping(address => bool) public excludedFromDividends;

    mapping(address => uint256) public lastClaimTimes;

    uint256 public claimWait;
    uint256 public immutable minimumTokenBalanceForDividends;

    event ExcludeFromDividends(address indexed account);
    event ClaimWaitUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event Claim(
        address indexed account,
        uint256 amount,
        bool indexed automatic
    );

    constructor(address rewardToken)
        DividendPayingToken(
            "TOKEN_Dividen_Tracker",
            "TOKEN_Dividend_Tracker",
            rewardToken
        )
    {
        claimWait = 3600;
        minimumTokenBalanceForDividends = 20000 * (10**18); //must hold 20000+ tokens
    }

    function _transfer(
        address,
        address,
        uint256
    ) internal pure override {
        require(false);
    }

    function withdrawDividend() public pure override {
        require(
            false
        );
    }

    function excludeFromDividends(address account) external onlyOwner {
        require(!excludedFromDividends[account]);
        excludedFromDividends[account] = true;

        _setBalance(account, 0);
        tokenHoldersMap.remove(account);

        emit ExcludeFromDividends(account);
    }

    function updateClaimWait(uint256 newClaimWait) external onlyOwner {
        require(
            newClaimWait >= 3600 && newClaimWait <= 86400,
            "TOKEN_Dividend_Tracker: claimWait must be updated to between 1 and 24 hours"
        );

        emit ClaimWaitUpdated(newClaimWait, claimWait);
        claimWait = newClaimWait;
    }

    function getLastProcessedIndex() external view returns (uint256) {
        return lastProcessedIndex;
    }

    function getNumberOfTokenHolders() external view returns (uint256) {
        return tokenHoldersMap.keys.length;
    }

    function getAccount(address _account)
        public
        view
        returns (
            address account,
            int256 index,
            int256 iterationsUntilProcessed,
            uint256 withdrawableDividends,
            uint256 totalDividends,
            uint256 lastClaimTime,
            uint256 nextClaimTime,
            uint256 secondsUntilAutoClaimAvailable
        )
    {
        account = _account;

        index = tokenHoldersMap.getIndexOfKey(account);

        iterationsUntilProcessed = -1;

        if (index >= 0) {
            if (uint256(index) > lastProcessedIndex) {
                iterationsUntilProcessed = index.sub(
                    int256(lastProcessedIndex)
                );
            } else {
                uint256 processesUntilEndOfArray = tokenHoldersMap.keys.length >
                    lastProcessedIndex
                    ? tokenHoldersMap.keys.length.sub(lastProcessedIndex)
                    : 0;

                iterationsUntilProcessed = index.add(
                    int256(processesUntilEndOfArray)
                );
            }
        }

        withdrawableDividends = withdrawableDividendOf(account);
        totalDividends = accumulativeDividendOf(account);

        lastClaimTime = lastClaimTimes[account];

        nextClaimTime = lastClaimTime > 0 ? lastClaimTime.add(claimWait) : 0;

        secondsUntilAutoClaimAvailable = nextClaimTime > block.timestamp
            ? nextClaimTime.sub(block.timestamp)
            : 0;
    }

    function getAccountAtIndex(uint256 index)
        public
        view
        returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        if (index >= tokenHoldersMap.size()) {
            return (
                0x0000000000000000000000000000000000000000,
                -1,
                -1,
                0,
                0,
                0,
                0,
                0
            );
        }

        address account = tokenHoldersMap.getKeyAtIndex(index);

        return getAccount(account);
    }

    function canAutoClaim(uint256 lastClaimTime) private view returns (bool) {
        if (lastClaimTime > block.timestamp) {
            return false;
        }

        return block.timestamp.sub(lastClaimTime) >= claimWait;
    }

    function setBalance(address payable account, uint256 newBalance)
        external
        onlyOwner
    {
        if (excludedFromDividends[account]) {
            return;
        }

        if (newBalance >= minimumTokenBalanceForDividends) {
            _setBalance(account, newBalance);
            tokenHoldersMap.set(account, newBalance);
        } else {
            _setBalance(account, 0);
            tokenHoldersMap.remove(account);
        }

        processAccount(account, true);
    }

    function process(uint256 gas)
        public
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 numberOfTokenHolders = tokenHoldersMap.keys.length;

        if (numberOfTokenHolders == 0) {
            return (0, 0, lastProcessedIndex);
        }

        uint256 _lastProcessedIndex = lastProcessedIndex;

        uint256 gasUsed = 0;

        uint256 gasLeft = gasleft();

        uint256 iterations = 0;
        uint256 claims = 0;

        while (gasUsed < gas && iterations < numberOfTokenHolders) {
            _lastProcessedIndex++;

            if (_lastProcessedIndex >= tokenHoldersMap.keys.length) {
                _lastProcessedIndex = 0;
            }

            address account = tokenHoldersMap.keys[_lastProcessedIndex];

            if (canAutoClaim(lastClaimTimes[account])) {
                if (processAccount(payable(account), true)) {
                    claims++;
                }
            }

            iterations++;

            uint256 newGasLeft = gasleft();

            if (gasLeft > newGasLeft) {
                gasUsed = gasUsed.add(gasLeft.sub(newGasLeft));
            }

            gasLeft = newGasLeft;
        }

        lastProcessedIndex = _lastProcessedIndex;

        return (iterations, claims, lastProcessedIndex);
    }

    function processAccount(address payable account, bool automatic)
        public
        onlyOwner
        returns (bool)
    {
        uint256 amount = _withdrawDividendOfUser(account);

        if (amount > 0) {
            lastClaimTimes[account] = block.timestamp;
            emit Claim(account, amount, automatic);
            return true;
        }

        return false;
    }
}
