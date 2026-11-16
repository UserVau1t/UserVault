pragma solidity ^0.8.30;
import {MainnetLimitOrderManager as M} from "./MainnetLimitOrderManager.sol";
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";
import {ProRataAllocation as A} from "../libraries/ProRataAllocation.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";

contract MainnetLiquiditySnapshot {
    struct Source {bytes32 key;uint256 available;uint8 kind;uint256 id;uint16 bucket;}
    M public immutable limits;E public immutable vault;PinnedMarketPricing public immutable pricing;
    bytes32 private immutable limitHash;bytes32 private immutable vaultHash;bytes32 private immutable pricingHash;
    uint256 public immutable configuredChainId;
    error InvalidConfig();error SnapshotTooLarge();
    constructor(M m){
        if(address(m).code.length==0)revert InvalidConfig();
        limits=m;vault=m.vault();pricing=m.pricing();configuredChainId=m.configuredChainId();
        if(configuredChainId!=block.chainid)revert InvalidConfig();
        limitHash=address(m).codehash;vaultHash=address(vault).codehash;pricingHash=address(pricing).codehash;
    }
    function sourceKey(uint8 kind,address module,uint256 id,uint16 index) public pure returns(bytes32){
        return keccak256(abi.encode("UserVault.Liquidity.v1",kind,module,id,uint256(index)));
    }
    function snapshot(address base,address quote,E.Side activeSide) public view returns(Source[] memory sources){
        (,,sources)=snapshotPriced(base,quote,activeSide);
    }
    function snapshotPriced(address base,address quote,E.Side activeSide) public view
        returns(P.Ratio memory rate,P.Ratio memory usd,Source[] memory sources){
        if(block.chainid!=configuredChainId||address(limits).codehash!=limitHash
            ||address(vault).codehash!=vaultHash||address(pricing).codehash!=pricingHash)revert InvalidConfig();
        uint256 last=limits.nextOrder();if(last>64)revert SnapshotTooLarge();
        M.EligibleSource[] memory eligible;
        (rate,usd,eligible)=limits.eligibleGroup(base,quote,activeSide);
        Source[] memory rows=new Source[](64);uint256 count;
        (uint256 epoch,uint256 inventory)=vault.availableLiquidity(base,quote,activeSide);
        if(inventory!=0)rows[count++]=Source(sourceKey(0,address(vault),epoch,0),inventory,0,epoch,0);
        for(uint256 i;i<eligible.length;i++){
            if(count==64)revert SnapshotTooLarge();M.EligibleSource memory s=eligible[i];
            rows[count++]=Source(sourceKey(s.kind,address(limits),s.id,s.bucket),s.amount,s.kind,s.id,s.bucket);
        }
        sources=new Source[](count);
        for(uint256 i=0;i<count;i++){
            Source memory value=rows[i];uint256 j=i;
            while(j>0&&sources[j-1].key>value.key){sources[j]=sources[j-1];--j;}
            sources[j]=value;
        }
    }
    function plan(address base,address quote,E.Side activeSide,uint256 requestedOutput) external view
        returns(Source[] memory sources,uint256[] memory amounts,uint256 filled,uint256 unused){
        sources=snapshot(base,quote,activeSide);A.Source[] memory weights=new A.Source[](sources.length);
        for(uint256 i=0;i<sources.length;i++)weights[i]=A.Source(sources[i].key,sources[i].available);
        (amounts,filled,unused)=A.allocate(weights,requestedOutput);
    }
}
