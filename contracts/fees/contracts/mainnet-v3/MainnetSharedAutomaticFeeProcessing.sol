pragma solidity ^0.8.30;
import {MainnetAutomaticFeeProcessing} from "./MainnetAutomaticFeeProcessing.sol";
import {IFeeProcessingPolicy, IFeeETHConverter} from "./MainnetFeeProcessing.sol";
import {MainnetSharedFeeDistribution} from "./MainnetSharedFeeDistribution.sol";
import {MainnetSharedBurnAndClaim} from "./MainnetSharedBurnAndClaim.sol";

contract MainnetSharedAutomaticFeeProcessing is MainnetAutomaticFeeProcessing {
    constructor(address[] memory collectors,IFeeProcessingPolicy p,IFeeETHConverter c,address keeper)
        MainnetAutomaticFeeProcessing(collectors,p,c,keeper) {}
    function createDistribution(address,address) external pure override {revert InvalidConfiguration();}
    function recordFee(bytes32,address,address,uint256) external payable override returns(bytes32){revert InvalidFee();}
    function _fundAllocation(bytes32 key,address payer,uint256 amountETH) internal override {
        MainnetSharedFeeDistribution(address(distribution)).fundAttributedFee{value:amountETH}(key,payer,feeCashbackEligible[key]);
    }
    function bindSharedDistribution(MainnetSharedFeeDistribution funds) external {
        if(msg.sender!=installer||address(distribution)!=address(0)||address(funds).code.length==0
            ||funds.settlementSource()!=address(this)||funds.settlementSourceCodeHash()!=address(this).codehash)revert InvalidConfiguration();
        MainnetSharedBurnAndClaim burn=MainnetSharedBurnAndClaim(funds.controller());
        if(address(burn.treasury())!=address(funds)||burn.treasuryHash()!=address(funds).codehash
            ||funds.controllerHash()!=address(burn).codehash)revert InvalidConfiguration();
        distribution=funds;
    }
}
