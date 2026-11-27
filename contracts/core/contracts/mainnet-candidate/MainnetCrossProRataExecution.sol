pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MainnetProRataExecution as C} from "./MainnetProRataExecution.sol";
import {MainnetLiquiditySnapshot as S} from "./MainnetLiquiditySnapshot.sol";
import {V2NativeQuoteAdapter as A} from "../adapters/V2NativeQuoteAdapter.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";

contract MainnetCrossProRataExecution is ReentrancyGuard {
    using SafeERC20 for IERC20;
    C public immutable coordinator;A public immutable adapter;
    bytes32 private immutable coordinatorHash;bytes32 private immutable adapterHash;
    address public immutable usdg;
    mapping(address=>uint256) public fees;
    struct Targets {uint256 first;uint256 second;uint256 minConverted;}
    struct State {C.Plan first;C.Plan second;bool crossed;}
    error InvalidRequest();error FirstNotExhausted();error SettlementMismatch();error StateChanged();
    event Settled(address indexed caller,address indexed base,address quote,E.Side side,uint256 grossInput,uint256 output,uint256 refund,uint256 conversionFee);
    constructor(C execution,A conversion){
        if(address(execution).code.length==0||address(conversion).code.length==0)revert InvalidRequest();
        A.Config memory c=conversion.configuration();
        if(c.chainId!=block.chainid||execution.liquidity().configuredChainId()!=block.chainid
            ||c.usdg!=execution.liquidity().pricing().usdg()||c.wrappedNative!=execution.liquidity().pricing().wrappedNative())revert InvalidRequest();

        (bool ok,bytes memory data)=address(execution.liquidity().vault()).staticcall(abi.encodeWithSignature("quoteAdapter()"));
        if(!ok||data.length!=32||abi.decode(data,(address))!=address(conversion))revert InvalidRequest();
        coordinator=execution;adapter=conversion;usdg=c.usdg;
        coordinatorHash=address(execution).codehash;adapterHash=address(conversion).codehash;
    }
    function executeDirect(E.DirectRequest calldata q,Targets calldata targets) external payable nonReentrant returns(E.Result memory r){
        _beginFeeExecution();
        if(q.chainId!=block.chainid||!q.allowCrossQuote||q.maxGrossInput==0||q.minGrossInputFilled>q.maxGrossInput
            ||q.deadline<block.timestamp||q.recipient==address(0)||q.recipient==address(this)
            ||(q.canonicalQuote!=address(0)&&q.canonicalQuote!=usdg)
            ||q.inputAsset!=(q.side==E.Side.Buy?q.canonicalQuote:q.baseToken)
            ||address(coordinator).codehash!=coordinatorHash||address(adapter).codehash!=adapterHash)revert InvalidRequest();
        address output=q.side==E.Side.Buy?q.baseToken:q.canonicalQuote;
        uint256 beforeIn=_balance(q.inputAsset)-msg.value;_collect(q.inputAsset,q.maxGrossInput);
        uint256 beforeOut=_balance(output);State memory s;
        E.DirectRequest memory leg=q;leg.allowCrossQuote=false;leg.minGrossInputFilled=0;leg.minNetOutput=0;leg.recipient=payable(address(this));
        E.Result memory first;
        (first,s.first)=_executeFresh(leg,targets.first);
        r=first;
        if(targets.second!=0){

            if(coordinator.liquidity().snapshot(q.baseToken,q.canonicalQuote,q.side).length!=0)revert FirstNotExhausted();
            if(r.inputRefund==0)revert InvalidRequest();
            s.crossed=true;
            leg.canonicalQuote=_other(q.canonicalQuote);leg.inputAsset=q.side==E.Side.Buy?leg.canonicalQuote:q.baseToken;
            if(q.side==E.Side.Buy)_buySecond(q,leg,targets,s,r);
            else _sellSecond(q,leg,targets,s,r);
        }
        if(r.grossInputUsed<q.minGrossInputFilled||r.netOutput<q.minNetOutput||r.inputRefund!=q.maxGrossInput-r.grossInputUsed
            ||_balance(output)-beforeOut!=r.netOutput)revert SettlementMismatch();
        _send(output,q.recipient,r.netOutput);_send(q.inputAsset,msg.sender,r.inputRefund);
        if(_balance(q.inputAsset)!=beforeIn||_balance(output)!=beforeOut)revert SettlementMismatch();
        _verify(q.baseToken,q.canonicalQuote,q.side,s.first);
        if(s.crossed)_verify(q.baseToken,_other(q.canonicalQuote),q.side,s.second);
        emit Settled(msg.sender,q.baseToken,q.canonicalQuote,q.side,r.grossInputUsed,r.netOutput,r.inputRefund,0);
        _endFeeExecution();
    }
    function _beginFeeExecution() internal virtual {}
    function _endFeeExecution() internal virtual {}
    function _recordCoordinatorFee(address asset,uint256 amount) internal virtual {fees[asset]+=amount;}
    function _buySecond(E.DirectRequest calldata q,E.DirectRequest memory leg,Targets calldata t,State memory s,E.Result memory r) private {
        uint256 budget=r.inputRefund;
        leg.maxGrossInput=adapter.quoteExactInput(q.canonicalQuote==address(0),budget);
        s.second=coordinator.preview(leg,t.second);
        if(s.second.grossInput==0||s.second.output==0)revert InvalidRequest();
        uint256 beforeIn=_balance(q.inputAsset);uint256 beforeOut=_balance(leg.inputAsset);
        if(q.inputAsset!=address(0))IERC20(q.inputAsset).forceApprove(address(adapter),budget);
        uint256 used=adapter.swapExactOutput{value:q.inputAsset==address(0)?budget:0}(q.inputAsset==address(0),s.second.grossInput,budget,q.deadline);
        if(q.inputAsset!=address(0))IERC20(q.inputAsset).forceApprove(address(adapter),0);
        if(beforeIn-_balance(q.inputAsset)!=used||_balance(leg.inputAsset)-beforeOut!=s.second.grossInput)revert SettlementMismatch();
        if(used==0||used>budget)revert SettlementMismatch();
        leg.maxGrossInput=s.second.grossInput;
        E.Result memory second=_execute(leg,t.second,s.second);
        if(second.inputRefund!=0||_balance(leg.inputAsset)!=beforeOut)revert SettlementMismatch();
        r.grossInputUsed+=used;r.inputRefund-=used;r.netOutput+=second.netOutput;
    }
    function _sellSecond(E.DirectRequest calldata q,E.DirectRequest memory leg,Targets calldata t,State memory s,E.Result memory r) private {
        leg.maxGrossInput=r.inputRefund;if(t.minConverted==0)revert InvalidRequest();
        uint256 beforeOther=_balance(leg.canonicalQuote);
        E.Result memory second;
        (second,s.second)=_executeFresh(leg,t.second);
        if(s.second.grossInput==0||s.second.output==0)revert InvalidRequest();
        uint256 beforeOut=_balance(q.canonicalQuote);

        uint256 quoted=adapter.quoteExactInput(leg.canonicalQuote==address(0),second.netOutput);
        if(quoted<t.minConverted)revert InvalidRequest();
        if(leg.canonicalQuote!=address(0))IERC20(leg.canonicalQuote).forceApprove(address(adapter),second.netOutput);
        uint256 converted=adapter.swapExactInput{value:leg.canonicalQuote==address(0)?second.netOutput:0}(leg.canonicalQuote==address(0),second.netOutput,quoted,q.deadline);
        if(leg.canonicalQuote!=address(0))IERC20(leg.canonicalQuote).forceApprove(address(adapter),0);
        if(_balance(leg.canonicalQuote)!=beforeOther||_balance(q.canonicalQuote)-beforeOut!=converted)revert SettlementMismatch();
        r.grossInputUsed+=second.grossInputUsed;r.inputRefund=second.inputRefund;r.netOutput+=converted;
    }
    function _execute(E.DirectRequest memory q,uint256 target,C.Plan memory p) private returns(E.Result memory r){
        if(p.grossInput==0)return E.Result(0,0,q.maxGrossInput);
        uint256 beforeIn=_balance(q.inputAsset);address output=q.side==E.Side.Buy?q.baseToken:q.canonicalQuote;uint256 beforeOut=_balance(output);
        if(q.inputAsset!=address(0))IERC20(q.inputAsset).forceApprove(address(coordinator),q.maxGrossInput);
        r=coordinator.executeDirect{value:q.inputAsset==address(0)?q.maxGrossInput:0}(q,target);
        if(q.inputAsset!=address(0))IERC20(q.inputAsset).forceApprove(address(coordinator),0);
        if(r.grossInputUsed!=p.grossInput||r.netOutput!=p.output||r.inputRefund!=q.maxGrossInput-r.grossInputUsed
            ||beforeIn-_balance(q.inputAsset)!=r.grossInputUsed||_balance(output)-beforeOut!=r.netOutput)revert SettlementMismatch();
    }
    function _executeFresh(E.DirectRequest memory q,uint256 target) private returns(E.Result memory r,C.Plan memory p){
        uint256 beforeIn=_balance(q.inputAsset);address output=q.side==E.Side.Buy?q.baseToken:q.canonicalQuote;uint256 beforeOut=_balance(output);
        if(q.inputAsset!=address(0))IERC20(q.inputAsset).forceApprove(address(coordinator),q.maxGrossInput);
        (r,p)=coordinator.executeWithPlan{value:q.inputAsset==address(0)?q.maxGrossInput:0}(q,target);
        if(q.inputAsset!=address(0))IERC20(q.inputAsset).forceApprove(address(coordinator),0);
        if(r.grossInputUsed!=p.grossInput||r.netOutput!=p.output||r.inputRefund!=q.maxGrossInput-r.grossInputUsed
            ||beforeIn-_balance(q.inputAsset)!=r.grossInputUsed||_balance(output)-beforeOut!=r.netOutput)revert SettlementMismatch();
    }
    function _verify(address base,address quote,E.Side side,C.Plan memory p) private view {
        (P.Ratio memory rate,P.Ratio memory usd,S.Source[] memory nowSources)=coordinator.liquidity().snapshotPriced(base,quote,side);
        if(rate.n!=p.rate.n||rate.d!=p.rate.d||usd.n!=p.usd.n||usd.d!=p.usd.d)revert StateChanged();
        uint256 j;
        for(uint256 i;i<p.sources.length;i++){
            uint256 left=p.sources[i].available-p.outputs[i];if(left==0)continue;
            if(j==nowSources.length||nowSources[j].key!=p.sources[i].key||nowSources[j].available!=left)revert StateChanged();++j;
        }
        if(j!=nowSources.length)revert StateChanged();
    }
    function _other(address q) private view returns(address){return q==address(0)?usdg:address(0);}
    function _balance(address a) private view returns(uint256){return a==address(0)?address(this).balance:IERC20(a).balanceOf(address(this));}
    function _collect(address a,uint256 n) private {
        if(a==address(0)){if(msg.value!=n)revert InvalidRequest();}
        else{if(msg.value!=0)revert InvalidRequest();uint256 b=_balance(a);IERC20(a).safeTransferFrom(msg.sender,address(this),n);if(_balance(a)-b!=n)revert SettlementMismatch();}
    }
    function _send(address a,address to,uint256 n) private {
        if(n==0)return;
        if(a==address(0)){(bool ok,)=payable(to).call{value:n}("");if(!ok)revert SettlementMismatch();}
        else{uint256 b=_balance(a);uint256 received=IERC20(a).balanceOf(to);IERC20(a).safeTransfer(to,n);if(b-_balance(a)!=n||IERC20(a).balanceOf(to)-received!=n)revert SettlementMismatch();}
    }
    receive() external payable {if(msg.sender!=address(coordinator)&&msg.sender!=address(adapter))revert InvalidRequest();}
}
