pragma solidity ^0.8.30;
interface IPriceContext {function openContext(bytes[] calldata proofs) external;function closeContext() external;}
interface IPriceContextHost {function priceContextPricing() external view returns(address);}

contract PriceContextDispatch {
    error PriceContextCallFailed();
    function withPriceSources(bytes[] calldata proofs,bytes calldata data) external payable returns(bytes memory result){
        if(data.length<4||bytes4(data[:4])==this.withPriceSources.selector)revert PriceContextCallFailed();
        IPriceContext source=IPriceContext(IPriceContextHost(address(this)).priceContextPricing());
        source.openContext(proofs);bool ok;(ok,result)=address(this).delegatecall(data);
        if(!ok){assembly("memory-safe"){revert(add(result,32),mload(result))}}
        source.closeContext();
    }
}
