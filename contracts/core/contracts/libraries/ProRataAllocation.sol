pragma solidity ^0.8.30;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library ProRataAllocation {
    struct Source {bytes32 key;uint256 available;}
    error InvalidSources();error CapacityOverflow();
    function allocate(Source[] memory sources,uint256 requested)
        internal pure returns(uint256[] memory amounts,uint256 filled,uint256 unused){
        uint256 count=sources.length;
        uint256 total;
        for(uint256 i=0;i<count;i++){

            if(sources[i].key==bytes32(0)||(i!=0&&sources[i-1].key>=sources[i].key))revert InvalidSources();
            if(sources[i].available>type(uint256).max-total)revert CapacityOverflow();
            total+=sources[i].available;
        }
        amounts=new uint256[](count);filled=Math.min(requested,total);unused=requested-filled;
        if(filled==0)return(amounts,filled,unused);
        uint256[] memory remainder=new uint256[](count);
        uint256[] memory heap=new uint256[](count);
        uint256 allocated;
        for(uint256 i=0;i<count;i++){
            amounts[i]=Math.mulDiv(filled,sources[i].available,total);
            remainder[i]=mulmod(filled,sources[i].available,total);
            heap[i]=i;allocated+=amounts[i];
        }

        for(uint256 i=count/2;i>0;){--i;_sift(heap,remainder,i,count);}
        uint256 left=filled-allocated;
        for(uint256 unit=0;unit<left;unit++){
            uint256 best=heap[0];
            if(remainder[best]==0||amounts[best]>=sources[best].available)revert InvalidSources();
            ++amounts[best];uint256 remaining=count-unit-1;heap[0]=heap[remaining];
            if(remaining!=0)_sift(heap,remainder,0,remaining);
        }
    }
    function _better(uint256 a,uint256 b,uint256[] memory r) private pure returns(bool){
        return r[a]>r[b]||(r[a]==r[b]&&a<b);
    }
    function _sift(uint256[] memory heap,uint256[] memory r,uint256 root,uint256 size) private pure {
        while(root<size/2){
            uint256 child=root*2+1;
            if(child+1<size&&_better(heap[child+1],heap[child],r))++child;
            if(!_better(heap[child],heap[root],r))break;
            (heap[root],heap[child])=(heap[child],heap[root]);root=child;
        }
    }
}
