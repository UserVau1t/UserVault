pragma solidity ^0.8.30;
import {MainnetMarketLimitOrderManager as M} from "./MainnetMarketLimitOrderManager.sol";
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";
import {ProRataAllocation as A} from "../libraries/ProRataAllocation.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";

contract MainnetMarketLiquiditySnapshot {
    struct Source {bytes32 key;uint256 available;uint8 kind;uint256 id;uint16 bucket;}
    M public immutable limits;E public immutable vault;PinnedMarketPricing public immutable pricing;
    bytes32 private immutable limitHash;bytes32 private immutable vaultHash;bytes32 private immutable pricingHash;
    uint256 public immutable configuredChainId;
    error InvalidConfig();
    constructor(M m){
        if(address(m).code.length==0)revert InvalidConfig();
        limits=m;vault=m.vault();pricing=m.pricing();configuredChainId=m.configuredChainId();
        if(configuredChainId!=block.chainid)revert InvalidConfig();
        limitHash=address(m).codehash;vaultHash=address(vault).codehash;pricingHash=address(pricing).codehash;
    }
    function sourceKey(uint8 kind,address module,uint256 id,uint16 index) public pure returns(bytes32){
        return keccak256(abi.encode("UserVault.Liquidity.v1",kind,module,id,uint256(index)));
    }
    struct Page {
        P.Ratio rate;P.Ratio usd;Source[] sources;
        uint256 nextOrder;uint16 nextBucket;uint256 activeCount;uint256 visited;bool done;
        uint256 vaultEpoch;uint256 vaultInventory;
    }

    function snapshotPage(address base,address quote,E.Side activeSide,
        uint256 orderCursor,uint16 bucketCursor,uint16 maxVisits) external view returns(Page memory p){
        if(block.chainid!=configuredChainId||address(limits).codehash!=limitHash
            ||address(vault).codehash!=vaultHash||address(pricing).codehash!=pricingHash)revert InvalidConfig();
        M.EligiblePage memory part=limits.eligibleGroupPage(base,quote,activeSide,orderCursor,bucketCursor,maxVisits);
        p.rate=part.rate;p.usd=part.usd;p.nextOrder=part.nextOrder;p.nextBucket=part.nextBucket;
        p.activeCount=part.activeCount;p.visited=part.visited;p.done=part.done;
        (p.vaultEpoch,p.vaultInventory)=vault.availableLiquidity(base,quote,activeSide);
        bool first=orderCursor==0&&bucketCursor==0&&p.vaultInventory!=0;
        p.sources=new Source[](part.sources.length+(first?1:0));uint256 offset;
        if(first){p.sources[0]=Source(sourceKey(0,address(vault),p.vaultEpoch,0),p.vaultInventory,0,p.vaultEpoch,0);offset=1;}
        for(uint256 i;i<part.sources.length;i++){
            M.EligibleSource memory s=part.sources[i];
            p.sources[offset+i]=Source(sourceKey(s.kind,address(limits),s.id,s.bucket),s.amount,s.kind,s.id,s.bucket);
        }
    }
    function snapshot(address base,address quote,E.Side activeSide) public view returns(Source[] memory sources){
        (,,sources)=snapshotPriced(base,quote,activeSide);
    }
    function hasCounterparty(address base,address quote,E.Side side) external view returns(bool){
        address other=quote==address(0)?pricing.usdg():address(0);
        bool oppositeSell=side==E.Side.Buy;
        if(limits.activeOrderCount(base,quote,oppositeSell)!=0||limits.activeOrderCount(base,other,oppositeSell)!=0)return true;
        (,uint256 first)=vault.availableLiquidity(base,quote,side);
        if(first!=0)return true;
        (,uint256 second)=vault.availableLiquidity(base,other,side);
        return second!=0;
    }
    function totalAvailable(address base,address quote,E.Side side) external view returns(uint256 total){
        (,,Source[] memory sources)=snapshotPriced(base,quote,side);
        for(uint256 i;i<sources.length;i++)total+=sources[i].available;
    }
    function snapshotPriced(address base,address quote,E.Side activeSide) public view
        returns(P.Ratio memory rate,P.Ratio memory usd,Source[] memory sources){
        return snapshotScoped(base,quote,activeSide,true);
    }
    function snapshotScoped(address base,address quote,E.Side activeSide,bool includeCurrentPrice) public view
        returns(P.Ratio memory rate,P.Ratio memory usd,Source[] memory sources){
        if(block.chainid!=configuredChainId||address(limits).codehash!=limitHash
            ||address(vault).codehash!=vaultHash||address(pricing).codehash!=pricingHash)revert InvalidConfig();
        M.EligibleSource[] memory eligible;
        (rate,usd,eligible)=limits.eligibleGroup(base,quote,activeSide);
        uint256 epoch;uint256 inventory;
        if(includeCurrentPrice)(epoch,inventory)=vault.availableLiquidity(base,quote,activeSide);
        sources=new Source[](eligible.length+(inventory==0?0:1));uint256 count;
        if(inventory!=0)sources[count++]=Source(sourceKey(0,address(vault),epoch,0),inventory,0,epoch,0);
        for(uint256 i=0;i<eligible.length;i++){
            M.EligibleSource memory s=eligible[i];
            sources[count++]=Source(sourceKey(s.kind,address(limits),s.id,s.bucket),s.amount,s.kind,s.id,s.bucket);
        }

        for(uint256 i=count/2;i>0;){--i;_sift(sources,i,count);}
        for(uint256 size=count;size>1;){
            --size;(sources[0],sources[size])=(sources[size],sources[0]);_sift(sources,0,size);
        }
    }
    function creationFingerprint(address base,E.Side side) external view returns(bytes32){
        (P.Ratio memory r0,P.Ratio memory u0,Source[] memory s0)=snapshotPriced(base,address(0),side);
        (P.Ratio memory r1,P.Ratio memory u1,Source[] memory s1)=snapshotPriced(base,pricing.usdg(),side);
        return keccak256(abi.encode(r0,u0,s0,r1,u1,s1));
    }
    function _sift(Source[] memory rows,uint256 root,uint256 size) private pure {
        while(root<size/2){
            uint256 child=root*2+1;
            if(child+1<size&&rows[child+1].key>rows[child].key)++child;
            if(rows[root].key>=rows[child].key)break;
            (rows[root],rows[child])=(rows[child],rows[root]);root=child;
        }
    }
    function plan(address base,address quote,E.Side activeSide,uint256 requestedOutput) external view
        returns(Source[] memory sources,uint256[] memory amounts,uint256 filled,uint256 unused){
        sources=snapshot(base,quote,activeSide);A.Source[] memory weights=new A.Source[](sources.length);
        for(uint256 i=0;i<sources.length;i++)weights[i]=A.Source(sources[i].key,sources[i].available);
        (amounts,filled,unused)=A.allocate(weights,requestedOutput);
    }
}
