// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ILMSubscribedPositions {
    function getApproved(uint256 id) external view returns(address);
    function subscriber(uint256 id) external view returns(address);
    function subscribe(uint256 id,address subscriber,bytes calldata data) external payable;
    function getPositionLiquidity(uint256 id) external view returns(uint128);
    function msgSender() external view returns(address);
    function ownerOf(uint256 id) external view returns(address);
    function isApprovedForAll(address owner,address operator) external view returns(bool);
}
interface ILMShareController {
    function walletPositionTerms() external pure returns(bool);
    function ledger() external view returns(LiquidityPositionLedger);
    function subscribePosition(uint256 id) external;
    function retireStrategy(uint256 id) external;
}

/// Uniswap grants this observer permission to subscribe. Its only outbound mutating PM call is subscribe.
contract LiquidityPositionLedger {
    error Unauthorized();
    error InvalidShare();
    ILMSubscribedPositions private constant pm=ILMSubscribedPositions(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    address public immutable gateway;
    address public immutable controller;
    struct Share {uint128 managed;uint128 total;}
    struct Fees {uint256 amount0;uint256 amount1;}
    mapping(uint256=>Share) private shares;
    mapping(uint256=>Fees) private outside;
    uint256 private enrolling;
    constructor(address gateway_,address controller_){gateway=gateway_;controller=controller_;}

    function attachWalletPosition(uint256 id) external {
        if(msg.sender!=controller)revert Unauthorized();
        if(pm.subscriber(id)==address(this))return;
        ILMShareController(controller).retireStrategy(id);
        _enroll(id,pm.getPositionLiquidity(id));
    }
    function enroll(uint256 id,uint128 minted) external {
        if(msg.sender!=gateway&&msg.sender!=controller)revert Unauthorized();
        _enroll(id,minted);
    }
    function _enroll(uint256 id,uint128 minted) private {
        if(id==0||minted==0||enrolling!=0||pm.subscriber(id)!=address(0)||pm.getPositionLiquidity(id)!=minted)revert InvalidShare();
        enrolling=id;
        if(pm.isApprovedForAll(pm.ownerOf(id),controller)||pm.getApproved(id)==controller)ILMShareController(controller).subscribePosition(id);
        else pm.subscribe(id,address(this),"");
        delete enrolling;
        shares[id]=Share(minted,minted);
    }
    function managedLiquidity(uint256 id) public view returns(uint128){
        return pm.subscriber(id)==address(this)?shares[id].managed:0;
    }
    function notifySubscribe(uint256 id,bytes calldata) external view {
        if(msg.sender!=address(pm)||enrolling!=id||id==0)revert Unauthorized();
    }
    function _detach(uint256 id) private {
        bool wasManaged=shares[id].managed!=0;
        delete shares[id];
        if(wasManaged&&pm.msgSender()!=controller)ILMShareController(controller).retireStrategy(id);
    }
    function notifyUnsubscribe(uint256 id) external {
        if(msg.sender!=address(pm))revert Unauthorized();
        _detach(id);
    }
    function notifyBurn(uint256 id,address,uint256,uint256,int256) external {
        if(msg.sender!=address(pm))revert Unauthorized();
        _detach(id);
    }
    function notifyModifyLiquidity(uint256 id,int256 change,int256 fees) external {
        if(msg.sender!=address(pm))revert Unauthorized();
        Share memory s=shares[id];
        bool viaManager=pm.msgSender()==controller;
        if(ILMShareController(controller).walletPositionTerms()){
            // The PM has already applied this delta when it notifies its subscriber.
            uint128 live=pm.getPositionLiquidity(id);
            if(live==0&&s.total!=0&&!viaManager)ILMShareController(controller).retireStrategy(id);
            shares[id]=Share(live,live);
            return;
        }
        if(viaManager&&s.managed<s.total&&fees!=0){
            uint256 f0=uint128(int128(fees>>128));uint256 f1=uint128(int128(fees));
            outside[id].amount0+=f0-f0*s.managed/s.total;
            outside[id].amount1+=f1-f1*s.managed/s.total;
        }
        if(change==0)return;
        if(change>0){
            uint128 added=uint128(uint256(change));
            s.total+=added;
            if(viaManager)s.managed+=added;
        }else{
            uint128 removed=uint128(uint256(-change));
            if(viaManager&&removed>s.managed)revert InvalidShare();
            s.total-=removed;
            if(viaManager)s.managed-=removed;
            else if(s.managed>s.total)s.managed=s.total;
        }
        if(!viaManager&&s.managed==0&&shares[id].managed!=0)ILMShareController(controller).retireStrategy(id);
        shares[id]=s;
    }
    function takeOutsideFees(uint256 id) external returns(uint256,uint256){
        if(msg.sender!=controller)revert Unauthorized();
        Fees memory f=outside[id];
        if(f.amount0!=0||f.amount1!=0)delete outside[id];
        return (f.amount0,f.amount1);
    }
}
