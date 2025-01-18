// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

interface ITokenMarket {
    function getTotalVolume(address _token) external view returns (uint256);
    function getRecentVolume(address _token) external view returns (uint256);
}

interface IDEX {
    function getTotalVolume(address _token) external view returns (uint256);
    function getRecentVolume(address _token) external view returns (uint256);
}

interface INFTMarket {
    function getTotalVolume(address _nft) external view returns (uint256);
    function getRecentVolume(address _nft) external view returns (uint256);
}

contract NFT is ERC721, Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    // 动物类型枚举
    enum AnimalType {
        RABBIT,     // 初始类型
        PANDA,      // 第二级
        TIGER,      // 第三级
        DRAGON      // 最高级
    }

    // 状态类型枚举
    enum StateType {
        SLEEPING,   // 睡觉状态
        SITTING,    // 坐状态
        STANDING    // 站立/腾飞状态（龙为腾飞）
    }

    // 动物状态的NFT信息结构
    struct AnimalStateNFTs {
        uint256 sleepingNFT;   // 睡觉状态NFT的tokenId
        uint256 sittingNFT;    // 坐状态NFT的tokenId
        uint256 standingNFT;   // 站立/腾飞状态NFT的tokenId
    }

    // 用户当前状态信息
    struct UserStatus {
        AnimalType currentAnimal;   // 当前动物类型
        StateType currentState;     // 当前状态
        uint256 weightedVolume;     // 近期加权交易量
    }

    // 状态阈值常量
    uint256 public constant SITTING_THRESHOLD = 10;   // 坐状态阈值
    uint256 public constant STANDING_THRESHOLD = 100; // 站立/腾飞状态阈值

    // 动物类型阈值映射
    mapping(AnimalType => uint256) public animalThresholds;

    // 用户地址 => 用户状态
    mapping(address => UserStatus) public userStatus;

    // 用户地址 => 动物类型 => 该动物所有状态的NFT信息
    mapping(address => mapping(AnimalType => AnimalStateNFTs)) public userAnimalNFTs;

    // NFT token ID => 其元数据URI
    mapping(uint256 => string) public tokenURIs;

    // 构造函数
    constructor() ERC721("Trading Animals NFT", "TANFT") Ownable(msg.sender)  {
        // 设置各动物类型的加权交易量阈值
        animalThresholds[AnimalType.RABBIT] = 0;      // 初始动物无门槛
        animalThresholds[AnimalType.PANDA] = 1000;    // 示例阈值
        animalThresholds[AnimalType.TIGER] = 5000;    // 示例阈值
        animalThresholds[AnimalType.DRAGON] = 10000;  // 示例阈值
    }

    // 铸造新的 NFT
    function mintNewNFT(address to, string memory uri) internal returns (uint256) {
        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();
        
        // 铸造 NFT
        _mint(to, newTokenId);
        
        // 存储 URI
        tokenURIs[newTokenId] = uri;
        
        return newTokenId;
    }

    // 更新用户状态
    function updateUserState(address user, StateType newState, string memory uri) internal {
        UserStatus storage status = userStatus[user];
        AnimalStateNFTs storage animalNFTs = userAnimalNFTs[user][status.currentAnimal];

        // 获取对应状态的 NFT ID
        uint256 targetNFTId = getStateNFTId(animalNFTs, newState);

        // 如果该状态没有 NFT，则铸造新的
        if (targetNFTId == 0) {
            targetNFTId = mintNewNFT(user, uri);
            setStateNFTId(animalNFTs, newState, targetNFTId);
        }

        // 更新用户状态
        status.currentState = newState;
    }

    // 更新用户加权交易量和状态
    function updateUserStatus(address user, uint256 newWeightedVolume, string memory uri) public onlyOwner {
        UserStatus storage status = userStatus[user];
        status.weightedVolume = newWeightedVolume;

        // 1. 检查并更新动物类型
        AnimalType newAnimalType = determineAnimalType(newWeightedVolume);
        if (newAnimalType != status.currentAnimal) {
            status.currentAnimal = newAnimalType;
            // 新动物类型时重置状态 NFT 记录
            userAnimalNFTs[user][newAnimalType] = AnimalStateNFTs(0, 0, 0);
        }

        // 2. 检查并更新状态
        StateType newState = determineState(newWeightedVolume);
        if (newState != status.currentState) {
            updateUserState(user, newState, uri);
        }
    }

    // 确定用户的动物类型
    function determineAnimalType(uint256 weightedVolume) public view returns (AnimalType) {
        if (weightedVolume >= animalThresholds[AnimalType.DRAGON]) {
            return AnimalType.DRAGON;
        } else if (weightedVolume >= animalThresholds[AnimalType.TIGER]) {
            return AnimalType.TIGER;
        } else if (weightedVolume >= animalThresholds[AnimalType.PANDA]) {
            return AnimalType.PANDA;
        } else {
            return AnimalType.RABBIT;
        }
    }

    // 获取用户当前的动物类型
    function getAnimalType(address user) external view returns (AnimalType) {
        return userStatus[user].currentAnimal;
    }

    // 确定用户的状态
    function determineState(uint256 weightedVolume) public pure returns (StateType) {
        if (weightedVolume >= STANDING_THRESHOLD) {
            return StateType.STANDING;
        } else if (weightedVolume >= SITTING_THRESHOLD) {
            return StateType.SITTING;
        } else {
            return StateType.SLEEPING;
        }
    }

    // 获取状态对应的 NFT ID
    function getStateNFTId(AnimalStateNFTs storage animalNFTs, StateType state) internal view returns (uint256) {
        if (state == StateType.SLEEPING) {
            return animalNFTs.sleepingNFT;
        } else if (state == StateType.SITTING) {
            return animalNFTs.sittingNFT;
        } else {
            return animalNFTs.standingNFT;
        }
    }

    // 设置状态对应的 NFT ID
    function setStateNFTId(AnimalStateNFTs storage animalNFTs, StateType state, uint256 tokenId) internal {
        if (state == StateType.SLEEPING) {
            animalNFTs.sleepingNFT = tokenId;
        } else if (state == StateType.SITTING) {
            animalNFTs.sittingNFT = tokenId;
        } else {
            animalNFTs.standingNFT = tokenId;
        }
    }

    // 覆盖 ERC721 的 tokenURI 函数
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "ERC721Metadata: URI query for nonexistent token");
        return tokenURIs[tokenId];
    }
}
