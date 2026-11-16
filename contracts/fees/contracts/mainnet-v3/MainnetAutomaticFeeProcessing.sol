pragma solidity ^0.8.30;
import {MainnetBoundedFeeProcessing} from "./MainnetBoundedFeeProcessing.sol";
import {IFeeProcessingPolicy, IFeeETHConverter} from "./MainnetFeeProcessing.sol";

contract MainnetAutomaticFeeProcessing is MainnetBoundedFeeProcessing {
    address public immutable feeKeeper;
    uint256 public constant MAX_QUOTE_LIFETIME=120;
    bool private quotedCall;
    constructor(address[] memory collectors,IFeeProcessingPolicy p,IFeeETHConverter c,address keeper)
        MainnetBoundedFeeProcessing(collectors,p,c) {
        if(keeper==address(0)||keeper==address(this))revert InvalidConfiguration();
        feeKeeper=keeper;
    }
    function processQuoted(address asset,uint256 epoch,uint256 cursor,uint256 amount,uint256 minimumETH,uint256 deadline)
        external nonReentrant {
        if(msg.sender!=feeKeeper)revert Unauthorized();
        if(epoch!=currentEpoch[asset]||cursor!=processedInput[asset][epoch]||minimumETH==0
            ||deadline<block.timestamp||deadline>block.timestamp+MAX_QUOTE_LIFETIME)revert InvalidProcessing();
        quotedCall=true;
        _process(asset,amount,minimumETH,deadline,"");
        quotedCall=false;
    }
    function _checkBatch(address asset,uint256 amount,uint256 remaining,uint256 alreadyProcessed) internal view override {

        if(msg.sender!=feeKeeper||!quotedCall)revert Unauthorized();
        super._checkBatch(asset,amount,remaining,alreadyProcessed);
    }
}
