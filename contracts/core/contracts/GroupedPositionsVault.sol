pragma solidity ^0.8.30;
import {SharedVault} from "./SharedVault.sol";
import {VaultAccounting as A} from "./libraries/VaultAccounting.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract GroupedPositionsVault is SharedVault {
    using A for A.Epoch;
    struct Amount { uint256 whole; uint256 fraction; }
    struct Carry { Amount incoming; Amount outgoing; }
    struct GroupStorage {
        mapping(bytes32=>uint256) ids;
        mapping(uint256=>Carry) carry;
    }
    bytes32 private constant GROUP_SLOT=keccak256("uservault.groupedpositions.v1");
    function _groups() internal pure returns(GroupStorage storage g){bytes32 slot=GROUP_SLOT;assembly ("memory-safe"){g.slot:=slot}}
    function _idKey(address owner,bytes32 market,Side side) internal pure returns(bytes32){return keccak256(abi.encode(owner,market,side));}

    function epochCarry(uint256 eid) external view virtual returns(uint256 incoming,uint256 incomingFraction,uint256 outgoing,uint256 outgoingFraction){
        Carry storage c=_groups().carry[eid];return(c.incoming.whole,c.incoming.fraction,c.outgoing.whole,c.outgoing.fraction);
    }
    function _add(Amount storage a,uint256 whole,uint256 fraction) private {
        uint256 sum=a.fraction+fraction;
        a.whole+=whole+sum/A.INDEX_SCALE;a.fraction=sum%A.INDEX_SCALE;
    }
    function _checkEpoch(uint256 eid) private view {
        A.Epoch storage e=_s().epochs[eid].ledger;Carry storage c=_groups().carry[eid];
        uint256 available=e.proceedsReceived+c.incoming.whole;
        uint256 spent=e.proceedsClaimed+c.outgoing.whole;
        assert(spent<available||(spent==available&&c.outgoing.fraction<=c.incoming.fraction));
    }
    function _creditPosition(address owner,uint256 eid,uint256 amount) internal virtual override returns(uint256 id){
        VaultStorage storage s=_s();EpochInfo storage target=s.epochs[eid];GroupStorage storage g=_groups();
        bytes32 key=_idKey(owner,target.market,target.side);id=g.ids[key];
        if(id==0){
            id=super._creditPosition(owner,eid,amount);g.ids[key]=id;return id;
        }
        A.Position storage p=s.positions[id];
        if(p.epochId!=eid){
            uint256 previous=p.epochId;EpochInfo storage old=s.epochs[previous];

            assert(old.ledger.closed&&old.ledger.inventory==0);
            old.ledger.settle(p);

            _add(g.carry[previous].outgoing,p.accrued,p.fractionalAccrued);
            _add(g.carry[eid].incoming,p.accrued,p.fractionalAccrued);
            old.ledger.shares-=p.shares;p.shares=0;
            p.epochId=eid;p.checkpoint=target.ledger.index;
            _checkEpoch(previous);
        }
        A.Epoch storage e=target.ledger;

        e.settle(p);
        uint256 minted=e.shares==0?amount*A.SHARE_SCALE:Math.mulDiv(amount,e.shares,e.inventory);
        if(minted==0)revert A.InvalidAmount();
        p.shares+=minted;p.deposited+=amount;e.shares+=minted;e.inventory+=amount;

    }
    function _claimProceeds(uint256 id,uint256 gross) internal virtual override {
        VaultStorage storage s=_s();A.Position storage p=s.positions[id];A.Epoch storage e=s.epochs[p.epochId].ledger;
        if(gross==0)revert A.InvalidAmount();
        e.settle(p);if(gross>p.accrued)revert A.InsufficientEntitlement();
        p.accrued-=gross;p.claimed+=gross;e.proceedsClaimed+=gross;_checkEpoch(p.epochId);
    }
}
