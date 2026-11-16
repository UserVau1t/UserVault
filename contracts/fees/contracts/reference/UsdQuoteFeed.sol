pragma solidity ^0.8.30;

import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";

interface IUsdAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80,int256,uint256,uint256,uint80);
}

contract UsdQuoteFeed {
    address public immutable quoteAsset;
    uint8 public immutable quoteDecimals;
    IUsdAggregatorV3 public immutable feed;
    uint8 public immutable feedDecimals;
    bytes32 public immutable feedCodeHash;
    uint256 public immutable configuredChainId;
    uint256 public immutable maxAge;

    error InvalidConfiguration();
    error SourceChanged();
    error InvalidAnswer();
    error InvalidTimestamp();
    error StaleAnswer();

    constructor(uint256 chainId,address asset,uint8 assetDecimals,address source,
        bytes32 sourceCodeHash,uint8 expectedFeedDecimals,uint256 maximumAge) {
        if(chainId!=block.chainid || source.code.length==0 || maximumAge==0
            || source.codehash!=sourceCodeHash || assetDecimals>36 || expectedFeedDecimals>36
            || (asset==address(0) && assetDecimals!=18)) revert InvalidConfiguration();
        if(IUsdAggregatorV3(source).decimals()!=expectedFeedDecimals) revert InvalidConfiguration();
        configuredChainId=chainId;quoteAsset=asset;quoteDecimals=assetDecimals;
        feed=IUsdAggregatorV3(source);feedCodeHash=sourceCodeHash;
        feedDecimals=expectedFeedDecimals;maxAge=maximumAge;
    }

    function read() public view returns (P.Ratio memory rate,uint256 updatedAt,uint80 roundId) {
        if(block.chainid!=configuredChainId || address(feed).codehash!=feedCodeHash
            || feed.decimals()!=feedDecimals) revert SourceChanged();
        int256 answer;
        (roundId,answer,,updatedAt,)=feed.latestRoundData();

        if(roundId==0 || answer<=0) revert InvalidAnswer();
        if(updatedAt==0 || updatedAt>block.timestamp) revert InvalidTimestamp();
        if(block.timestamp-updatedAt>maxAge) revert StaleAnswer();
        rate=P.compose(P.ratio(uint256(answer),10**uint256(feedDecimals)),
            P.ratio(1e18,10**uint256(quoteDecimals)));
    }

    function valueUsd(uint256 rawAmount,bool roundUp) external view returns(uint256) {
        (P.Ratio memory rate,,)=read();
        return P.consideration(rawAmount,rate,roundUp);
    }

    function atLeastUsd(uint256 rawAmount,uint256 minimumUsd18) external view returns(bool) {
        (P.Ratio memory rate,,)=read();
        return P.atLeast(rawAmount,rate,minimumUsd18);
    }
}
