import {CachedTokenPricing} from "cached/CachedTokenPricing.sol";

pragma solidity ^0.8.30;
import {SharedTokenPricing} from "./SharedTokenPricing.sol";
import {SharedPoolReader} from "./SharedPoolReader.sol";
import {UsdQuoteFeed} from "./UsdQuoteFeed.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";

library SharedPricingFingerprint {
    error InvalidPricing();
    function compute(address target,address base,address usdg) internal view returns(bytes32) {
        SharedTokenPricing pricing=SharedTokenPricing(target);
        if(target.code.length==0||pricing.configuredChainId()!=block.chainid||pricing.usdg()!=usdg)revert InvalidPricing();

        bytes32 nativeState=_market(pricing,base,address(0));
        bytes32 usdState=_market(pricing,base,usdg);
        (bytes32 tokenHash,uint8 decimals,bytes32 admittedDigest,uint256 admittedAt)=pricing.tokens(base);
        return keccak256(abi.encode("UserVault.SharedPricingCheckpoint.v1",block.chainid,target,target.codehash,
            base,tokenHash,decimals,admittedDigest,admittedAt,nativeState,usdState,
            _feed(pricing.ethFeed()),_feed(pricing.usdgFeed())));
    }
    function _market(SharedTokenPricing pricing,address base,address quote) private view returns(bytes32) {
        (P.Ratio memory rate,P.Ratio memory usd)=pricing.read(base,quote);
        SharedTokenPricing.Selection memory s=pricing.selection(base,quote);
        if(!s.present)revert InvalidPricing();
        SharedPoolReader reader=pricing.reader();
        address origin=s.pool.quote;
        (,P.Ratio memory liquidity)=reader.inspect(base,s.pool,CachedTokenPricing(address(pricing)).sourceQuoteUsd(base));
        return keccak256(abi.encode(quote,address(reader),address(reader).codehash,s,rate,usd,liquidity));
    }
    function _feed(UsdQuoteFeed feed) private view returns(bytes32) {
        (P.Ratio memory rate,uint256 updatedAt,uint80 round)=feed.read();
        return keccak256(abi.encode(address(feed),address(feed).codehash,address(feed.feed()),feed.feedCodeHash(),rate,updatedAt,round));
    }
}
