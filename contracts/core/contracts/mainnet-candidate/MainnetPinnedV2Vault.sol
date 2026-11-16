pragma solidity ^0.8.30;
import {PinnedVaultAdmission} from "../PinnedVaultAdmission.sol";
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {PinnedReferencePrice} from "../reference/PinnedReferencePrice.sol";
import {V2ConversionVault} from "../V2ConversionVault.sol";
import {V2NativeQuoteAdapter} from "../adapters/V2NativeQuoteAdapter.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";

contract MainnetPinnedV2Vault is PinnedVaultAdmission,V2ConversionVault {
    address public immutable administrator;
    bytes32 private conversionCheckpoint;
    constructor(uint256 expectedMainnetChain,address admin,PinnedMarketPricing p,V2NativeQuoteAdapter adapter)
        PinnedVaultAdmission(p) V2ConversionVault(adapter) {
        V2NativeQuoteAdapter.Config memory c=adapter.configuration();
        if(block.chainid!=expectedMainnetChain || admin==address(0) || c.usdg!=p.usdg()
            || c.wrappedNative!=p.wrappedNative())revert E.InvalidRequest();
        administrator=admin;
    }
    function setPaused(bool value) external virtual nonReentrant {if(msg.sender!=administrator)revert Unauthorized();_setPaused(value);}
    function _conversionFeeBps() internal view virtual override returns(uint16){return _s().feeBps;}
    function _admitV2Conversion(address input,address output,bool,uint256 maxInput,uint256 outputLimit,uint256 deadline)
        internal view override returns(bool) {
        if(block.timestamp>deadline || maxInput==0 || outputLimit==0
            || !((input==address(0)&&output==_s().usdg)||(input==_s().usdg&&output==address(0))))return false;

        try quoteAdapter.quoteExactInput(input==address(0),maxInput) returns(uint256 available){return available>=outputLimit;}
        catch{return false;}
    }
    function _fingerprint(address base) internal view virtual returns(bytes32){
        return keccak256(abi.encode(base,_marketFingerprint(base,address(0)),_marketFingerprint(base,_s().usdg)));
    }
    function _marketFingerprint(address base,address quote) private view returns(bytes32){
        (address source,bytes32 codeHash)=pricing.bindings(pricing.key(base,quote));
        PinnedReferencePrice ref=PinnedReferencePrice(source);
        (P.Ratio memory rate,P.Ratio memory usd)=pricing.read(base,quote);
        (,uint256 updatedAt,uint80 round)=ref.read();
        return keccak256(abi.encode(source,codeHash,ref.source(),ref.sourceCodeHash(),rate,usd,updatedAt,round));
    }
    function _checkpointConversion(address base) internal override {conversionCheckpoint=_fingerprint(base);}
    function _validateCrossBuySettlement(E.DirectRequest calldata q,uint256,uint256) internal view override {
        if(conversionCheckpoint!=_fingerprint(q.baseToken))revert E.PriceNotAdmitted();
    }
    function _validateCrossSellSettlement(E.DirectRequest calldata q,uint256,uint256) internal view override {
        if(conversionCheckpoint!=_fingerprint(q.baseToken))revert E.PriceNotAdmitted();
    }
}
