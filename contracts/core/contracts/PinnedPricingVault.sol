pragma solidity ^0.8.30;
import {CrossBuyVault} from "./CrossBuyVault.sol";
import {PinnedMarketPricing} from "./reference/PinnedMarketPricing.sol";
import {ReferencePriceMath as P} from "./libraries/ReferencePriceMath.sol";
import {IUserVaultExecution as E} from "./interfaces/IUserVaultExecution.sol";

abstract contract PinnedPricingVault is CrossBuyVault {
    PinnedMarketPricing public immutable pricing;
    bytes32 private immutable pricingHash;
    constructor(PinnedMarketPricing pricing_) {
        if(address(pricing_).code.length==0 || pricing_.configuredChainId()!=block.chainid)revert E.InvalidRequest();
        pricing=pricing_;pricingHash=address(pricing_).codehash;

    }
    function _checkPricing() private view {
        if(address(pricing).codehash!=pricingHash)revert E.PriceNotAdmitted();
    }
    function _directReference(address base,address quote,bytes calldata hints) internal view override returns(P.Ratio memory rate){
        if(hints.length!=0)revert E.UnsupportedRoute();
        _checkPricing();(rate,)=pricing.read(base,quote);
    }
    function _meetsCreationMinimum(address base,address quote,Side side,uint256 amount) internal view override returns(bool){
        _checkPricing();return pricing.meetsMinimum(base,quote,side==Side.Sell,amount,20e18);
    }
    function _validateFill(uint256 id,uint256 consumed,uint256 proceeds) internal view override {
        _checkPricing();EpochInfo storage e=_s().epochs[id];Market storage m=_s().markets[e.market];
        (P.Ratio memory rate,)=pricing.read(m.base,m.quote);
        if(e.side==Side.Sell){if(proceeds!=P.consideration(consumed,rate,true))revert E.PriceNotAdmitted();}
        else if(consumed!=P.consideration(proceeds,rate,false))revert E.PriceNotAdmitted();
        _validatePinnedFillLimits(id,consumed,proceeds);
    }
    function _validatePinnedFillLimits(uint256 id,uint256 consumed,uint256 proceeds) internal view virtual;
}
