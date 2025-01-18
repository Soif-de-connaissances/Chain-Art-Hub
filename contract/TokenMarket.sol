// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./NFT.sol"; // 引入 NFT 合约

contract TokenMarket is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct TokenInfo {
        uint256 price;      // 价格（以 wei 为单位）
        bool isListed;      // 是否已上市
        uint256 available;  // 平台可用数量
    }

    struct Trade {
        uint256 amount;     // 交易量
        uint256 timestamp;  // 交易时间
    }

    mapping(address => TokenInfo) public listedTokens;
    mapping(address => mapping(address => uint256)) public userTokenBalances;
    mapping(address => Trade[]) public tokenTradeHistory; // 每种代币的交易记录

    address public feeCollector; // 手续费收集地址
    uint256 public accumulatedFees; // 累积的手续费 

    NFT public nftContract; // NFT 合约实例

    // 动物类型对应的手续费率（万分比）
    mapping(NFT.AnimalType => uint256) public feeRates;

    event TokenListed(address indexed token, uint256 price, uint256 amount);
    event TokenDelisted(address indexed token);
    event TokenPurchased(address indexed buyer, address indexed token, uint256 amount, uint256 cost, uint256 fee);
    event TokenSold(address indexed seller, address indexed token, uint256 amount, uint256 earning);
    event FeeRateUpdated(NFT.AnimalType animalType, uint256 newRate);
    event FeesCollected(uint256 amount);
    event TradeRecorded(address indexed token, uint256 amount, uint256 timestamp);

    constructor(address _nftContract) Ownable(msg.sender) {
        feeCollector = msg.sender;
        nftContract = NFT(_nftContract);

        // 设置默认手续费率
        feeRates[NFT.AnimalType.RABBIT] = 30;   // 0.3%
        feeRates[NFT.AnimalType.PANDA] = 27;    // 0.27%
        feeRates[NFT.AnimalType.TIGER] = 24;    // 0.24%
        feeRates[NFT.AnimalType.DRAGON] = 21;   // 0.21%
    }

    // 设置手续费率
    function updateFeeRate(NFT.AnimalType animalType, uint256 newRate) external onlyOwner {
        require(newRate <= 500, "Fee rate cannot exceed 5%");
        feeRates[animalType] = newRate;
        emit FeeRateUpdated(animalType, newRate);
    }

    // 收集累积的手续费
    function collectFees() external {
        require(msg.sender == feeCollector, "Only fee collector can collect fees");
        uint256 feesToCollect = accumulatedFees;
        accumulatedFees = 0;

        (bool success, ) = feeCollector.call{value: feesToCollect}("");
        require(success, "Fee transfer failed");

        emit FeesCollected(feesToCollect);
    }

    // 上市新代币
    function listToken(address _token, uint256 _priceInWei, uint256 _amount) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        require(_priceInWei > 0, "Price must be greater than 0");
        require(_amount > 0, "Amount must be greater than 0");

        IERC20 token = IERC20(_token);

        uint256 allowance = token.allowance(msg.sender, address(this));
        require(allowance >= _amount, "Insufficient allowance");

        uint256 balance = token.balanceOf(msg.sender);
        require(balance >= _amount, "Insufficient balance");

        token.safeTransferFrom(msg.sender, address(this), _amount);

        listedTokens[_token] = TokenInfo({
            price: _priceInWei,
            isListed: true,
            available: _amount
        });

        emit TokenListed(_token, _priceInWei, _amount);
    }

    // 下架代币
    function delistToken(address _token) external onlyOwner {
        TokenInfo storage tokenInfo = listedTokens[_token];
        require(tokenInfo.isListed, "Token not listed");

        IERC20 token = IERC20(_token);
        uint256 contractBalance = token.balanceOf(address(this));

        require(contractBalance >= tokenInfo.available, "Contract balance too low");

        if (tokenInfo.available > 0) {
            token.safeTransfer(owner(), tokenInfo.available);
        }

        delete listedTokens[_token];

        emit TokenDelisted(_token);
    }

    // 购买代币
    function buyToken(address _token, uint256 _amount) external payable {
        TokenInfo storage tokenInfo = listedTokens[_token];
        require(tokenInfo.isListed, "Token not listed");
        require(tokenInfo.available >= _amount, "Insufficient token balance");

        uint256 totalCost = (_amount * tokenInfo.price) / 1e18;

        // 获取用户动物类型并动态计算手续费
        NFT.AnimalType userAnimalType = nftContract.getAnimalType(msg.sender);
        uint256 feeRate = feeRates[userAnimalType];
        uint256 fee = (totalCost * feeRate) / 10000;
        uint256 totalPayment = totalCost + fee;

        require(msg.value >= totalPayment, "Insufficient ETH sent");

        tokenInfo.available -= _amount;
        userTokenBalances[msg.sender][_token] += _amount;
        accumulatedFees += fee;

        IERC20(_token).safeTransfer(msg.sender, _amount);

        if (msg.value > totalPayment) {
            (bool success, ) = msg.sender.call{value: msg.value - totalPayment}("");
            require(success, "ETH refund failed");
        }

        _recordTrade(_token, _amount);

        emit TokenPurchased(msg.sender, _token, _amount, totalCost, fee);
    }

    // 卖出代币
    function sellToken(address _token, uint256 _amount) external {
        TokenInfo storage tokenInfo = listedTokens[_token];
        require(tokenInfo.isListed, "Token not listed");
        require(_amount > 0, "Amount must be greater than 0");

        IERC20 token = IERC20(_token);

        uint256 allowance = token.allowance(msg.sender, address(this));
        require(allowance >= _amount, "Insufficient allowance");

        uint256 balance = token.balanceOf(msg.sender);
        require(balance >= _amount, "Insufficient balance");

        uint256 totalEarning = (_amount * tokenInfo.price) / 1e18;

        // 获取用户动物类型并动态计算手续费
        NFT.AnimalType userAnimalType = nftContract.getAnimalType(msg.sender);
        uint256 feeRate = feeRates[userAnimalType];
        uint256 fee = (totalEarning * feeRate) / 10000;
        uint256 actualEarning = totalEarning - fee;

        require(address(this).balance >= actualEarning, "Insufficient contract balance");

        token.safeTransferFrom(msg.sender, address(this), _amount);

        userTokenBalances[msg.sender][_token] -= _amount;
        tokenInfo.available += _amount;
        accumulatedFees += fee;

        (bool success, ) = msg.sender.call{value: actualEarning}("");
        require(success, "ETH transfer failed");

        _recordTrade(_token, _amount);

        emit TokenSold(msg.sender, _token, _amount, actualEarning);
    }

    // 记录交易量
    function _recordTrade(address _token, uint256 _amount) internal {
        tokenTradeHistory[_token].push(Trade({
            amount: _amount,
            timestamp: block.timestamp
        }));

        emit TradeRecorded(_token, _amount, block.timestamp);
    }

    // 获取总交易量
    function getTotalVolume(address _token) external view returns (uint256) {
        uint256 totalVolume = 0;
        for (uint256 i = 0; i < tokenTradeHistory[_token].length; i++) {
            totalVolume += tokenTradeHistory[_token][i].amount;
        }
        return totalVolume;
    }

    // 获取近期交易量
    function getRecentVolume(address _token) external view returns (uint256) {
        uint256 recentVolume = 0;
        uint256 someDaysAgo = block.timestamp - 3 days;
        for (uint256 i = 0; i < tokenTradeHistory[_token].length; i++) {
            if (tokenTradeHistory[_token][i].timestamp >= someDaysAgo) {
                recentVolume += tokenTradeHistory[_token][i].amount;
            }
        }
        return recentVolume;
    }
}