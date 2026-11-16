pragma solidity ^0.8.30;
import {IPriceContext} from "./PriceContextDispatch.sol";

contract PriceContextQuery {
    IPriceContext public immutable pricing;
    bytes32 private immutable pricingHash;
    constructor(IPriceContext p){require(address(p).code.length!=0);pricing=p;pricingHash=address(p).codehash;}
    function query(bytes[] calldata proofs,address target,bytes calldata data) external returns(bytes memory result){
        require(address(pricing).codehash==pricingHash&&target.code.length!=0);
        pricing.openContext(proofs);bool ok;(ok,result)=target.staticcall(data);
        if(!ok){assembly("memory-safe"){revert(add(result,32),mload(result))}}
        pricing.closeContext();
    }
}
