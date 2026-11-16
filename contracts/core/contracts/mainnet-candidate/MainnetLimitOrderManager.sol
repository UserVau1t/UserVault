pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LimitAccounting as L} from "../libraries/LimitAccounting.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";

contract MainnetLimitOrderManager is ReentrancyGuard {
    using L for L.Order;using SafeERC20 for IERC20;
    PinnedMarketPricing public immutable pricing;
    E public immutable vault;
    bytes32 private immutable pricingHash;bytes32 private immutable vaultHash;
    uint256 public immutable configuredChainId;
    uint16 public constant FEE_BPS=50;
    uint256 public nextOrder;
    mapping(uint256=>L.Order) private orders;
    mapping(address=>uint256) public liabilities;
    mapping(address=>uint256) public fees;
    error InvalidRequest();error Unauthorized();error AssetTransfer();error PriceChanged();
    event Opened(uint256 indexed id,address indexed owner,address indexed base,address quote,bool sell,uint256 amount,uint256 lower,uint256 upper,uint16 steps);
    event Filled(uint256 indexed id,uint16 indexed bucket,address indexed caller,bool viaVault,uint256 principal,uint256 proceeds);
    event Claimed(uint256 indexed id,uint256 gross,uint256 fee);
    event Withdrawn(uint256 indexed id,uint16 indexed bucket,uint256 amount);
    constructor(uint256 chain,PinnedMarketPricing p,E v){
        if(chain!=block.chainid||address(p).code.length==0||address(v).code.length==0)revert InvalidRequest();
        configuredChainId=chain;pricing=p;vault=v;pricingHash=address(p).codehash;vaultHash=address(v).codehash;
    }
    function _identity() private view {
        if(block.chainid!=configuredChainId||address(pricing).codehash!=pricingHash||address(vault).codehash!=vaultHash)revert InvalidRequest();
    }
    function create(address base,address quote,bool sell,uint256 amount,uint256 lower,uint256 upper,uint16 steps) external payable nonReentrant returns(uint256 id){
        _identity();
        if(base==address(0)||base==pricing.usdg()||base==pricing.wrappedNative()||base.code.length==0
            ||(quote!=address(0)&&quote!=pricing.usdg()))revert InvalidRequest();

        pricing.read(base,quote);
        id=++nextOrder;L.Order storage o=orders[id];
        o.open(msg.sender,base,quote,sell,IERC20Metadata(base).decimals(),amount,lower,upper,steps);
        address input=sell?base:quote;_collect(input,msg.sender,amount);liabilities[input]+=amount;_solvent(input);
        emit Opened(id,msg.sender,base,quote,sell,amount,lower,upper,steps);
    }
    function status(uint256 id) external view returns(address owner,uint256 remaining,uint256 executed,uint256 withdrawn,uint256 claimable,uint256 claimed,uint256 revision){
        L.Order storage o=orders[id];return(o.owner,o.remaining,o.executed,o.withdrawn,o.claimable,o.claimed,o.revision);
    }
    function orderMarket(uint256 id) external view returns(address base,address quote,bool sell,uint16 steps,uint256 remaining){
        L.Order storage o=orders[id];return(o.base,o.quote,o.sell,o.steps,o.remaining);
    }

    function eligibleLiquidity(uint256 id) external view returns(uint256[] memory amounts){
        L.Order storage o=orders[id];_identity();
        if(o.owner==address(0))revert InvalidRequest();
        (,P.Ratio memory usd)=pricing.read(o.base,o.quote);amounts=new uint256[](o.steps);
        for(uint16 i=0;i<o.steps;i++)if(o.eligible(i,usd))amounts[i]=o.available(i);
    }
    struct EligibleSource {uint256 id;uint16 bucket;uint8 kind;uint256 amount;}

    function eligibleGroup(address base,address quote,E.Side activeSide) external view
        returns(P.Ratio memory rate,P.Ratio memory usd,EligibleSource[] memory sources){
        _identity();if(nextOrder>64)revert InvalidRequest();
        (rate,usd)=pricing.read(base,quote);
        EligibleSource[] memory rows=new EligibleSource[](64);uint256 count;
        for(uint256 id=1;id<=nextOrder;id++){
            L.Order storage o=orders[id];
            if(o.base!=base||o.quote!=quote||o.remaining==0||o.sell!=(activeSide==E.Side.Buy))continue;
            for(uint16 i;i<o.steps;i++)if(o.eligible(i,usd)){
                uint256 amount=o.available(i);if(amount==0)continue;
                if(count==64)revert InvalidRequest();
                rows[count++]=EligibleSource(id,i,o.steps==1?1:2,amount);
            }
        }
        sources=new EligibleSource[](count);for(uint256 i;i<count;i++)sources[i]=rows[i];
    }
    function bucket(uint256 id,uint16 index) external view returns(uint256 level,uint256 amount,bool eligible){
        L.Order storage o=orders[id];level=o.level(index);amount=o.available(index);
        _identity();(,P.Ratio memory usd)=pricing.read(o.base,o.quote);eligible=o.eligible(index,usd);
    }
    function _price(L.Order storage o,uint16 index) private view returns(P.Ratio memory rate){
        _identity();P.Ratio memory usd;(rate,usd)=pricing.read(o.base,o.quote);
        if(!o.eligible(index,usd))revert L.Ineligible();
    }

    function executeDirect(uint256 id,uint16 index,uint256 budget,uint256 minOutput,uint256 deadline,address recipient)
        external payable nonReentrant returns(E.Result memory r){
        if(budget==0||block.timestamp>deadline||recipient==address(0)||recipient==address(this))revert InvalidRequest();
        L.Order storage o=orders[id];uint256 net;
        address input=o.sell?o.quote:o.base;address output=o.sell?o.base:o.quote;
        {
            P.Ratio memory rate=_price(o,index);(r,net)=_plan(o,index,budget,rate);
            if(net==0||r.netOutput==0||r.netOutput<minOutput)revert InvalidRequest();
            _collect(input,msg.sender,budget);

            P.Ratio memory afterRate=_price(o,index);if(afterRate.n!=rate.n||afterRate.d!=rate.d)revert PriceChanged();
        }
        o.fill(index,r.netOutput,net,false);liabilities[output]-=r.netOutput;liabilities[input]+=net;_recordLimitFee(input,r.grossInputUsed-net,_limitFeePayer(msg.sender));
        _send(output,recipient,r.netOutput);_send(input,msg.sender,r.inputRefund);_solvent(input);
        emit Filled(id,index,msg.sender,false,r.netOutput,net);
    }
    function _limitFeePayer(address caller) internal view virtual returns(address){return caller;}
    function _recordLimitFee(address asset,uint256 amount,address) internal virtual {fees[asset]+=amount;}
    function _beginVaultFeeExecution(address) internal virtual {}
    function _endVaultFeeExecution() internal virtual {}
    function _plan(L.Order storage o,uint16 index,uint256 budget,P.Ratio memory rate) private view returns(E.Result memory r,uint256 net){
        uint256 inventory=o.available(index);uint256 available=budget-Math.mulDiv(budget,FEE_BPS,10000);
        if(o.sell){r.netOutput=Math.min(inventory,P.consideration(available,P.Ratio(rate.d,rate.n),false));net=P.consideration(r.netOutput,rate,true);}
        else{net=P.atMost(available,rate,inventory)?available:P.consideration(inventory,P.Ratio(rate.d,rate.n),false);r.netOutput=P.consideration(net,rate,false);}
        if(net==0||r.netOutput==0)return(r,0);
        r.grossInputUsed=net==available?budget:Math.mulDiv(net-1,10000,10000-FEE_BPS)+1;r.inputRefund=budget-r.grossInputUsed;
    }

    function executeVault(uint256 id,uint16 index,uint256 budget,uint256 minOutput,uint256 deadline) external nonReentrant returns(E.Result memory r){
        L.Order storage o=orders[id];P.Ratio memory rate=_price(o,index);
        if(budget==0||budget>o.available(index)||minOutput==0||block.timestamp>deadline)revert InvalidRequest();
        address input=o.sell?o.base:o.quote;address output=o.sell?o.quote:o.base;
        uint256 beforeInput=_balance(input);uint256 beforeOutput=_balance(output);
        if(input!=address(0))IERC20(input).forceApprove(address(vault),budget);
        E.DirectRequest memory q=E.DirectRequest(configuredChainId,o.base,o.quote,input,o.sell?E.Side.Sell:E.Side.Buy,budget,1,minOutput,deadline,payable(address(this)),false);
        _beginVaultFeeExecution(o.owner);
        r=vault.executeDirect{value:input==address(0)?budget:0}(q,"","");
        _endVaultFeeExecution();
        if(input!=address(0))IERC20(input).forceApprove(address(vault),0);
        P.Ratio memory afterRate=_price(o,index);
        if(afterRate.n!=rate.n||afterRate.d!=rate.d)revert PriceChanged();
        if(r.grossInputUsed==0||r.grossInputUsed>budget||r.inputRefund!=budget-r.grossInputUsed||r.netOutput<minOutput
            ||beforeInput-_balance(input)!=r.grossInputUsed||_balance(output)-beforeOutput!=r.netOutput)revert AssetTransfer();

        o.fill(index,r.grossInputUsed,r.netOutput,true);liabilities[input]-=r.grossInputUsed;liabilities[output]+=r.netOutput;
        _solvent(input);_solvent(output);emit Filled(id,index,msg.sender,true,r.grossInputUsed,r.netOutput);
    }
    function claim(uint256 id,uint256 amount) external nonReentrant {
        L.Order storage o=orders[id];if(o.owner!=msg.sender)revert Unauthorized();
        uint256 fee=o.claim(amount,FEE_BPS);address asset=o.sell?o.quote:o.base;
        liabilities[asset]-=amount;_recordLimitFee(asset,fee,msg.sender);_send(asset,msg.sender,amount-fee);emit Claimed(id,amount,fee);
    }
    function withdraw(uint256 id,uint16 index,uint256 amount) external nonReentrant {
        L.Order storage o=orders[id];if(o.owner!=msg.sender)revert Unauthorized();o.withdraw(index,amount);
        address asset=o.sell?o.base:o.quote;liabilities[asset]-=amount;_send(asset,msg.sender,amount);emit Withdrawn(id,index,amount);
    }
    function _balance(address asset) private view returns(uint256){return asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));}
    function _collect(address asset,address from,uint256 amount) private {
        if(asset==address(0)){if(msg.value!=amount)revert AssetTransfer();}
        else{if(msg.value!=0)revert AssetTransfer();uint256 b=_balance(asset);IERC20(asset).safeTransferFrom(from,address(this),amount);if(_balance(asset)-b!=amount)revert AssetTransfer();}
    }
    function _send(address asset,address to,uint256 amount) private {
        if(amount!=0){if(asset==address(0)){(bool ok,)=payable(to).call{value:amount}("");if(!ok)revert AssetTransfer();}
        else{uint256 b=_balance(asset);uint256 r=IERC20(asset).balanceOf(to);IERC20(asset).safeTransfer(to,amount);if(b-_balance(asset)!=amount||IERC20(asset).balanceOf(to)-r!=amount)revert AssetTransfer();}}
        _solvent(asset);
    }
    function _solvent(address asset) private view {if(_balance(asset)<liabilities[asset]+fees[asset])revert AssetTransfer();}
    receive() external payable {if(msg.sender!=address(vault))revert Unauthorized();}
}
