pragma solidity ^0.8.30;
import {MainnetSharedAutomaticFeeProcessing} from "contracts/mainnet-v3/MainnetSharedAutomaticFeeProcessing.sol";
import {IFeeProcessingPolicy, IFeeETHConverter} from "contracts/mainnet-v3/MainnetFeeProcessing.sol";
import {PriceContextConsumer} from "cached/PriceContextConsumer.sol";
interface ICacheFeeRoute {function pricing() external view returns(address);}
contract CachedFeeProcessor is MainnetSharedAutomaticFeeProcessing,PriceContextConsumer {
    address private immutable sourcePricing;
    bytes32 private immutable sourcePricingHash;
    constructor(address[] memory collectors,IFeeProcessingPolicy p,IFeeETHConverter c,address keeper)
        MainnetSharedAutomaticFeeProcessing(collectors,p,c,keeper){
        if(address(p)!=address(c))revert InvalidConfiguration();
        address source=ICacheFeeRoute(address(p)).pricing();if(source.code.length==0)revert InvalidConfiguration();
        sourcePricing=source;sourcePricingHash=source.codehash;
    }
    function _contextPricing() internal view override returns(address){
        if(sourcePricing.codehash!=sourcePricingHash)revert InvalidConfiguration();return sourcePricing;
    }
}
