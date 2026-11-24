pragma solidity 0.8.30;
import {LiquidityControllerCore,LMPoolKey,LMSwapParams,ILMPositionManager,ILMStateView,ILMPoolManager,ILMToken,ILMPermit2} from "./LiquidityControllerV2.sol";
import {LiquidityFeeVault} from "./LiquidityFeeVault.sol";
import {LM_ROUTED_SWAP,LM_AUTO_QUOTE,LM_COMPOUND_QUOTE,LMFundingFill} from "./LiquiditySwapPlan.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityDepositFee} from "./LiquidityDepositFee.sol";
import {LiquidityPermitAllowance} from "./LiquidityPermitAllowance.sol";
interface ILMAutomationTreasury {
    function verifyCompoundQuote(LMPoolKey calldata key,uint256 id,uint64 nonce,bool forward,uint128 input,bytes32 routeHash,uint128 minimum,bytes calldata proof) external view returns(uint16,uint128);
    function feeReference() external view returns (ILMMarketFunding);
    function swapPosition(LMPoolKey calldata source,bool zeroForOne,uint128 amount,uint128 minimum,bytes calldata market,uint256 deadline) external payable;
    function settleReinvestment(uint256 id,uint64 nonce,LMPoolKey calldata key,uint256 fee0,uint256 fee1,uint256 deadline,bytes calldata conversion) external payable;
    function settleRebalance(uint256 id,uint64 nonce,LMPoolKey calldata key,uint256 fee0,uint256 fee1,uint256 deadline,bytes calldata conversion) external payable;
}
interface ILMMarketFunding {
    function quoteFunding(LMPoolKey calldata key,bytes calldata forwardRoute,uint160 localPrice,uint160 marketPrice,int24 lower,int24 upper,uint256 a0,uint256 a1,uint16 slippageBps) external returns(bool forward,uint128 input,uint128 minimumOut,uint128 minimumLiquidity,bytes memory route,uint128 expectedOut);
}
contract LiquidityExecutionV2 {
    error Unauthorized();error InvalidConfiguration();error InvalidPosition();error Expired();error InvalidSwap();error InsufficientOutput();error TransferFailed();error UnsupportedHook();error BalanceChanged();error EmptyLiquidity();
    address private immutable self=address(this);
    address private constant POSITION_MANAGER=0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address private constant POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant STATE_VIEW=0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address private constant PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 private constant Q96=1<<96;
    bytes32 private constant COMMITMENT_SLOT=keccak256("uservault.liquidity.v2.swap-commitment");
    ILMPositionManager private constant pm=ILMPositionManager(POSITION_MANAGER);
    ILMStateView private constant viewState=ILMStateView(STATE_VIEW);
    ILMPoolManager private constant pools=ILMPoolManager(POOL_MANAGER);
    event Executed(uint256 indexed oldTokenId,uint256 indexed newTokenId,address indexed owner,bool rebalance,uint128 liquidity,uint256 returned0,uint256 returned1);
    event FeesReserved(address indexed owner,uint256 indexed tokenId,address indexed currency,uint256 amount);
    function _commitment() private view returns(bytes32 value){bytes32 slot=COMMITMENT_SLOT;assembly ("memory-safe"){value:=sload(slot)}}
    function _setCommitment(bytes32 value) private {bytes32 slot=COMMITMENT_SLOT;assembly ("memory-safe"){sstore(slot,value)}}
    function _reserve(address owner,uint256 tokenId,address currency,uint256 amount) private {
        if(amount==0)return;LiquidityFeeVault vault=LiquidityControllerCore(payable(address(this))).feeVault();
        uint256 beforeBalance=currency==address(0)?address(vault).balance:ILMToken(currency).balanceOf(address(vault));
        _send(currency,address(vault),amount);
        uint256 afterBalance=currency==address(0)?address(vault).balance:ILMToken(currency).balanceOf(address(vault));
        if(afterBalance!=beforeBalance+amount)revert BalanceChanged();vault.credit(owner,currency,amount);emit FeesReserved(owner,tokenId,currency,amount);
    }
    function run(LiquidityControllerCore.Operation memory op,LiquidityControllerCore.Swap memory swap,LiquidityControllerCore.Bounds memory bounds,uint256 deadline,uint256 minimumUsd) external returns(uint256 newId) {
        if(address(this)==self)revert Unauthorized();
        if(op.price<bounds.minimumPrice||op.price>bounds.maximumPrice) revert InsufficientOutput();
        bytes[] memory remove=new bytes[](2);
        bool burn=op.rebalance;
        uint256 decrease;
        if(address(op.ledger)!=address(0)){
            if(op.managedBefore!=op.ledger.managedLiquidity(op.tokenId))revert InvalidPosition();
            if(burn){decrease=op.managedBefore;burn=decrease==pm.getPositionLiquidity(op.tokenId);}
        }
        remove[0]=burn?abi.encode(op.tokenId,uint128(0),uint128(0),bytes("")):abi.encode(op.tokenId,decrease,uint128(0),uint128(0),bytes(""));
        remove[1]=abi.encode(op.key.currency0,op.key.currency1,address(this));
        pm.modifyLiquidities(abi.encode(burn?hex"0311":hex"0111",remove),deadline);
        _payOutsideFees(op);
        (uint256 a0,uint256 a1)=_available(op);
        // Charge the gross inventory released by this burn before selecting swap or mint amounts.
        if(op.rebalance&&op.treasury!=address(0)){
            uint256 divisor=op.wholePosition?1000:400;
            _payAutomationFee(op,a0/divisor,a1/divisor,deadline);
            (a0,a1)=_available(op);
        }
        bool chargeReinvest=!op.rebalance&&op.treasury!=address(0);
        if(minimumUsd>0&&LiquidityControllerCore(payable(address(this))).feeValueUsd(op.key,a0,a1,op.price)<minimumUsd)revert InsufficientOutput();
        bool autoQuote=op.liveFunding&&bytes32(op.market)==LM_AUTO_QUOTE;
        uint128 expectedOut;
        if(chargeReinvest&&bytes32(op.conversion)==LM_COMPOUND_QUOTE){
            if(bytes32(op.market)!=LM_ROUTED_SWAP)revert InvalidSwap();
            (op.slippageBps,expectedOut)=ILMAutomationTreasury(op.treasury).verifyCompoundQuote(
                op.key,op.tokenId,op.strategyNonce,swap.zeroForOne,swap.amountIn,keccak256(op.market),op.minimumOut,op.conversion);
            op.conversion="";
            autoQuote=true;
        }
        // Size and account for the deposit at its own pool once the range is known.
        if(autoQuote)op.valuationPrice=op.price;
        uint256 beforeValue=_value1(a0,a1,op.valuationPrice);
        if(beforeValue<bounds.minimumValue1||beforeValue==0) revert InsufficientOutput();
        uint256 valueAfterFees=beforeValue;
        uint256 maxIdleBps=100;
        if(op.liveFunding){
            (swap.zeroForOne,swap.amountIn,op.minimumOut,bounds.minimumLiquidity,op.market,expectedOut)=
                ILMAutomationTreasury(op.treasury).feeReference().quoteFunding(
                    op.key,op.market,op.price,op.valuationPrice,op.lower,op.upper,a0,a1,op.slippageBps
                );
        }
        if(swap.amountIn>0&&op.treasury!=address(0)&&(op.rebalance||op.market.length!=0)){
            address input=swap.zeroForOne?op.key.currency0:op.key.currency1;
            if(swap.amountIn>(swap.zeroForOne?a0:a1))revert InvalidSwap();
            if(input!=address(0))_tokenCall(input,abi.encodeWithSignature("approve(address,uint256)",op.treasury,swap.amountIn));
            ILMAutomationTreasury treasury=ILMAutomationTreasury(op.treasury);
            if(bytes32(op.market)==LM_ROUTED_SWAP){
                (,LMFundingFill[] memory fills)=abi.decode(op.market,(bytes32,LMFundingFill[]));
                address output=swap.zeroForOne?op.key.currency1:op.key.currency0;
                uint256 beforeOut=_balance(output);
                uint256 total;
                for(uint256 i;i<fills.length;++i){
                    uint128 part=fills[i].amount;
                    if(part==0)continue;
                    total+=part;
                    treasury.swapPosition{value:input==address(0)?part:0}(op.key,swap.zeroForOne,part,1,fills[i].path,deadline);
                }
                uint256 actualOut=_balance(output)-beforeOut;
                if(total!=swap.amountIn||actualOut<op.minimumOut)revert InsufficientOutput();
                if(autoQuote){
                    // Either a short fill or a price improvement can leave a refundable surplus.
                    (uint256 low,uint256 high)=actualOut<expectedOut?(actualOut,uint256(expectedOut)):(uint256(expectedOut),actualOut);
                    maxIdleBps+=FullMath.mulDivRoundingUp(high-low,10000,high);
                }
            }else treasury.swapPosition{value:input==address(0)?swap.amountIn:0}(op.key,swap.zeroForOne,swap.amountIn,op.minimumOut,op.market,deadline);
            if(input!=address(0))_tokenCall(input,abi.encodeWithSignature("approve(address,uint256)",op.treasury,0));
            uint256 remainingInput=swap.zeroForOne?a0-swap.amountIn:a1-swap.amountIn;
            (a0,a1)=_available(op);
            if((swap.zeroForOne?a0:a1)<remainingInput)revert InsufficientOutput();
        }else if(swap.amountIn>0){
            if(swap.amountIn>(swap.zeroForOne?a0:a1)) revert InvalidSwap();
            (,,uint24 packedFee,uint24 lpFee)=viewState.getSlot0(keccak256(abi.encode(op.key)));
            uint256 protocolFee=swap.zeroForOne?packedFee&0xfff:packedFee>>12;
            uint256 swapFee=protocolFee+lpFee-protocolFee*lpFee/1000000;
            if(swapFee>=1000000)revert InvalidSwap();
            bytes memory payload=abi.encode(op.key,swap);
            _setCommitment(keccak256(payload));pools.unlock(payload);
            if(_commitment()!=bytes32(0)) revert InvalidSwap();
            (uint256 b0,uint256 b1)=_available(op);
            uint256 spent=swap.zeroForOne?a0-b0:a1-b1;
            uint256 received=swap.zeroForOne?b1-a1:b0-a0;
            uint256 expected=swap.zeroForOne?_value1(spent,0,op.price):_value0(spent,op.price);
            expected=FullMath.mulDiv(expected,1000000-swapFee,1000000);
            if(spent==0||spent>swap.amountIn||received<FullMath.mulDiv(expected,10000-op.slippageBps,10000)) revert InsufficientOutput();
            uint256 feeValue=FullMath.mulDivRoundingUp(swap.zeroForOne?_value1(spent,0,op.price):spent,swapFee,1000000);
            valueAfterFees=feeValue<beforeValue?beforeValue-feeValue:0;
            a0=b0;a1=b1;
        }
        (uint160 current,,,)=viewState.getSlot0(keccak256(abi.encode(op.key)));
        uint256 priceChange=FullMath.mulDiv(current,Q96,op.price);
        uint256 priceRatio=FullMath.mulDiv(priceChange,priceChange,Q96);
        if(priceRatio<FullMath.mulDiv(Q96,10000-op.slippageBps,10000)||priceRatio>FullMath.mulDiv(Q96,10000+op.slippageBps,10000)) revert InsufficientOutput();
        if(current<bounds.minimumPrice||current>bounds.maximumPrice)revert InsufficientOutput();
        // Signed swaps already enforce the actual input debit and aggregate output in token units.
        if(!autoQuote&&_value1(a0,a1,op.valuationPrice)<FullMath.mulDiv(valueAfterFees,10000-op.slippageBps,10000))revert InsufficientOutput();
        if(a0>type(uint128).max||a1>type(uint128).max) revert InvalidConfiguration();
        // An in-pool compound swap can earn fresh fees on the same NFT. Settle those
        // credits first so that the following increase pays exactly its native debt.
        if(!op.rebalance&&swap.amountIn!=0&&op.market.length==0){
            pm.modifyLiquidities(abi.encode(hex"0111",remove),deadline);
            _payOutsideFees(op);
            (a0,a1)=_available(op);
            if(a0>type(uint128).max||a1>type(uint128).max)revert InvalidConfiguration();
        }
        uint256 net0=chargeReinvest?(op.wholePosition?LiquidityDepositFee.reinvestBudget(a0):a0-a0/100):a0;
        uint256 net1=chargeReinvest?(op.wholePosition?LiquidityDepositFee.reinvestBudget(a1):a1-a1/100):a1;
        (uint128 liquidity,uint256 used0,uint256 used1)=LiquidityControllerCore(payable(address(this))).liquidityMath().mintAmounts(current,op.lower,op.upper,net0,net1);
        if(liquidity<bounds.minimumLiquidity||liquidity==0) revert EmptyLiquidity();
        if(used0>net0||used1>net1)revert InsufficientOutput();
        _approve(op.key.currency0,used0);_approve(op.key.currency1,used1);
        _unchangedPrice(op.key,current);
        newId=op.rebalance?pm.nextTokenId():op.tokenId;
        bytes[] memory add=new bytes[](3);
        add[0]=op.rebalance?abi.encode(op.key,op.lower,op.upper,uint256(liquidity),uint128(used0),uint128(used1),op.owner,bytes("")):abi.encode(op.tokenId,uint256(liquidity),uint128(used0),uint128(used1),bytes(""));
        add[1]=abi.encode(op.key.currency0);add[2]=abi.encode(op.key.currency1);
        uint256 nativeDebt=op.key.currency0==address(0)?used0:0;
        pm.modifyLiquidities{value:nativeDebt}(abi.encode(op.rebalance?hex"021212":hex"001212",add),deadline);
        if(op.rebalance&&address(op.ledger)!=address(0))op.ledger.enroll(newId,liquidity);
        if(pm.ownerOf(newId)!=op.owner) revert Unauthorized();
        if(op.rebalance&&pm.nextTokenId()!=newId+1) revert InvalidPosition();
        _approve(op.key.currency0,0);_approve(op.key.currency1,0);
        if(chargeReinvest)_payAutomationFee(op,op.wholePosition?used0/100:_reinvestShare(used0,a0),op.wholePosition?used1/100:_reinvestShare(used1,a1),deadline);
        (uint256 remainder0,uint256 remainder1)=_available(op);
        if(op.treasury!=address(0)&&(op.rebalance||op.market.length!=0)){
            uint256 invested=_value1(a0-remainder0,a1-remainder1,op.valuationPrice);
            uint256 idle=_value1(remainder0,remainder1,op.valuationPrice);
            if(invested==0||idle>FullMath.mulDiv(invested+idle,maxIdleBps,10000))revert InsufficientOutput();
        }
        if(op.rebalance){_send(op.key.currency0,op.owner,remainder0);_send(op.key.currency1,op.owner,remainder1);}
        else{_reserve(op.owner,op.tokenId,op.key.currency0,remainder0);_reserve(op.owner,op.tokenId,op.key.currency1,remainder1);}
        if(_balance(op.key.currency0)!=op.baseline0||_balance(op.key.currency1)!=op.baseline1) revert BalanceChanged();
        if(address(op.ledger)!=address(0)&&op.ledger.managedLiquidity(newId)!=(op.rebalance?liquidity:op.managedBefore+liquidity))revert InvalidPosition();
        _unchangedPrice(op.key,current);
        emit Executed(op.tokenId,newId,op.owner,op.rebalance,liquidity,remainder0,remainder1);
    }
    function _payOutsideFees(LiquidityControllerCore.Operation memory op) private {
        if(address(op.ledger)==address(0))return;
        (uint256 f0,uint256 f1)=op.ledger.takeOutsideFees(op.tokenId);
        _send(op.key.currency0,op.owner,f0);_send(op.key.currency1,op.owner,f1);
    }
    function _reinvestShare(uint256 used,uint256 available) private pure returns(uint256){
        uint256 share=used/99;uint256 cap=available/100;
        return share<cap?share:cap;
    }
    function _payAutomationFee(LiquidityControllerCore.Operation memory op,uint256 f0,uint256 f1,uint256 deadline) private {
        if(f0==0&&f1==0)return;
        if(op.key.currency0!=address(0)&&f0!=0)_tokenCall(op.key.currency0,abi.encodeWithSignature("approve(address,uint256)",op.treasury,f0));
        if(f1!=0)_tokenCall(op.key.currency1,abi.encodeWithSignature("approve(address,uint256)",op.treasury,f1));
        uint256 eth=op.key.currency0==address(0)?f0:0;
        ILMAutomationTreasury treasury=ILMAutomationTreasury(op.treasury);
        if(op.rebalance)treasury.settleRebalance{value:eth}(op.tokenId,op.strategyNonce,op.key,f0,f1,deadline,op.conversion);
        else treasury.settleReinvestment{value:eth}(op.tokenId,op.strategyNonce,op.key,f0,f1,deadline,op.conversion);
        if(op.key.currency0!=address(0)&&f0!=0)_tokenCall(op.key.currency0,abi.encodeWithSignature("approve(address,uint256)",op.treasury,0));
        if(f1!=0)_tokenCall(op.key.currency1,abi.encodeWithSignature("approve(address,uint256)",op.treasury,0));
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory) {
        if(msg.sender!=POOL_MANAGER||_commitment()==bytes32(0)||keccak256(data)!=_commitment()) revert Unauthorized();
        _setCommitment(bytes32(0));
        (LMPoolKey memory key,LiquidityControllerCore.Swap memory swap)=abi.decode(data,(LMPoolKey,LiquidityControllerCore.Swap));
        int256 delta=pools.swap(key,LMSwapParams(swap.zeroForOne,-int256(uint256(swap.amountIn)),swap.sqrtPriceLimitX96),"");
        int128 delta0=int128(delta>>128);int128 delta1=int128(delta);
        if(swap.zeroForOne?(delta0>=0||delta1<=0):(delta1>=0||delta0<=0)) revert InvalidSwap();
        _settle(key.currency0,delta0);_settle(key.currency1,delta1);
        return "";
    }
    function _settle(address token,int128 delta) private {
        if(delta<0){uint256 amount=uint256(-int256(delta));if(token==address(0)){pools.settle{value:amount}();}else{pools.sync(token);_send(token,POOL_MANAGER,amount);if(pools.settle()!=amount) revert BalanceChanged();}}
        else if(delta>0)pools.take(token,address(this),uint128(delta));
    }
    function _approve(address token,uint256 amount) private {
        if(token==address(0))return;
        if(!LiquidityPermitAllowance.hasUnlimited(token)){
            _tokenCall(token,abi.encodeWithSignature("approve(address,uint256)",PERMIT2,0));
            if(amount>0)_tokenCall(token,abi.encodeWithSignature("approve(address,uint256)",PERMIT2,amount));
        }
        ILMPermit2(PERMIT2).approve(token,POSITION_MANAGER,uint160(amount),amount==0?0:uint48(block.timestamp));
    }
    function _available(LiquidityControllerCore.Operation memory op) private view returns(uint256,uint256) { return (_balance(op.key.currency0)-op.baseline0,_balance(op.key.currency1)-op.baseline1); }
    function _unchangedPrice(LMPoolKey memory key,uint160 expected) private view {(uint160 actual,,,)=viewState.getSlot0(keccak256(abi.encode(key)));if(actual!=expected)revert InsufficientOutput();}
    function _balance(address token) private view returns(uint256) {return token==address(0)?address(this).balance:ILMToken(token).balanceOf(address(this));}
    function _send(address token,address recipient,uint256 amount) private {if(amount==0)return;if(token==address(0)){(bool ok,)=recipient.call{value:amount}("");if(!ok)revert TransferFailed();}else _tokenCall(token,abi.encodeWithSignature("transfer(address,uint256)",recipient,amount));}
    function _tokenCall(address token,bytes memory data) private {(bool ok,bytes memory result)=token.call(data);if(!ok||(result.length!=0&&(result.length!=32||!abi.decode(result,(bool)))))revert TransferFailed();}
    function _plain(LMPoolKey memory key) private pure {if(key.hooks!=address(0))revert UnsupportedHook();if(key.currency0>=key.currency1||key.tickSpacing<=0||key.fee>1000000)revert InvalidPosition();}
    function _ticks(uint256 info) private pure returns(int24,int24){return(int24(uint24(info>>8)),int24(uint24(info>>32)));}
    function _floor(int24 tick,int24 spacing) private pure returns(int256){int256 result=int256(tick)/spacing*spacing;if(tick<0&&tick%spacing!=0)result-=spacing;return result;}
    function _value1(uint256 a0,uint256 a1,uint160 price) private view returns(uint256){return LiquidityControllerCore(payable(address(this))).liquidityMath().value1(a0,a1,price);}
    function _value0(uint256 a1,uint160 price) private view returns(uint256){return LiquidityControllerCore(payable(address(this))).liquidityMath().value0(a1,price);}
    function _deadline(uint256 deadline) private view {if(deadline<block.timestamp||deadline>block.timestamp+1200)revert Expired();}
}
