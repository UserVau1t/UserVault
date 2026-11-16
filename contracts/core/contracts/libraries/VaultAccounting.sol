pragma solidity ^0.8.30;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library VaultAccounting {
    uint256 internal constant SHARE_SCALE = 1e18;

    uint256 internal constant INDEX_SCALE = 1e54;
    struct Epoch {
        uint256 inventory;
        uint256 shares;
        uint256 index;
        uint256 proceedsReceived;
        uint256 proceedsClaimed;
        uint256 inventoryReserve;
        bool closed;
    }
    struct Position {
        address owner;
        uint256 epochId;
        uint256 shares;
        uint256 checkpoint;
        uint256 accrued;
        uint256 fractionalAccrued;
        uint256 deposited;
        uint256 withdrawn;
        uint256 claimed;
    }
    error InvalidAmount();
    error ClosedEpoch();
    error InsufficientEntitlement();

    function join(Epoch storage e, Position storage p, address owner, uint256 epochId, uint256 amount) internal {
        if (e.closed) revert ClosedEpoch();
        if (amount == 0 || owner == address(0) || p.owner != address(0)) revert InvalidAmount();
        uint256 minted = e.shares == 0 ? amount * SHARE_SCALE : Math.mulDiv(amount, e.shares, e.inventory);
        if (minted == 0) revert InvalidAmount();
        p.owner=owner; p.epochId=epochId; p.shares=minted; p.checkpoint=e.index; p.deposited=amount;
        e.shares+=minted; e.inventory+=amount;
    }
    function fill(Epoch storage e, uint256 consumed, uint256 proceeds) internal {
        if (e.closed) revert ClosedEpoch();
        if (consumed==0 || proceeds==0 || consumed>e.inventory || e.shares==0) revert InvalidAmount();
        uint256 increment=Math.mulDiv(proceeds,INDEX_SCALE,e.shares);
        if (increment==0) revert InvalidAmount();

        e.index+=increment; e.proceedsReceived+=proceeds; e.inventory-=consumed;
        if(e.inventory==0)e.closed=true;
    }
    function remaining(Epoch storage e, Position storage p) internal view returns(uint256){
        return e.shares==0?0:Math.mulDiv(p.shares,e.inventory,e.shares);
    }
    function earned(Epoch storage e, Position storage p) internal view returns(uint256 whole,uint256 fraction){
        uint256 delta=e.index-p.checkpoint;
        whole=p.accrued+Math.mulDiv(p.shares,delta,INDEX_SCALE);
        fraction=p.fractionalAccrued+mulmod(p.shares,delta,INDEX_SCALE);
        whole+=fraction/INDEX_SCALE; fraction%=INDEX_SCALE;
    }
    function settle(Epoch storage e, Position storage p) internal {
        (p.accrued,p.fractionalAccrued)=earned(e,p);p.checkpoint=e.index;
    }
    function claim(Epoch storage e, Position storage p,uint256 gross) internal {
        if(gross==0)revert InvalidAmount();settle(e,p);
        if(gross>p.accrued)revert InsufficientEntitlement();
        p.accrued-=gross;p.claimed+=gross;e.proceedsClaimed+=gross;
        assert(e.proceedsClaimed<=e.proceedsReceived);
    }
    function withdraw(Epoch storage e,Position storage p,uint256 amount) internal returns(uint256 reserve){
        if(amount==0)revert InvalidAmount();
        if(amount>remaining(e,p))revert InsufficientEntitlement();
        settle(e,p);

        uint256 burned=amount==remaining(e,p)?p.shares:Math.mulDiv(amount,e.shares,e.inventory,Math.Rounding.Ceil);
        return burnInventory(e,p,burned,amount);
    }
    function exit(Epoch storage e,Position storage p) internal returns(uint256 amount,uint256 reserve){
        if(p.shares==0)revert InvalidAmount();
        amount=remaining(e,p);settle(e,p);
        reserve=burnInventory(e,p,p.shares,amount);
    }
    function burnInventory(Epoch storage e,Position storage p,uint256 burned,uint256 amount) private returns(uint256 reserve){

        uint256 debit=Math.mulDiv(burned,e.inventory,e.shares,Math.Rounding.Ceil);
        reserve=debit-amount;
        p.shares-=burned;e.shares-=burned;e.inventory-=debit;
        e.inventoryReserve+=reserve;p.withdrawn+=amount;
        if(e.inventory==0)e.closed=true;
    }
}
