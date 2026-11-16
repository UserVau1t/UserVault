pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VaultAccounting as A} from "./libraries/VaultAccounting.sol";

abstract contract SharedVault {
    using A for A.Epoch;
    using SafeERC20 for IERC20;
    enum Side { Buy, Sell }
    struct Market { address base; address quote; uint256 activeEpoch; }
    struct EpochInfo { bytes32 market; Side side; A.Epoch ledger; }

    struct VaultStorage {
        mapping(bytes32=>Market) markets;
        mapping(uint256=>EpochInfo) epochs;
        mapping(uint256=>A.Position) positions;
        mapping(address=>uint256) liabilities;
        mapping(address=>uint256) fees;
        uint256 nextEpoch;
        uint256 nextPosition;
        address usdg;
        uint256 lock;
        bool initialized;
        bool paused;
        uint16 feeBps;
    }
    bytes32 private constant STORAGE_SLOT=keccak256("uservault.sharedvault.accounting.v1");
    error Unauthorized();error InvalidMarket();error Paused();error AssetTransfer();error Reentrancy();error AlreadyInitialized();
    event PositionOpened(uint256 indexed positionId,address indexed owner,uint256 indexed epochId,uint256 amount);
    event EpochFilled(uint256 indexed epochId,uint256 inventoryUsed,uint256 proceeds);
    event Claimed(uint256 indexed positionId,uint256 gross,uint256 net,uint256 fee);
    event Withdrawn(uint256 indexed positionId,uint256 amount,uint256 retainedRoundingReserve);
    modifier nonReentrant(){VaultStorage storage s=_s();if(s.lock!=0)revert Reentrancy();s.lock=1;_;s.lock=0;}
    function _s() internal pure returns(VaultStorage storage s){bytes32 slot=STORAGE_SLOT;assembly ("memory-safe"){s.slot:=slot}}
    function _initializeAccounting(address usdg) internal {
        VaultStorage storage s=_s();if(s.initialized)revert AlreadyInitialized();
        if(usdg==address(0)||usdg.code.length==0)revert InvalidMarket();
        s.initialized=true;s.usdg=usdg;s.feeBps=50;
    }
    function marketId(address base,address quote) public pure returns(bytes32){return keccak256(abi.encode(base,quote));}
    function position(uint256 id) external view virtual returns(A.Position memory){return _s().positions[id];}
    function epoch(uint256 id) external view virtual returns(EpochInfo memory){return _s().epochs[id];}
    function accounted(address asset) external view virtual returns(uint256 liabilities,uint256 fees){return(_s().liabilities[asset],_s().fees[asset]);}
    function entitlement(uint256 id) public view virtual returns(uint256 inventory,uint256 proceeds){
        VaultStorage storage s=_s();A.Position storage p=s.positions[id];
        if(p.owner==address(0))return(0,0);A.Epoch storage e=s.epochs[p.epochId].ledger;
        inventory=e.remaining(p);(proceeds,)=e.earned(p);
    }
    function _assets(EpochInfo storage e) internal view returns(address inventory,address proceeds){
        Market storage m=_s().markets[e.market];return e.side==Side.Sell?(m.base,m.quote):(m.quote,m.base);
    }

    function _open(address owner,address base,address quote,Side side,uint256 amount) internal returns(uint256 id){
        VaultStorage storage s=_s();if(s.paused)revert Paused();
        if(!s.initialized||base==address(0)||base==s.usdg||base==quote||base.code.length==0||(quote!=address(0)&&quote!=s.usdg))revert InvalidMarket();
        _admitDeposit(base,quote,side,amount);
        bytes32 key=marketId(base,quote);Market storage m=s.markets[key];
        uint256 eid=m.activeEpoch;
        if(eid==0||s.epochs[eid].ledger.closed){eid=++s.nextEpoch;m.base=base;m.quote=quote;m.activeEpoch=eid;s.epochs[eid].market=key;s.epochs[eid].side=side;}
        else if(s.epochs[eid].side!=side)revert InvalidMarket();
        id=_creditPosition(owner,eid,amount);
        (address inventory,)=_assets(s.epochs[eid]);s.liabilities[inventory]+=amount;_solvent(inventory);
        emit PositionOpened(id,owner,eid,amount);
    }
    function _creditPosition(address owner,uint256 eid,uint256 amount) internal virtual returns(uint256 id){
        VaultStorage storage s=_s();id=++s.nextPosition;s.epochs[eid].ledger.join(s.positions[id],owner,eid,amount);
    }
    function _claimProceeds(uint256 id,uint256 gross) internal virtual {
        VaultStorage storage s=_s();s.epochs[s.positions[id].epochId].ledger.claim(s.positions[id],gross);
    }
    function _recordFill(uint256 eid,uint256 consumed,uint256 proceeds) internal {
        VaultStorage storage s=_s();if(s.paused)revert Paused();EpochInfo storage e=s.epochs[eid];
        _validateFill(eid,consumed,proceeds);
        e.ledger.fill(consumed,proceeds);(address input,address output)=_assets(e);
        s.liabilities[input]-=consumed;s.liabilities[output]+=proceeds;_solvent(output);
        emit EpochFilled(eid,consumed,proceeds);
    }
    function _feePayer(address caller) internal view virtual returns(address){return caller;}
    function _recordProtocolFee(address asset,uint256 amount,address) internal virtual {_s().fees[asset]+=amount;}
    function claim(uint256 id,uint256 gross) public virtual nonReentrant {
        VaultStorage storage s=_s();A.Position storage p=s.positions[id];if(p.owner!=msg.sender)revert Unauthorized();
        EpochInfo storage e=s.epochs[p.epochId];_claimProceeds(id,gross);
        (,address asset)=_assets(e);uint256 fee=Math.mulDiv(gross,s.feeBps,10000);
        s.liabilities[asset]-=gross;_recordProtocolFee(asset,fee,msg.sender);_send(asset,msg.sender,gross-fee);
        emit Claimed(id,gross,gross-fee,fee);

    }
    function withdraw(uint256 id,uint256 amount) public virtual nonReentrant {if(_s().positions[id].owner!=msg.sender)revert Unauthorized();_withdraw(id,amount);}

    function withdrawAll(uint256 id) public virtual nonReentrant {
        VaultStorage storage s=_s();A.Position storage p=s.positions[id];
        if(p.owner!=msg.sender)revert Unauthorized();
        EpochInfo storage e=s.epochs[p.epochId];
        (uint256 amount,uint256 reserve)=e.ledger.exit(p);
        (address asset,)=_assets(e);s.liabilities[asset]-=amount;
        _send(asset,p.owner,amount);emit Withdrawn(id,amount,reserve);
    }
    function _withdraw(uint256 id,uint256 amount) private {
        VaultStorage storage s=_s();A.Position storage p=s.positions[id];EpochInfo storage e=s.epochs[p.epochId];
        uint256 reserve=e.ledger.withdraw(p,amount);(address asset,)=_assets(e);
        s.liabilities[asset]-=amount;_send(asset,p.owner,amount);emit Withdrawn(id,amount,reserve);
    }
    function dustEligible(uint256 id,uint256 amount) external view virtual returns(bool){return _dustEligible(id,amount);}
    function _collect(address asset,address from,uint256 amount) internal {
        if(asset==address(0)){if(msg.value!=amount)revert AssetTransfer();}
        else{if(msg.value!=0)revert AssetTransfer();uint256 beforeBalance=IERC20(asset).balanceOf(address(this));IERC20(asset).safeTransferFrom(from,address(this),amount);if(IERC20(asset).balanceOf(address(this))-beforeBalance!=amount)revert AssetTransfer();}
    }
    function _send(address asset,address to,uint256 amount) internal {
        if(amount==0)return;
        if(asset==address(0)){(bool ok,)=payable(to).call{value:amount}("");if(!ok)revert AssetTransfer();}
        else {
            uint256 beforeBalance=IERC20(asset).balanceOf(address(this));
            uint256 recipientBefore=IERC20(asset).balanceOf(to);
            IERC20(asset).safeTransfer(to,amount);
            if(beforeBalance-IERC20(asset).balanceOf(address(this))!=amount || IERC20(asset).balanceOf(to)-recipientBefore!=amount)revert AssetTransfer();
        }
        _solvent(asset);
    }
    function _solvent(address asset) internal view {
        uint256 balance=asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));
        if(balance<_s().liabilities[asset]+_s().fees[asset])revert AssetTransfer();
    }
    function _setFee(uint16 bps) internal {require(bps>=20&&bps<=100,"fee bounds");_s().feeBps=bps;}
    function _setPaused(bool paused) internal {_s().paused=paused;}
    function _admitDeposit(address base,address quote,Side side,uint256 amount) internal view virtual;
    function _validateFill(uint256 epochId,uint256 consumed,uint256 proceeds) internal view virtual;
    function _dustEligible(uint256 positionId,uint256 remaining) internal view virtual returns(bool);
}
