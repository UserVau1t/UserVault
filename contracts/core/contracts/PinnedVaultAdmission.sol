pragma solidity ^0.8.30;
import {PinnedPricingVault} from "./PinnedPricingVault.sol";
import {PinnedMarketPricing} from "./reference/PinnedMarketPricing.sol";
import {ReferencePriceMath as P} from "./libraries/ReferencePriceMath.sol";
import {IUserVaultExecution as E} from "./interfaces/IUserVaultExecution.sol";

abstract contract PinnedVaultAdmission is PinnedPricingVault {
    uint256 public constant BASE_CAPACITY_USD18=100000e18;
    error CapacityExceeded();
    constructor(PinnedMarketPricing p) PinnedPricingVault(p) {}

    function _inventoryValue(address base,address quote) private view returns(uint256 amount,P.Ratio memory rate){
        uint256 id=_s().markets[marketId(base,quote)].activeEpoch;
        if(id==0 || _s().epochs[id].ledger.closed)return(0,P.Ratio(1,1));
        EpochInfo storage e=_s().epochs[id];amount=e.ledger.inventory;
        if(amount==0)return(0,P.Ratio(1,1));
        (,P.Ratio memory baseUsd)=pricing.read(base,quote);
        rate=e.side==Side.Sell?baseUsd:pricing.quoteUsd(quote);
    }

    function _capacity(address base,address quote,Side side,uint256 amount) private view {
        uint256[3] memory amounts;P.Ratio[3] memory rates;
        (amounts[0],rates[0])=_inventoryValue(base,address(0));
        (amounts[1],rates[1])=_inventoryValue(base,_s().usdg);
        amounts[2]=amount;
        (,P.Ratio memory usd)=pricing.read(base,quote);
        rates[2]=side==Side.Sell?usd:pricing.quoteUsd(quote);
        _checkCapacityAmounts(amounts,rates);
    }
    function _checkCapacityAmounts(uint256[3] memory amounts,P.Ratio[3] memory rates) internal view virtual {
        uint256 whole;uint256 fractionN;uint256 fractionD=1;
        for(uint256 i=0;i<3;i++){
            P.Ratio memory r=rates[i];
            if(!P.atMost(amounts[i],r,BASE_CAPACITY_USD18))revert CapacityExceeded();
            whole+=P.consideration(amounts[i],r,false);
            uint256 rem=mulmod(amounts[i],r.n,r.d);
            if(rem!=0){

                P.Ratio memory f=P.ratio(rem,r.d);
                uint256 common=_gcd(fractionD,f.d);
                uint256 a=f.d/common;uint256 b=fractionD/common;
                fractionN=fractionN*a+f.n*b;fractionD*=a;
                whole+=fractionN/fractionD;fractionN%=fractionD;
                if(fractionN==0)fractionD=1;
                else {common=_gcd(fractionN,fractionD);fractionN/=common;fractionD/=common;}
            }
            if(whole>BASE_CAPACITY_USD18)revert CapacityExceeded();
        }
        if(whole==BASE_CAPACITY_USD18 && fractionN!=0)revert CapacityExceeded();
    }
    function _gcd(uint256 a,uint256 b) private pure returns(uint256){while(b!=0){uint256 r=a%b;a=b;b=r;}return a;}
    function _admitDeposit(address base,address quote,Side side,uint256 amount) internal view override {
        if(!_meetsCreationMinimum(base,quote,side,amount))revert CreationBelowMinimum();
        _capacity(base,quote,side,amount);
    }
    function _validatePinnedFillLimits(uint256 id,uint256 consumed,uint256 proceeds) internal view override {
        EpochInfo storage e=_s().epochs[id];
        if(e.ledger.closed || consumed==0 || proceeds==0 || consumed>e.ledger.inventory)revert E.ExecutionLimit();
    }
    function _validateDirectExecution(E.DirectRequest memory q,uint256 id,uint256 netInput,uint256 output) internal view override {
        EpochInfo storage e=_s().epochs[id];
        if(e.market!=marketId(q.baseToken,q.canonicalQuote) || uint8(e.side)==uint8(q.side)
            || netInput==0 || output==0 || output>e.ledger.inventory)revert E.ExecutionLimit();
    }
    function _dustEligible(uint256,uint256) internal pure override returns(bool){return false;}
}
