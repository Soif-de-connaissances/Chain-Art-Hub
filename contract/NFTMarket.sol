// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// 定义 NFT 接口
interface INFT {
    enum AnimalType { RABBIT, PANDA, TIGER, DRAGON }
    function getAnimalType(address user) external view returns (AnimalType);
}

contract NFTMarket is Ownable, ReentrancyGuard, ERC721Holder {
    struct NFTInfo {
        uint256 price;       // 固定价格（以代币单位表示）
        bool isListed;       // 是否已上市
        address seller;      // 出售者
    }

    struct Auction {
        address seller;      // 拍卖者
        uint256 startPrice;  // 起拍价格
        uint256 highestBid;  // 当前最高出价
        address highestBidder; // 当前最高出价者
        uint256 endTime;     // 拍卖结束时间
        bool isActive;       // 拍卖是否活跃
    }

    struct Trade {
        uint256 amount;     // 交易额
        uint256 timestamp;  // 交易时间
    }

    mapping(address => mapping(uint256 => NFTInfo)) public listedNFTs;
    mapping(address => mapping(uint256 => Auction)) public nftAuctions;
    mapping(address => Trade[]) public nftTradeHistory;

    // 动态手续费相关
    mapping(uint8 => uint256) public feeRates; // AnimalType => fee rate
    INFT public nftContract;
    
    address public feeCollector;
    IERC20 public acceptedToken;

    event NFTListed(address indexed nft, uint256 indexed tokenId, uint256 price, address seller);
    event NFTDelisted(address indexed nft, uint256 indexed tokenId);
    event NFTPurchased(address indexed buyer, address indexed nft, uint256 indexed tokenId, uint256 price, uint256 fee);
    event AuctionCreated(address indexed nft, uint256 indexed tokenId, uint256 startPrice, uint256 endTime, address seller);
    event BidPlaced(address indexed bidder, address indexed nft, uint256 indexed tokenId, uint256 amount);
    event AuctionEnded(address indexed nft, uint256 indexed tokenId, address winner, uint256 highestBid);
    event FeeRateUpdated(uint8 animalType, uint256 newRate);

    constructor(address _nftContract, IERC20 _acceptedToken) Ownable(msg.sender) {
        nftContract = INFT(_nftContract);
        acceptedToken = _acceptedToken;
        feeCollector = msg.sender;

        // 设置默认手续费率
        feeRates[uint8(INFT.AnimalType.RABBIT)] = 30;   // 0.3%
        feeRates[uint8(INFT.AnimalType.PANDA)] = 27;    // 0.27%
        feeRates[uint8(INFT.AnimalType.TIGER)] = 24;    // 0.24%
        feeRates[uint8(INFT.AnimalType.DRAGON)] = 21;   // 0.21%
    }

    // 更新手续费率
    function updateFeeRate(uint8 animalType, uint256 newRate) external onlyOwner {
        require(newRate <= 500, "Fee rate cannot exceed 5%");
        require(animalType <= uint8(INFT.AnimalType.DRAGON), "Invalid animal type");
        feeRates[animalType] = newRate;
        emit FeeRateUpdated(animalType, newRate);
    }

    function setFeeCollector(address _newCollector) external onlyOwner {
        require(_newCollector != address(0), "Invalid address");
        feeCollector = _newCollector;
    }

    function listNFT(address _nft, uint256 _tokenId, uint256 _price) external nonReentrant {
        require(_price > 0, "Price must be greater than 0");
        IERC721 nft = IERC721(_nft);
        require(nft.ownerOf(_tokenId) == msg.sender, "Not the owner");
        require(nft.isApprovedForAll(msg.sender, address(this)), "Not approved");

        listedNFTs[_nft][_tokenId] = NFTInfo({
            price: _price,
            isListed: true,
            seller: msg.sender
        });

        nft.safeTransferFrom(msg.sender, address(this), _tokenId);
        emit NFTListed(_nft, _tokenId, _price, msg.sender);
    }

    function delistNFT(address _nft, uint256 _tokenId) external nonReentrant {
        NFTInfo storage nftInfo = listedNFTs[_nft][_tokenId];
        require(nftInfo.isListed, "NFT not listed");
        require(nftInfo.seller == msg.sender, "Not the seller");

        IERC721(_nft).safeTransferFrom(address(this), msg.sender, _tokenId);
        delete listedNFTs[_nft][_tokenId];
        emit NFTDelisted(_nft, _tokenId);
    }

function buyNFT(address _nft, uint256 _tokenId) external nonReentrant {
    NFTInfo storage nftInfo = listedNFTs[_nft][_tokenId];
    require(nftInfo.isListed, "NFT not listed");

    // 获取买家的动物类型并计算动态手续费
    uint8 buyerAnimalType = uint8(nftContract.getAnimalType(msg.sender));
    uint256 feeRate = feeRates[buyerAnimalType];
    uint256 fee = (nftInfo.price * feeRate) / 10000;
    uint256 totalAmount = nftInfo.price + fee;

    // 先检查并转移总金额到合约
    acceptedToken.transferFrom(msg.sender, address(this), totalAmount);
    
    // 然后从合约分别转给收费方和卖家
    acceptedToken.transfer(feeCollector, fee);
    acceptedToken.transfer(nftInfo.seller, nftInfo.price);

    IERC721(_nft).safeTransferFrom(address(this), msg.sender, _tokenId);
    
    _recordTrade(_nft, nftInfo.price);
    delete listedNFTs[_nft][_tokenId];

    emit NFTPurchased(msg.sender, _nft, _tokenId, nftInfo.price, fee);
}

    function createAuction(address _nft, uint256 _tokenId, uint256 _startPrice, uint256 _duration) external nonReentrant {
        require(_startPrice > 0, "Invalid start price");
        require(_duration > 0, "Invalid duration");

        IERC721 nft = IERC721(_nft);
        require(nft.ownerOf(_tokenId) == msg.sender, "Not the owner");
        require(nft.isApprovedForAll(msg.sender, address(this)), "Not approved");

        nft.safeTransferFrom(msg.sender, address(this), _tokenId);

        nftAuctions[_nft][_tokenId] = Auction({
            seller: msg.sender,
            startPrice: _startPrice,
            highestBid: 0,
            highestBidder: address(0),
            endTime: block.timestamp + _duration,
            isActive: true
        });

        emit AuctionCreated(_nft, _tokenId, _startPrice, block.timestamp + _duration, msg.sender);
    }

    function placeBid(address _nft, uint256 _tokenId, uint256 _bidAmount) external nonReentrant {
        Auction storage auction = nftAuctions[_nft][_tokenId];
        require(auction.isActive, "Auction not active");
        require(block.timestamp < auction.endTime, "Auction ended");
        require(_bidAmount > auction.highestBid, "Bid too low");

        if (auction.highestBid > 0) {
            acceptedToken.transfer(auction.highestBidder, auction.highestBid);
        }

        acceptedToken.transferFrom(msg.sender, address(this), _bidAmount);

        auction.highestBid = _bidAmount;
        auction.highestBidder = msg.sender;

        emit BidPlaced(msg.sender, _nft, _tokenId, _bidAmount);
    }

    function endAuction(address _nft, uint256 _tokenId) external nonReentrant {
        Auction storage auction = nftAuctions[_nft][_tokenId];
        require(auction.isActive, "Auction not active");
        require(block.timestamp >= auction.endTime, "Auction not ended");

        auction.isActive = false;

        if (auction.highestBid > 0) {
            // 获取最高出价者的动物类型并计算动态手续费
            uint8 winnerAnimalType = uint8(nftContract.getAnimalType(auction.highestBidder));
            uint256 feeRate = feeRates[winnerAnimalType];
            uint256 fee = (auction.highestBid * feeRate) / 10000;
            uint256 sellerProceeds = auction.highestBid - fee;

            acceptedToken.transfer(feeCollector, fee);
            acceptedToken.transfer(auction.seller, sellerProceeds);

            IERC721(_nft).safeTransferFrom(address(this), auction.highestBidder, _tokenId);
            _recordTrade(_nft, auction.highestBid);

            emit AuctionEnded(_nft, _tokenId, auction.highestBidder, auction.highestBid);
        } else {
            IERC721(_nft).safeTransferFrom(address(this), auction.seller, _tokenId);
        }

        delete nftAuctions[_nft][_tokenId];
    }

    function _recordTrade(address _nft, uint256 _amount) internal {
        nftTradeHistory[_nft].push(Trade({
            amount: _amount,
            timestamp: block.timestamp
        }));
    }

    function getTotalVolume(address _nft) external view returns (uint256) {
        uint256 totalVolume = 0;
        for (uint256 i = 0; i < nftTradeHistory[_nft].length; i++) {
            totalVolume += nftTradeHistory[_nft][i].amount;
        }
        return totalVolume;
    }

    function getRecentVolume(address _nft) external view returns (uint256) {
        uint256 recentVolume = 0;
        uint256 cutoffTime = block.timestamp - 3 days;
        for (uint256 i = 0; i < nftTradeHistory[_nft].length; i++) {
            if (nftTradeHistory[_nft][i].timestamp >= cutoffTime) {
                recentVolume += nftTradeHistory[_nft][i].amount;
            }
        }
        return recentVolume;
    }
}
