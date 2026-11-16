pragma solidity ^0.8.30;
import {SharedVault} from "../SharedVault.sol";
import {MainnetPinnedV2Vault} from "./MainnetPinnedV2Vault.sol";
import {GroupedPositionsVault} from "../GroupedPositionsVault.sol";
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {V2NativeQuoteAdapter} from "../adapters/V2NativeQuoteAdapter.sol";

contract MainnetGroupedV2Vault is MainnetPinnedV2Vault,GroupedPositionsVault {
    constructor(uint256 chain,address admin,PinnedMarketPricing pricing,V2NativeQuoteAdapter adapter)
        MainnetPinnedV2Vault(chain,admin,pricing,adapter) {}
    function _creditPosition(address owner,uint256 eid,uint256 amount) internal override(SharedVault,GroupedPositionsVault) returns(uint256){return GroupedPositionsVault._creditPosition(owner,eid,amount);}
    function _claimProceeds(uint256 id,uint256 gross) internal override(SharedVault,GroupedPositionsVault){GroupedPositionsVault._claimProceeds(id,gross);}
}
