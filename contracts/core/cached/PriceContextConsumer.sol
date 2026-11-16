pragma solidity ^0.8.30;
import {PriceContextDispatch} from "./PriceContextDispatch.sol";

abstract contract PriceContextConsumer {
    error PriceContextCallFailed();
    address private immutable contextDispatcher=address(new PriceContextDispatch());
    function _contextPricing() internal view virtual returns(address);
    function priceContextPricing() external view returns(address){return _contextPricing();}
    function withPriceSources(bytes[] calldata,bytes calldata) external payable returns(bytes memory){
        (bool ok,bytes memory result)=contextDispatcher.delegatecall(msg.data);
        if(!ok){assembly("memory-safe"){revert(add(result,32),mload(result))}}

        assembly("memory-safe"){return(add(result,32),mload(result))}
    }
}
