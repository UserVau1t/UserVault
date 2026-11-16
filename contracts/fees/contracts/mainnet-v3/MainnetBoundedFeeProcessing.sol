pragma solidity ^0.8.30;
import {MainnetFeeProcessing, IFeeProcessingPolicy, IFeeETHConverter} from "./MainnetFeeProcessing.sol";

contract MainnetBoundedFeeProcessing is MainnetFeeProcessing {
    uint256 public constant MAX_BATCH_USD18=5e17;

    uint256 public constant MIN_NONFINAL_BATCH_USD18=49e16;
    constructor(address[] memory collectors,IFeeProcessingPolicy p,IFeeETHConverter c)
        MainnetFeeProcessing(collectors,p,c) {}
    function PROCESS_MIN_USD18() public pure override returns(uint256){return 0;}
    function processPartial(address asset,uint256 amount,uint256 minimumETH,uint256 deadline,bytes calldata route)
        external nonReentrant {
        _process(asset,amount,minimumETH,deadline,route);
    }
    function _checkBatch(address asset,uint256 amount,uint256 remaining,uint256 alreadyProcessed) internal view virtual override {
        uint256 value=policy.valueUsd(asset,amount);
        if((asset!=address(0)&&value==0)||value>MAX_BATCH_USD18)revert InvalidProcessing();

        if(amount<remaining&&value<MIN_NONFINAL_BATCH_USD18)revert InvalidProcessing();
    }
}
