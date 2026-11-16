pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library AggregateRangeTree {
    struct Node {
        uint120 left;
        uint120 right;
        uint8 height;
        uint256 key;
        uint256 inventory;
        uint256 proceeds;
    }
    struct Book {
        uint256 root;
        uint256 next;
        mapping(uint256=>Node) nodes;
    }
    struct Frontier {
        uint256[257] ids;
        uint256[256] path;
        uint256 count;
        uint256 depth;
        uint256 inventory;
    }
    struct Batch {
        uint256[] keys;
        uint256[] amounts;
        uint256[] prior;
        uint256[] gains;
    }
    error InvalidTree();
    error InsufficientInventory();
    error MissingLevel();

    function _split(uint256 left,uint256 right,uint256 inventory,uint256 proceeds)
        private pure returns(uint256 li,uint256 ri,uint256 lp,uint256 rp) {
        uint256 basis=left+right;
        if(basis==0){
            if(inventory!=0||proceeds!=0)revert InvalidTree();
            return(0,0,0,0);
        }
        if(inventory>basis)revert InvalidTree();
        li=Math.mulDiv(left,inventory,basis);ri=inventory-li;
        lp=Math.mulDiv(left,proceeds,basis);rp=proceeds-lp;
    }
    function _push(Book storage b,uint256 id) private {
        Node storage n=b.nodes[id];
        if(n.left==0)return;
        Node storage l=b.nodes[n.left];Node storage r=b.nodes[n.right];
        if(n.inventory==l.inventory+r.inventory&&n.proceeds==0)return;
        (uint256 li,uint256 ri,uint256 lp,uint256 rp)=_split(l.inventory,r.inventory,n.inventory,n.proceeds);
        l.inventory=li;r.inventory=ri;l.proceeds+=lp;r.proceeds+=rp;n.proceeds=0;
    }
    function _newNode(Book storage b) private returns(uint120 id){
        uint256 next=++b.next;if(next>type(uint120).max)revert InvalidTree();return uint120(next);
    }
    function _newLeaf(Book storage b,uint256 key) private returns(uint256 id){id=_newNode(b);b.nodes[id].key=key;}
    function _seed(Book storage b,uint256[] memory keys,uint256[] memory amounts,uint256 start,uint256 end) private returns(uint120 id){
        id=_newNode(b);Node storage n=b.nodes[id];
        if(end-start==1){n.key=keys[start];n.inventory=amounts[start];return id;}
        uint256 middle=start+(end-start)/2;
        n.left=_seed(b,keys,amounts,start,middle);n.right=_seed(b,keys,amounts,middle,end);
        n.key=keys[middle];_refresh(b,id);
    }
    function seed(Book storage b,uint256[] memory keys,uint256[] memory amounts) internal {
        if(b.root!=0||keys.length!=amounts.length)revert InvalidTree();
        uint256 count;
        for(uint256 i;i<keys.length;i++){
            if(amounts[i]==0)continue;
            if(count!=0&&keys[i]<keys[count-1])revert InvalidTree();
            if(count!=0&&keys[i]==keys[count-1])amounts[count-1]+=amounts[i];
            else{keys[count]=keys[i];amounts[count++]=amounts[i];}
        }
        if(count!=0)b.root=_seed(b,keys,amounts,0,count);
    }
    function _join(Book storage b,uint120 pivot,uint120 left,uint120 right) private returns(uint120){
        uint256 lh=b.nodes[left].height;uint256 rh=b.nodes[right].height;
        if(lh>rh+1){
            _push(b,left);Node storage l=b.nodes[left];l.right=_join(b,pivot,l.right,right);
            return uint120(_balance(b,left));
        }
        if(rh>lh+1){
            _push(b,right);Node storage r=b.nodes[right];r.left=_join(b,pivot,left,r.left);
            return uint120(_balance(b,right));
        }
        Node storage p=b.nodes[pivot];p.left=left;p.right=right;_refresh(b,pivot);return pivot;
    }
    function _lowerBound(uint256[] memory keys,uint256 start,uint256 end,uint256 key) private pure returns(uint256){
        while(start<end){uint256 middle=start+(end-start)/2;if(keys[middle]<key)start=middle+1;else end=middle;}
        return start;
    }
    function _batch(Book storage b,uint120 id,Batch memory data,uint256 start,uint256 end) private returns(uint120){
        if(start==end)return id;
        Node storage n=b.nodes[id];uint256 middle=_lowerBound(data.keys,start,end,n.key);
        if(n.left!=0){
            _push(b,id);
            uint120 left=_batch(b,n.left,data,start,middle);uint120 right=_batch(b,n.right,data,middle,end);
            return _join(b,id,left,right);
        }
        uint256 rightStart=middle;
        if(middle<end&&data.keys[middle]==n.key){
            data.prior[middle]=n.inventory;data.gains[middle]=n.proceeds;n.inventory+=data.amounts[middle];n.proceeds=0;rightStart++;
        }
        uint120 result=id;
        if(start<middle){
            uint120 left=_seed(b,data.keys,data.amounts,start,middle);uint120 pivot=_newNode(b);b.nodes[pivot].key=n.key;
            result=_join(b,pivot,left,result);
        }
        if(rightStart<end){
            uint120 right=_seed(b,data.keys,data.amounts,rightStart,end);uint120 pivot=_newNode(b);b.nodes[pivot].key=data.keys[rightStart];
            result=_join(b,pivot,result,right);
        }
        return result;
    }
    function addBatch(Book storage b,uint256[] memory keys,uint256[] memory amounts) internal returns(uint256[] memory prior,uint256[] memory gains){
        uint256 length=keys.length;if(length!=amounts.length)revert InvalidTree();
        Batch memory data=Batch(new uint256[](length),new uint256[](length),new uint256[](length),new uint256[](length));
        uint256[] memory groups=new uint256[](length);uint256[] memory offsets=new uint256[](length);uint256 count;
        for(uint256 i;i<length;i++){
            if(amounts[i]==0)continue;
            if(count!=0&&keys[i]<data.keys[count-1])revert InvalidTree();
            if(count==0||keys[i]!=data.keys[count-1])data.keys[count++]=keys[i];
            uint256 group=count-1;groups[i]=group;offsets[i]=data.amounts[group];data.amounts[group]+=amounts[i];
        }
        if(count!=0){if(b.root==0)b.root=_seed(b,data.keys,data.amounts,0,count);else b.root=_batch(b,uint120(b.root),data,0,count);}
        prior=new uint256[](length);gains=new uint256[](length);
        for(uint256 i;i<length;i++)if(amounts[i]!=0){prior[i]=data.prior[groups[i]]+offsets[i];if(offsets[i]==0)gains[i]=data.gains[groups[i]];}
    }
    function _refresh(Book storage b,uint256 id) private {
        Node storage n=b.nodes[id];if(n.left==0)return;
        n.height=uint8(1+Math.max(b.nodes[n.left].height,b.nodes[n.right].height));
        n.inventory=b.nodes[n.left].inventory+b.nodes[n.right].inventory;
    }
    function _rotateLeft(Book storage b,uint256 id) private returns(uint256 top){
        _push(b,id);Node storage n=b.nodes[id];top=n.right;_push(b,top);Node storage r=b.nodes[top];
        n.right=r.left;r.left=uint120(id);_refresh(b,id);_refresh(b,top);
    }
    function _rotateRight(Book storage b,uint256 id) private returns(uint256 top){
        _push(b,id);Node storage n=b.nodes[id];top=n.left;_push(b,top);Node storage l=b.nodes[top];
        n.left=l.right;l.right=uint120(id);_refresh(b,id);_refresh(b,top);
    }
    function _balance(Book storage b,uint256 id) private returns(uint256){
        _refresh(b,id);Node storage n=b.nodes[id];uint256 lh=b.nodes[n.left].height;uint256 rh=b.nodes[n.right].height;
        if(lh>rh+1){
            Node storage l=b.nodes[n.left];
            if(b.nodes[l.right].height>b.nodes[l.left].height)n.left=uint120(_rotateLeft(b,n.left));
            return _rotateRight(b,id);
        }
        if(rh>lh+1){
            Node storage r=b.nodes[n.right];
            if(b.nodes[r.left].height>b.nodes[r.right].height)n.right=uint120(_rotateRight(b,n.right));
            return _rotateLeft(b,id);
        }
        return id;
    }
    function ensure(Book storage b,uint256 key) internal returns(uint256 leaf){
        if(b.root==0){leaf=_newLeaf(b,key);b.root=leaf;return leaf;}
        uint256 at=b.root;uint256[] memory path=new uint256[](uint256(b.nodes[at].height)+1);uint256 depth;
        while(b.nodes[at].left!=0){path[depth++]=at;_push(b,at);Node storage n=b.nodes[at];at=key>=n.key?n.right:n.left;}
        if(b.nodes[at].key==key)return at;
        leaf=_newLeaf(b,key);uint120 fork=_newNode(b);Node storage p=b.nodes[fork];
        p.key=Math.max(key,b.nodes[at].key);p.height=1;p.inventory=b.nodes[at].inventory;
        if(key>b.nodes[at].key){p.left=uint120(at);p.right=uint120(leaf);}else{p.left=uint120(leaf);p.right=uint120(at);}
        uint256 subtree=fork;
        while(depth!=0){
            uint256 parent=path[--depth];Node storage n=b.nodes[parent];
            if(key>=n.key)n.right=uint120(subtree);else n.left=uint120(subtree);
            subtree=_balance(b,parent);
        }
        b.root=subtree;
    }
    function touch(Book storage b,uint256 key) internal returns(uint256 id){
        id=b.root;if(id==0)revert MissingLevel();
        while(b.nodes[id].left!=0){_push(b,id);Node storage n=b.nodes[id];id=key>=n.key?n.right:n.left;}
        if(b.nodes[id].key!=key)revert MissingLevel();
    }
    function takeProceeds(Book storage b,uint256 key) internal returns(uint256 id,uint256 inventory,uint256 proceeds){
        id=touch(b,key);Node storage n=b.nodes[id];inventory=n.inventory;proceeds=n.proceeds;n.proceeds=0;
    }
    function add(Book storage b,uint256 key,uint256 amount) internal returns(uint256 inventory,uint256 proceeds){
        if(b.root==0){uint256 leaf=_newLeaf(b,key);b.nodes[leaf].inventory=amount;b.root=leaf;return(0,0);}
        uint256 at=b.root;uint256[] memory path=new uint256[](uint256(b.nodes[at].height)+1);uint256 depth;
        while(b.nodes[at].left!=0){path[depth++]=at;_push(b,at);Node storage n=b.nodes[at];at=key>=n.key?n.right:n.left;}
        if(b.nodes[at].key==key){
            Node storage existing=b.nodes[at];inventory=existing.inventory;proceeds=existing.proceeds;
            existing.inventory=inventory+amount;existing.proceeds=0;
            while(depth!=0)b.nodes[path[--depth]].inventory+=amount;
            return(inventory,proceeds);
        }
        uint256 leaf=_newLeaf(b,key);b.nodes[leaf].inventory=amount;
        uint120 fork=_newNode(b);Node storage p=b.nodes[fork];
        p.key=Math.max(key,b.nodes[at].key);p.height=1;p.inventory=b.nodes[at].inventory+amount;
        if(key>b.nodes[at].key){p.left=uint120(at);p.right=uint120(leaf);}else{p.left=uint120(leaf);p.right=uint120(at);}
        uint256 subtree=fork;bool balancing=true;
        while(depth!=0){
            uint256 parent=path[--depth];Node storage n=b.nodes[parent];
            if(key>=n.key){if(n.right!=subtree)n.right=uint120(subtree);}else if(n.left!=subtree)n.left=uint120(subtree);
            if(balancing){
                uint256 beforeHeight=n.height;subtree=_balance(b,parent);
                balancing=b.nodes[subtree].height!=beforeHeight;
            }else{n.inventory+=amount;subtree=parent;}
        }
        b.root=subtree;
    }
    function change(Book storage b,uint256 key,uint256 amount,bool increase) internal {
        uint256 id=b.root;if(id==0)revert MissingLevel();
        while(true){
            Node storage n=b.nodes[id];_push(b,id);
            if(increase)n.inventory+=amount;
            else{if(amount>n.inventory)revert InsufficientInventory();n.inventory-=amount;}
            if(n.left==0){if(n.key!=key)revert MissingLevel();break;}
            id=key>=n.key?n.right:n.left;
        }
    }
    function level(Book storage b,uint256 key) internal view returns(uint256 inventory,uint256 proceeds){
        uint256 id=b.root;if(id==0)revert MissingLevel();
        inventory=b.nodes[id].inventory;proceeds=b.nodes[id].proceeds;
        while(b.nodes[id].left!=0){
            Node storage n=b.nodes[id];Node storage l=b.nodes[n.left];Node storage r=b.nodes[n.right];
            (uint256 li,uint256 ri,uint256 lp,uint256 rp)=_split(l.inventory,r.inventory,inventory,proceeds);
            if(key>=n.key){id=n.right;inventory=ri;proceeds=r.proceeds+rp;}
            else{id=n.left;inventory=li;proceeds=l.proceeds+lp;}
        }
        if(b.nodes[id].key!=key)revert MissingLevel();
    }
    function available(Book storage b,uint256 threshold) internal view returns(uint256 total){
        uint256 id=b.root;if(id==0)return 0;
        uint256 inventory=b.nodes[id].inventory;
        while(true){
            Node storage n=b.nodes[id];
            if(n.left==0)return threshold>=n.key?total+inventory:total;
            Node storage l=b.nodes[n.left];Node storage r=b.nodes[n.right];
            (uint256 li,uint256 ri,,)=_split(l.inventory,r.inventory,inventory,0);
            if(threshold>=n.key){total+=li;id=n.right;inventory=ri;}
            else{id=n.left;inventory=li;}
        }
    }
    function _frontier(Book storage b,uint256 threshold) private returns(Frontier memory f){
        uint256 id=b.root;if(id==0)return f;
        while(true){
            Node storage n=b.nodes[id];
            if(n.left==0){if(threshold>=n.key&&n.inventory!=0){f.ids[f.count++]=id;f.inventory+=n.inventory;}break;}
            _push(b,id);f.path[f.depth++]=id;
            if(threshold>=n.key){
                if(b.nodes[n.left].inventory!=0){f.ids[f.count++]=n.left;f.inventory+=b.nodes[n.left].inventory;}
                id=n.right;
            }else id=n.left;
        }
    }
    function fill(Book storage b,uint256 threshold,uint256 consumed,uint256 proceeds) internal returns(uint256 visits){
        Frontier memory f=_frontier(b,threshold);
        if(consumed==0||consumed>f.inventory)revert InsufficientInventory();
        uint256 prefix;uint256 debited;uint256 credited;
        for(uint256 i;i<f.count;i++){
            Node storage n=b.nodes[f.ids[i]];prefix+=n.inventory;
            uint256 nextDebit=Math.mulDiv(consumed,prefix,f.inventory);
            uint256 nextCredit=Math.mulDiv(proceeds,prefix,f.inventory);
            n.inventory-=nextDebit-debited;n.proceeds+=nextCredit-credited;
            debited=nextDebit;credited=nextCredit;
        }
        if(debited!=consumed||credited!=proceeds)revert InvalidTree();
        for(uint256 i=f.depth;i>0;){--i;Node storage n=b.nodes[f.path[i]];n.inventory=b.nodes[n.left].inventory+b.nodes[n.right].inventory;}
        return f.count+f.depth;
    }
}
