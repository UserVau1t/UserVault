pragma solidity ^0.8.30;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";

interface IPinnedPriceSource {
    function base() external view returns(address);
    function quote() external view returns(address);
    function read() external view returns(P.Ratio memory,uint256,uint80);
}

contract PinnedReferencePrice is Ownable2Step {
    address public immutable base;
    address public immutable quote;
    uint256 public immutable configuredChainId;
    address public source;
    bytes32 public sourceCodeHash;
    uint256 public constant SOURCE_GAS=300000;
    error InvalidSource();
    error InvalidConfiguration();
    event SourceChanged(address indexed previous,address indexed current,bytes32 runtimeHash);

    constructor(address administrator,uint256 chainId,address base_,address quote_,address initialSource)
        Ownable(administrator) {
        if(chainId!=block.chainid || base_==quote_ || base_.code.length==0
            || (quote_!=address(0) && quote_.code.length==0))revert InvalidConfiguration();
        base=base_;quote=quote_;configuredChainId=chainId;
        _setSource(initialSource);
    }
    function setSource(address next) external onlyOwner { _setSource(next); }
    function _setSource(address next) private {
        if(block.chainid!=configuredChainId || next.code.length==0
            || IPinnedPriceSource(next).base()!=base || IPinnedPriceSource(next).quote()!=quote)
            revert InvalidConfiguration();
        address previous=source;
        source=next;sourceCodeHash=next.codehash;
        read();
        emit SourceChanged(previous,next,sourceCodeHash);
    }
    function read() public view returns(P.Ratio memory rate,uint256 feedUpdatedAt,uint80 roundId) {
        address target=source;
        if(block.chainid!=configuredChainId || target.codehash!=sourceCodeHash)revert InvalidSource();
        bytes memory payload=abi.encodeCall(IPinnedPriceSource.read,());
        uint256[4] memory result;bool ok;uint256 size;uint256 limit=SOURCE_GAS;
        assembly ("memory-safe") {
            ok:=staticcall(limit,target,add(payload,32),mload(payload),result,128)
            size:=returndatasize()
        }
        if(!ok || size!=128 || result[0]==0 || result[1]==0 || result[2]==0
            || result[2]>block.timestamp || result[3]==0 || result[3]>type(uint80).max)
            revert InvalidSource();

        return(P.Ratio(result[0],result[1]),result[2],uint80(result[3]));
    }
    function valueUsd(uint256 amount,bool roundUp) external view returns(uint256) {
        (P.Ratio memory rate,,)=read();return P.consideration(amount,rate,roundUp);
    }
    function atLeastUsd(uint256 amount,uint256 threshold) external view returns(bool) {
        (P.Ratio memory rate,,)=read();return P.atLeast(amount,rate,threshold);
    }
}
