pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProRataAllocation as A} from "../libraries/ProRataAllocation.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";
import {MainnetLiquiditySnapshot as S} from "./MainnetLiquiditySnapshot.sol";

contract MainnetProRataExecution is ReentrancyGuard {
    using SafeERC20 for IERC20;
    struct Plan {
        S.Source[] sources;uint256[] allocated;uint256[] grossInputs;uint256[] outputs;
        P.Ratio rate;P.Ratio usd;uint256 grossInput;uint256 netInput;uint256 output;uint256 feeAdjustment;
    }
    S public immutable liquidity;
    bytes32 private immutable snapshotHash;
    uint16 public constant FEE_BPS=50;
    mapping(address=>uint256) public fees;
    error InvalidRequest();error BudgetTooSmall();error SettlementMismatch();error StateChanged();
    event Settled(address indexed caller,address indexed recipient,address indexed base,address quote,E.Side side,
        uint256 grossInput,uint256 output,uint256 refund,uint256 feeAdjustment);
    constructor(S snapshot){
        if(address(snapshot).code.length==0||snapshot.configuredChainId()!=block.chainid)revert InvalidRequest();
        liquidity=snapshot;snapshotHash=address(snapshot).codehash;
    }
    function _check(E.DirectRequest calldata q) private view {
        if(address(liquidity).codehash!=snapshotHash||q.chainId!=block.chainid||block.timestamp>q.deadline
            ||q.maxGrossInput==0||q.minGrossInputFilled>q.maxGrossInput||q.recipient==address(0)||q.recipient==address(this)
            ||q.allowCrossQuote||q.inputAsset!=(q.side==E.Side.Buy?q.canonicalQuote:q.baseToken)
            ||q.baseToken==address(0)||q.baseToken==liquidity.pricing().wrappedNative())revert InvalidRequest();
    }
    function _gross(uint256 net) private pure returns(uint256){return net==0?0:Math.mulDiv(net-1,10000,10000-FEE_BPS)+1;}
    function _size(uint256 wanted,uint256 inventory,E.Side side,P.Ratio memory rate)
        private pure returns(uint256 gross,uint256 net,uint256 output){
        if(wanted==0)return(0,0,0);
        if(side==E.Side.Buy){
            net=P.consideration(wanted,rate,true);
            output=Math.min(inventory,P.consideration(net,P.Ratio(rate.d,rate.n),false));
            net=P.consideration(output,rate,true);
        }else{
            net=P.consideration(wanted,P.Ratio(rate.d,rate.n),true);
            output=P.consideration(net,rate,false);
        }
        if(output<wanted||output>inventory||net==0)revert SettlementMismatch();
        gross=_gross(net);
    }
    function preview(E.DirectRequest calldata q,uint256 requestedOutput) external view returns(Plan memory){
        _check(q);return _plan(q,requestedOutput);
    }
    function _plan(E.DirectRequest calldata q,uint256 requestedOutput) private view returns(Plan memory p){
        (p.rate,p.usd,p.sources)=liquidity.snapshotPriced(q.baseToken,q.canonicalQuote,q.side);
        uint256 count=p.sources.length;A.Source[] memory weights=new A.Source[](count);
        for(uint256 i=0;i<count;i++){
            uint256 capacity=p.sources[i].available;

            if(q.side==E.Side.Sell)capacity=P.consideration(P.consideration(capacity,P.Ratio(p.rate.d,p.rate.n),false),p.rate,false);
            weights[i]=A.Source(p.sources[i].key,capacity);
        }
        (p.allocated,,)=A.allocate(weights,requestedOutput);
        p.grossInputs=new uint256[](count);p.outputs=new uint256[](count);uint256 sourceGross;
        for(uint256 i=0;i<count;i++){
            uint256 net;
            (p.grossInputs[i],net,p.outputs[i])=_size(p.allocated[i],p.sources[i].available,q.side,p.rate);
            p.netInput+=net;p.output+=p.outputs[i];sourceGross+=p.grossInputs[i];
        }
        p.grossInput=_gross(p.netInput);

        if(p.netInput!=0&&p.netInput==q.maxGrossInput-Math.mulDiv(q.maxGrossInput,FEE_BPS,10000))p.grossInput=q.maxGrossInput;
        if(p.grossInput>q.maxGrossInput)revert BudgetTooSmall();
        if(sourceGross>p.grossInput)revert SettlementMismatch();

        p.feeAdjustment=p.grossInput-sourceGross;
    }
    function executeDirect(E.DirectRequest calldata q,uint256 requestedOutput) external payable nonReentrant returns(E.Result memory r){
        (r,)=_execute(q,requestedOutput);
    }

    function executeWithPlan(E.DirectRequest calldata q,uint256 requestedOutput) external payable nonReentrant
        returns(E.Result memory r,Plan memory p){return _execute(q,requestedOutput);}
    function _execute(E.DirectRequest calldata q,uint256 requestedOutput) private returns(E.Result memory r,Plan memory p){
        _beginFeeExecution();_check(q);address output=q.side==E.Side.Buy?q.baseToken:q.canonicalQuote;
        uint256 inputBefore=_balance(q.inputAsset)-msg.value;
        _collect(q.inputAsset,q.maxGrossInput);
        uint256 outputBefore=_balance(output);

        p=_plan(q,requestedOutput);
        r=E.Result(p.grossInput,p.output,q.maxGrossInput-p.grossInput);
        if(r.grossInputUsed<q.minGrossInputFilled||r.netOutput<q.minNetOutput)revert InvalidRequest();
        for(uint256 i=0;i<p.sources.length;i++)if(p.grossInputs[i]!=0)_executeLeg(q,p,i,output);
        if(_balance(output)-outputBefore!=r.netOutput)revert SettlementMismatch();
        _recordCoordinatorFee(q.inputAsset,p.feeAdjustment);
        _send(output,q.recipient,r.netOutput);_send(q.inputAsset,msg.sender,r.inputRefund);
        if(_balance(q.inputAsset)!=inputBefore+p.feeAdjustment||_balance(output)!=outputBefore)revert SettlementMismatch();
        _verifyFinal(q,p);
        emit Settled(msg.sender,q.recipient,q.baseToken,q.canonicalQuote,q.side,r.grossInputUsed,r.netOutput,r.inputRefund,p.feeAdjustment);
        _endFeeExecution();
    }
    function _beginFeeExecution() internal virtual {}
    function _endFeeExecution() internal virtual {}
    function _recordCoordinatorFee(address asset,uint256 amount) internal virtual {fees[asset]+=amount;}
    function _executeLeg(E.DirectRequest calldata q,Plan memory p,uint256 index,address output) private {
        S.Source memory s=p.sources[index];
        address target=s.kind==0?address(liquidity.vault()):address(liquidity.limits());
        uint256 beforeInput=_balance(q.inputAsset);uint256 beforeOutput=_balance(output);
        if(q.inputAsset!=address(0))IERC20(q.inputAsset).forceApprove(target,p.grossInputs[index]);
        E.Result memory r;
        if(s.kind==0){
            E.DirectRequest memory leg=q;
            leg.maxGrossInput=p.grossInputs[index];leg.minGrossInputFilled=leg.maxGrossInput;
            leg.minNetOutput=p.outputs[index];leg.recipient=payable(address(this));
            r=liquidity.vault().executeDirect{value:q.inputAsset==address(0)?leg.maxGrossInput:0}(leg,"","");
        }else{
            r=liquidity.limits().executeDirect{value:q.inputAsset==address(0)?p.grossInputs[index]:0}
                (s.id,s.bucket,p.grossInputs[index],p.outputs[index],q.deadline,address(this));
        }
        if(q.inputAsset!=address(0))IERC20(q.inputAsset).forceApprove(target,0);
        if(r.grossInputUsed!=p.grossInputs[index]||r.netOutput!=p.outputs[index]||r.inputRefund!=0
            ||beforeInput-_balance(q.inputAsset)!=r.grossInputUsed||_balance(output)-beforeOutput!=r.netOutput)revert SettlementMismatch();
    }
    function _verifyFinal(E.DirectRequest calldata q,Plan memory p) private view {
        (P.Ratio memory rate,P.Ratio memory usd,S.Source[] memory current)=liquidity.snapshotPriced(q.baseToken,q.canonicalQuote,q.side);
        if(rate.n!=p.rate.n||rate.d!=p.rate.d||usd.n!=p.usd.n||usd.d!=p.usd.d)revert StateChanged();
        uint256 j;
        for(uint256 i=0;i<p.sources.length;i++){
            uint256 left=p.sources[i].available-p.outputs[i];if(left==0)continue;
            if(j==current.length||current[j].key!=p.sources[i].key||current[j].available!=left)revert StateChanged();
            ++j;
        }
        if(j!=current.length)revert StateChanged();
    }
    function _balance(address asset) private view returns(uint256){return asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));}
    function _collect(address asset,uint256 amount) private {
        if(asset==address(0)){if(msg.value!=amount)revert InvalidRequest();}
        else{if(msg.value!=0)revert InvalidRequest();uint256 before=_balance(asset);IERC20(asset).safeTransferFrom(msg.sender,address(this),amount);if(_balance(asset)-before!=amount)revert SettlementMismatch();}
    }
    function _send(address asset,address to,uint256 amount) private {
        if(amount==0)return;
        if(asset==address(0)){(bool ok,)=payable(to).call{value:amount}("");if(!ok)revert SettlementMismatch();}
        else{uint256 before=_balance(asset);uint256 received=IERC20(asset).balanceOf(to);IERC20(asset).safeTransfer(to,amount);
            if(before-_balance(asset)!=amount||IERC20(asset).balanceOf(to)-received!=amount)revert SettlementMismatch();}
    }
    receive() external payable {if(msg.sender!=address(liquidity.vault())&&msg.sender!=address(liquidity.limits()))revert InvalidRequest();}
}
