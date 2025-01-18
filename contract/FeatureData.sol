// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract UserFeatureStorage {
    // 存储用户地址与特征哈希值的映射
    mapping(address => bytes32) private userFeatures;

    // 事件，用于记录特征数据的更新
    event FeatureUpdated(address indexed user, bytes32 featureHash);

    // 设置或更新用户特征数据
    function setFeatureData(bytes32 featureHash) external {
        userFeatures[msg.sender] = featureHash;
        emit FeatureUpdated(msg.sender, featureHash);
    }

    // 获取用户的特征数据
    function getFeatureData(address user) external view returns (bytes32) {
        return userFeatures[user];
    }
}
