import {PriceContextConsumer} from "cached/PriceContextConsumer.sol";

pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeAttributedCollector} from "./FeeAttribution.sol";
import {MainnetMarketLimitOrderManager} from "./MainnetMarketLimitOrderManager.sol";
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";

contract FeeAwareMarketLimitManager is MainnetMarketLimitOrderManager,FeeAttributedCollector,PriceContextConsumer {
 function _contextPricing() internal view override returns(address){return address(pricing); }
    constructor(uint256 chain,PinnedMarketPricing pricing,E vault,address executionModule) MainnetMarketLimitOrderManager(chain,pricing,vault,executionModule){}
    function _limitFeePayer(address caller) internal view override returns(address){return _resolveFeePayer(caller);}
    function _recordLimitFee(address asset,uint256 amount,address payer) internal override {
        super._recordLimitFee(asset,amount,payer);_capturePaidFee(payer,asset,amount);
    }
    function _beginVaultFeeExecution(address owner) internal override {_enterFeePayer(owner);}
    function _endVaultFeeExecution() internal override {_leaveFeePayer();}
    function exportFee(uint256 id) external nonReentrant {_exportPaidFee(id);}
    function _debitProtocolFee(address asset,uint256 amount) internal override {fees[asset]-=amount;}
    function _checkFeeSolvency(address asset) internal view override {
        uint256 balance=asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));
        if(balance<liabilities[asset]+fees[asset])revert FeeAttributionError();
    }
}
