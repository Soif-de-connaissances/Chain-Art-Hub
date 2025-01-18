// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.8.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.8.0/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.8.0/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.8.0/contracts/token/ERC20/IERC20.sol";

// 定义 NFT 接口
interface INFT {
    enum AnimalType { RABBIT, PANDA, TIGER, DRAGON }
    function getAnimalType(address user) external view returns (AnimalType);
}

contract DEX is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public token1;
    IERC20 public token2;

    uint256 public token1Balance;
    uint256 public token2Balance;

    INFT public nftContract;

    // 使用 uint8 来匹配 enum
    mapping(uint8 => uint256) public feeRates;

    struct Trade {
        uint256 amount;
        uint256 timestamp;
    }

    mapping(address => Trade[]) public tokenTradeHistory;

    event LiquidityAdded(address indexed provider, uint256 token1Amount, uint256 token2Amount);
    event LiquidityRemoved(address indexed provider, uint256 token1Amount, uint256 token2Amount);
    event Swap(address indexed user, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);
    event TradeRecorded(address indexed token, uint256 amount, uint256 timestamp);
    event FeeRateUpdated(uint8 animalType, uint256 newRate);

    constructor(address _nftContract, address _token1, address _token2) {
        require(_token1 != address(0) && _token2 != address(0), "Invalid token addresses");
        token1 = IERC20(_token1);
        token2 = IERC20(_token2);
        nftContract = INFT(_nftContract);

        // 初始化费率
        feeRates[uint8(INFT.AnimalType.RABBIT)] = 30;   // 0.3%
        feeRates[uint8(INFT.AnimalType.PANDA)] = 27;    // 0.27%
        feeRates[uint8(INFT.AnimalType.TIGER)] = 24;    // 0.24%
        feeRates[uint8(INFT.AnimalType.DRAGON)] = 21;   // 0.21%
    }

    function updateFeeRate(uint8 animalType, uint256 newRate) external onlyOwner {
        require(newRate <= 500, "Fee rate cannot exceed 5%");
        require(animalType <= uint8(INFT.AnimalType.DRAGON), "Invalid animal type");
        feeRates[animalType] = newRate;
        emit FeeRateUpdated(animalType, newRate);
    }

    function addLiquidity(uint256 _token1Amount, uint256 _token2Amount) external onlyOwner nonReentrant {
        require(_token1Amount > 0 && _token2Amount > 0, "Amounts must be greater than 0");

        token1.safeTransferFrom(msg.sender, address(this), _token1Amount);
        token2.safeTransferFrom(msg.sender, address(this), _token2Amount);

        token1Balance += _token1Amount;
        token2Balance += _token2Amount;

        emit LiquidityAdded(msg.sender, _token1Amount, _token2Amount);
    }

    function removeLiquidity(uint256 _token1Amount, uint256 _token2Amount) external onlyOwner nonReentrant {
        require(_token1Amount > 0 && _token2Amount > 0, "Amounts must be greater than 0");
        require(token1Balance >= _token1Amount && token2Balance >= _token2Amount, "Insufficient liquidity");

        token1Balance -= _token1Amount;
        token2Balance -= _token2Amount;

        token1.safeTransfer(owner(), _token1Amount);
        token2.safeTransfer(owner(), _token2Amount);

        emit LiquidityRemoved(owner(), _token1Amount, _token2Amount);
    }

    function swap(address _tokenIn, uint256 _amountIn) public nonReentrant returns (uint256 amountOut) {
        require(_tokenIn == address(token1) || _tokenIn == address(token2), "Invalid token");
        require(_amountIn > 0, "Amount must be greater than 0");

        IERC20 tokenIn = IERC20(_tokenIn);
        IERC20 tokenOut = _tokenIn == address(token1) ? token2 : token1;

        uint256 reserveIn = _tokenIn == address(token1) ? token1Balance : token2Balance;
        uint256 reserveOut = _tokenIn == address(token1) ? token2Balance : token1Balance;

        // 获取用户动物类型并计算手续费
        uint8 userAnimalType = uint8(nftContract.getAnimalType(msg.sender));
        uint256 feeRate = feeRates[userAnimalType];
        uint256 amountInWithFee = (_amountIn * (10000 - feeRate)) / 10000;

        amountOut = (amountInWithFee * reserveOut) / (reserveIn + amountInWithFee);
        require(amountOut > 0 && amountOut <= reserveOut, "Insufficient liquidity");

        tokenIn.safeTransferFrom(msg.sender, address(this), _amountIn);
        tokenOut.safeTransfer(msg.sender, amountOut);

        if (_tokenIn == address(token1)) {
            token1Balance += _amountIn;
            token2Balance -= amountOut;
        } else {
            token2Balance += _amountIn;
            token1Balance -= amountOut;
        }

        _recordTrade(_tokenIn, _amountIn);

        emit Swap(msg.sender, _tokenIn, _amountIn, address(tokenOut), amountOut);
    }

    function _recordTrade(address _token, uint256 _amount) internal {
        tokenTradeHistory[_token].push(Trade({
            amount: _amount,
            timestamp: block.timestamp
        }));

        emit TradeRecorded(_token, _amount, block.timestamp);
    }

    function getTotalVolume(address _token) external view returns (uint256) {
        uint256 totalVolume = 0;
        for (uint256 i = 0; i < tokenTradeHistory[_token].length; i++) {
            totalVolume += tokenTradeHistory[_token][i].amount;
        }
        return totalVolume;
    }

    function getRecentVolume(address _token) external view returns (uint256) {
        uint256 recentVolume = 0;
        uint256 timeWindow = 3 days;
        uint256 startTime = block.timestamp - timeWindow;

        for (uint256 i = tokenTradeHistory[_token].length; i > 0; i--) {
            Trade memory trade = tokenTradeHistory[_token][i - 1];
            if (trade.timestamp < startTime) {
                break;
            }
            recentVolume += trade.amount;
        }
        return recentVolume;
    }
}
