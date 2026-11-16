pragma solidity ^0.8.30;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReferencePriceMath as P} from "./ReferencePriceMath.sol";

library LimitAccounting {
    uint16 internal constant MAX_STEPS=128;
    struct Order {
        address owner;address base;address quote;bool sell;uint8 decimals;
        uint16 steps;uint256 lower;uint256 upper;uint256 total;
        uint256 remaining;uint256 executed;uint256 withdrawn;
        uint256 claimable;uint256 prepaidClaimable;uint256 claimed;uint256 revision;
        mapping(uint16=>uint256) spent;
    }
    error InvalidOrder();error InvalidBucket();error Ineligible();error InvalidAmount();
    function open(Order storage o,address owner,address base,address quote,bool sell,uint8 decimals,
        uint256 amount,uint256 lower,uint256 upper,uint16 steps) internal {
        if(o.owner!=address(0)||owner==address(0)||amount==0||lower==0||upper<lower||steps==0||steps>MAX_STEPS
            ||amount<steps||decimals>36||(steps==1?lower!=upper:lower==upper))revert InvalidOrder();
        o.owner=owner;o.base=base;o.quote=quote;o.sell=sell;o.decimals=decimals;o.total=amount;o.remaining=amount;
        o.lower=lower;o.upper=upper;o.steps=steps;o.revision=1;
    }
    function level(Order storage o,uint16 bucket) internal view returns(uint256){
        if(o.owner==address(0)||bucket>=o.steps)revert InvalidBucket();
        return o.steps==1?o.lower:o.lower+Math.mulDiv(o.upper-o.lower,bucket,o.steps-1);
    }
    function available(Order storage o,uint16 bucket) internal view returns(uint256){
        level(o,bucket);
        uint256 allocation=o.total/o.steps+(bucket==o.steps-1?o.total%o.steps:0);
        return allocation-o.spent[bucket];
    }
    function eligible(Order storage o,uint16 bucket,P.Ratio memory usdPerBase) internal view returns(bool){
        uint256 boundary=level(o,bucket);
        return available(o,bucket)>0&&(o.sell?P.atLeast(10**o.decimals,usdPerBase,boundary):P.atMost(10**o.decimals,usdPerBase,boundary));
    }
    function fill(Order storage o,uint16 bucket,uint256 principal,uint256 output,bool feeAlreadyPaid) internal {
        if(principal==0||output==0||principal>available(o,bucket))revert InvalidAmount();
        o.spent[bucket]+=principal;o.remaining-=principal;o.executed+=principal;o.claimable+=output;
        if(feeAlreadyPaid)o.prepaidClaimable+=output;
        ++o.revision;
    }
    function withdraw(Order storage o,uint16 bucket,uint256 amount) internal {
        if(amount==0||amount>available(o,bucket))revert InvalidAmount();
        o.spent[bucket]+=amount;o.remaining-=amount;o.withdrawn+=amount;++o.revision;
    }
    function claim(Order storage o,uint256 amount,uint16 feeBps) internal returns(uint256 fee){
        if(amount==0||amount>o.claimable)revert InvalidAmount();
        uint256 prepaid=Math.min(amount,o.prepaidClaimable);o.prepaidClaimable-=prepaid;
        fee=Math.mulDiv(amount-prepaid,feeBps,10000);
        o.claimable-=amount;o.claimed+=amount;++o.revision;
    }
}
