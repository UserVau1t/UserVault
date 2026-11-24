pragma solidity 0.8.30;
import {LiquidityFeeVault} from "./LiquidityFeeVault.sol";
import {LiquidityPositionLedger} from "./LiquidityPositionLedger.sol";
import {LiquidityExecutionV2} from "./LiquidityExecutionV2.sol";
import {LiquidityMath} from "./LiquidityMath.sol";
import {LM_ROUTED_SWAP,LM_COMPOUND_ROUTE,LM_COMPOUND_QUOTE,LM_AUTO_QUOTE,LM_AUTO_REBALANCE,LMAutoTerms} from "./LiquiditySwapPlan.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

struct LMPoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
struct LMSwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
interface ILMPositionManager {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function ownerOf(uint256) external view returns (address);
    function getApproved(uint256) external view returns (address);
    function isApprovedForAll(address,address) external view returns (bool);
    function approve(address,uint256) external;
    function getPoolAndPositionInfo(uint256) external view returns (LMPoolKey memory,uint256);
    function getPositionLiquidity(uint256) external view returns (uint128);
    function nextTokenId() external view returns (uint256);
    function modifyLiquidities(bytes calldata,uint256) external payable;
}
interface ILMStateView {
    function poolManager() external view returns (address);
    function getSlot0(bytes32) external view returns (uint160,int24,uint24,uint24);
}
interface ILMPoolManager {
    function unlock(bytes calldata) external returns (bytes memory);
    function swap(LMPoolKey calldata,LMSwapParams calldata,bytes calldata) external returns (int256);
    function sync(address) external;
    function settle() external payable returns (uint256);
    function take(address,address,uint256) external;
}
interface ILMToken {
    function balanceOf(address) external view returns (uint256);
}
interface ILMPermit2 { function approve(address,address,uint160,uint48) external; }
interface ILMUsdPricing {
    function configuredChainId() external view returns(uint256);
    function usdg() external view returns(address);
    function quoteUsd(address) external view returns(uint256 n,uint256 d);
}

abstract contract LiquidityControllerCore {
    error Unauthorized(); error InvalidConfiguration(); error InvalidPosition(); error Expired();
    error MarketLeftRange(); error NotReady(); error InvalidSwap(); error InsufficientOutput(); error Reentrant(); error TransferFailed();
    error UnsupportedHook(); error BalanceChanged(); error EmptyLiquidity(); error WrongNetwork();
    error UsdPriceUnavailable(); error InvalidFeeRoute(); error InsufficientFees();

    address public constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address public constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant USDG = address(uint160(0x005fc5360d0400a0fd4f2af552add042d716f1d168));
    address public immutable usdPricing;
    bytes32 public immutable usdPricingHash;
    LiquidityFeeVault public immutable feeVault;
    LiquidityMath public immutable liquidityMath;
    LiquidityExecutionV2 public immutable executionEngine;
    uint256 private constant Q96 = 1 << 96;
    bytes32 internal constant MARKET_REBALANCE = keccak256("UserVault.MarketRebalance.v1");
    ILMPositionManager internal constant pm = ILMPositionManager(POSITION_MANAGER);
    ILMStateView private constant viewState = ILMStateView(STATE_VIEW);
    ILMPoolManager private constant pools = ILMPoolManager(POOL_MANAGER);

    struct Configuration {
        address operator;
        int24 lowerOffset;
        int24 upperOffset;
        int24 triggerDistance;
        uint32 minimumInterval;
        uint16 slippageBps;
        uint48 expiresAt;
        uint256 minimumCompoundUsd;
        bool autoCompound;
        bool autoRebalance;
    }
    struct Strategy { address owner; uint64 nonce; uint48 lastRebalance; uint48 lastCompound; Configuration config; }
    struct Swap { uint128 amountIn; bool zeroForOne; uint160 sqrtPriceLimitX96; }
    struct Bounds { uint160 minimumPrice; uint160 maximumPrice; uint128 minimumLiquidity; uint256 minimumValue1; }
    struct Operation {
        uint256 tokenId; address owner; LMPoolKey key; uint160 price; int24 lower; int24 upper;
        uint256 baseline0; uint256 baseline1; uint16 slippageBps; bool rebalance;
        address treasury; uint64 strategyNonce; bytes conversion; bytes market; uint128 minimumOut; uint160 valuationPrice; bool liveFunding;
        LiquidityPositionLedger ledger; uint128 managedBefore; bool wholePosition;
    }
    mapping(uint256 => Strategy) internal strategies;
    mapping(uint256 => uint64) public nonces;
    uint256 private entered;
    event StrategyConfigured(uint256 indexed tokenId,address indexed owner,uint64 nonce,Configuration configuration);
    event StrategyDisabled(uint256 indexed tokenId,address indexed owner,uint64 nonce);
    event Executed(uint256 indexed oldTokenId,uint256 indexed newTokenId,address indexed owner,bool rebalance,uint128 liquidity,uint256 returned0,uint256 returned1);
    event FeesReserved(address indexed owner,uint256 indexed tokenId,address indexed currency,uint256 amount);
    event FeesWithdrawn(address indexed owner,address indexed currency,uint256 amount);
    event FeesReinvested(address indexed owner,uint256 indexed tokenId,uint256 credit0,uint256 credit1);

    modifier lock() { if(entered!=0) revert Reentrant(); entered=1; _; entered=0; }
    constructor(address pricing,bytes32 pricingHash) {
        if(block.chainid!=4663) revert WrongNetwork();
        if(pm.poolManager()!=POOL_MANAGER||pm.permit2()!=PERMIT2||viewState.poolManager()!=POOL_MANAGER) revert InvalidConfiguration();
        if(pricing.code.length==0||pricing.codehash!=pricingHash||ILMUsdPricing(pricing).configuredChainId()!=4663||ILMUsdPricing(pricing).usdg()!=USDG)revert InvalidConfiguration();
        usdPricing=pricing;usdPricingHash=pricingHash;
    }
    receive() external payable { if(msg.sender!=POSITION_MANAGER&&msg.sender!=POOL_MANAGER&&msg.sender!=address(feeVault)&&msg.sender!=_automationTreasury()) revert Unauthorized(); }
    function feeCredits(address owner,address currency) external view returns(uint256){return feeVault.credits(owner,currency);}
    function totalFeeCredits(address currency) external view returns(uint256){return feeVault.totalCredits(currency);}
    function strategy(uint256 tokenId) external view returns(Strategy memory) { return strategies[tokenId]; }

    function configure(uint256 tokenId,Configuration memory config) external lock {
        address owner=pm.ownerOf(tokenId);
        if(!_mayConfigure(owner,tokenId)||!pm.isApprovedForAll(owner,address(this))) revert Unauthorized();
        _enrollForOwner(tokenId);
        (LMPoolKey memory key,uint256 info)=pm.getPoolAndPositionInfo(tokenId);
        _plain(key);
        (int24 lower,int24 upper)=_ticks(info);
        // Managed market strategies become eligible on a boundary crossing, even at the same timestamp.
        if(_automationTreasury()!=address(0))config.minimumInterval=0;
        else if(config.minimumInterval==0)revert InvalidConfiguration();
        if(config.operator==address(0)||(!config.autoCompound&&!config.autoRebalance)||(config.slippageBps & ~LM_AUTO_REBALANCE)>=10000) revert InvalidConfiguration();
        if((config.slippageBps & LM_AUTO_REBALANCE)!=0&&(!config.autoRebalance||_automationTreasury()==address(0)))revert InvalidConfiguration();
        if(config.autoCompound){if(config.minimumCompoundUsd<10e18)revert InvalidConfiguration();_usdValue(key,1,1,1<<96);}
        if(config.expiresAt!=0&&config.expiresAt<=block.timestamp) revert Expired();
        if(config.lowerOffset>=config.upperOffset||config.lowerOffset%key.tickSpacing!=0||config.upperOffset%key.tickSpacing!=0||config.triggerDistance<0||int256(config.triggerDistance)*2>=int256(upper)-lower) revert InvalidConfiguration();
        if(_managedLiquidity(tokenId)==0) revert EmptyLiquidity();
        uint64 nonce=++nonces[tokenId];
        strategies[tokenId]=Strategy(owner,nonce,uint48(block.timestamp),uint48(block.timestamp),config);
        pm.approve(address(this),tokenId);
        emit StrategyConfigured(tokenId,owner,nonce,config);
    }
    function _enrollForOwner(uint256 id) internal virtual {_requireOrigin(id);}
    function walletPositionTerms() public pure virtual returns(bool){return false;}
    function _mayConfigure(address owner,uint256) internal view virtual returns(bool){return msg.sender==owner;}
    function disable(uint256 tokenId) external lock {
        Strategy memory s=strategies[tokenId];
        if(s.owner!=msg.sender) revert Unauthorized();
        delete strategies[tokenId];
        uint64 nonce=++nonces[tokenId];
        if(_automationTreasury()!=address(0)){
            // Remember the range for later opt-in. The zero owner leaves automation disabled.
            strategies[tokenId].config.lowerOffset=s.config.lowerOffset;
            strategies[tokenId].config.upperOffset=s.config.upperOffset;
            strategies[tokenId].nonce=nonce;
        }
        emit StrategyDisabled(tokenId,msg.sender,nonce);
    }
    function execute(uint256 tokenId,uint64 nonce,bool rebalance,Swap calldata swap,uint256 deadline) external lock returns(uint256 newId) {
        return _execute(tokenId,nonce,rebalance,swap,deadline,"");
    }
    function _execute(uint256 tokenId,uint64 nonce,bool rebalance,Swap calldata swap,uint256 deadline,bytes memory conversion) internal returns(uint256 newId) {
        _deadline(deadline);
        Strategy memory s=strategies[tokenId];
        if(s.owner==address(0)||s.config.operator!=msg.sender||s.nonce!=nonce||pm.ownerOf(tokenId)!=s.owner||pm.getApproved(tokenId)!=address(this)||!pm.isApprovedForAll(s.owner,address(this))) revert Unauthorized();
        if(s.config.expiresAt!=0&&block.timestamp>s.config.expiresAt) revert Expired();
        if(rebalance&&block.timestamp<uint256(s.lastRebalance)+s.config.minimumInterval) revert NotReady();
        if(rebalance?!s.config.autoRebalance:!s.config.autoCompound) revert Unauthorized();
        uint16 slippage=s.config.slippageBps & ~LM_AUTO_REBALANCE;
        if(rebalance&&(s.config.slippageBps & LM_AUTO_REBALANCE)!=0){
            if(bytes32(conversion)!=MARKET_REBALANCE)revert InvalidConfiguration();
            (,bytes memory funding,)=abi.decode(conversion,(bytes32,bytes,bytes));
            (bytes32 mode,LMAutoTerms memory terms)=abi.decode(funding,(bytes32,LMAutoTerms));
            if(mode!=LM_AUTO_QUOTE||terms.tokenId!=tokenId||terms.nonce!=nonce)revert InvalidConfiguration();
            slippage=terms.bps;
        }
        (Operation memory op,int24 tick)=_operation(tokenId,s.owner,slippage,rebalance);
        op.treasury=_automationTreasury();
        op.liveFunding=op.treasury!=address(0)&&bytes32(conversion)==MARKET_REBALANCE;
        if(rebalance){
            tick=_rebalanceTick(op.key,tick,swap,conversion);
            if(op.treasury!=address(0))op.valuationPrice=liquidityMath.sqrtPriceAtTick(tick);
            int24 distance=s.config.triggerDistance;
            bool ready=distance==0?(tick<op.lower||tick>=op.upper):(int256(tick)<=int256(op.lower)+distance||int256(tick)>=int256(op.upper)-distance);
            if(!ready){
                if(op.liveFunding)return _keepPosition(tokenId,s);
                revert NotReady();
            }
            int256 base=_floor(tick,op.key.tickSpacing);
            int256 low=base+s.config.lowerOffset;int256 high=base+s.config.upperOffset;
            int24 minTick=TickMath.minUsableTick(op.key.tickSpacing);int24 maxTick=TickMath.maxUsableTick(op.key.tickSpacing);
            if(low<minTick)low=minTick;if(high>maxTick)high=maxTick;
            if(low>=high||low<type(int24).min||high>type(int24).max) revert InvalidConfiguration();
            if(low==op.lower&&high==op.upper){
                if(op.liveFunding)return _keepPosition(tokenId,s);
                revert NotReady();
            }
            op.lower=int24(low);op.upper=int24(high);
        }
        if(rebalance)strategies[tokenId].lastRebalance=uint48(block.timestamp);else strategies[tokenId].lastCompound=uint48(block.timestamp);
        if(rebalance&&!s.config.autoCompound)_reserveAccrued(op);
        Bounds memory bounds=Bounds(0,type(uint160).max,1,0);
        if(op.liveFunding){
            if(!rebalance)revert InvalidConfiguration();
            (,op.market,)=abi.decode(conversion,(bytes32,bytes,bytes));
            if(bytes32(op.market)==LM_AUTO_QUOTE&&(s.config.slippageBps & LM_AUTO_REBALANCE)==0)revert InvalidConfiguration();
            op.strategyNonce=nonce;
        }else if(op.treasury!=address(0)){
            bool routedCompound=bytes32(conversion)==LM_COMPOUND_ROUTE;
            if(routedCompound){if(rebalance)revert InvalidSwap();(,conversion)=abi.decode(conversion,(bytes32,bytes));}
            int24 lower; int24 upper;
            (bounds,lower,upper,op.minimumOut,op.market,op.conversion)=abi.decode(conversion,(Bounds,int24,int24,uint128,bytes,bytes));
            if(lower!=op.lower||upper!=op.upper||bounds.minimumPrice==0||bounds.minimumPrice>bounds.maximumPrice||bounds.minimumLiquidity==0)revert InvalidConfiguration();
            if(!rebalance&&op.market.length!=0&&(!routedCompound||bytes32(op.market)!=LM_ROUTED_SWAP||op.minimumOut==0||swap.sqrtPriceLimitX96!=0))revert InvalidSwap();
            if(rebalance&&swap.amountIn>0&&(op.market.length==0||op.minimumOut==0))revert InvalidSwap();
            op.strategyNonce=nonce;
        }
        if(_requiresCompoundQuote()&&!rebalance&&swap.amountIn!=0&&
            (bytes32(op.conversion)!=LM_COMPOUND_QUOTE||bytes32(op.market)!=LM_ROUTED_SWAP))revert InvalidSwap();
        newId=_run(op,swap,bounds,deadline,rebalance?0:s.config.minimumCompoundUsd);
        if(rebalance&&op.treasury!=address(0)&&(op.liveFunding||swap.amountIn!=0)&&tick>=op.lower&&tick<op.upper){
            // The funding swap can move the very market used to select the range.
            int24 settledTick=_rebalanceTick(op.key,tick,swap,conversion);
            if(settledTick<op.lower||settledTick>=op.upper)revert MarketLeftRange();
        }
        if(rebalance){
            delete strategies[tokenId];emit StrategyDisabled(tokenId,s.owner,++nonces[tokenId]);
            s.nonce=++nonces[newId];s.lastRebalance=uint48(block.timestamp);strategies[newId]=s;
            pm.approve(address(this),newId);
            emit StrategyConfigured(newId,s.owner,s.nonce,s.config);
        }else{strategies[tokenId].nonce=++nonces[tokenId];emit StrategyConfigured(tokenId,s.owner,strategies[tokenId].nonce,s.config);}
    }
    function manualRebalance(uint256 tokenId,int24 lower,int24 upper,uint16 slippageBps,Swap calldata swap,Bounds calldata bounds,uint256 deadline) external lock returns(uint256 newId) {
        _deadline(deadline);
        if(pm.ownerOf(tokenId)!=msg.sender) revert Unauthorized();
        (Operation memory op,)=_operation(tokenId,msg.sender,slippageBps,true);
        if(lower>=upper||lower%op.key.tickSpacing!=0||upper%op.key.tickSpacing!=0||lower<TickMath.minUsableTick(op.key.tickSpacing)||upper>TickMath.maxUsableTick(op.key.tickSpacing)) revert InvalidConfiguration();
        if(bounds.minimumPrice==0||bounds.minimumPrice>=bounds.maximumPrice||bounds.minimumLiquidity==0) revert InvalidConfiguration();
        op.lower=lower;op.upper=upper;
        if(strategies[tokenId].owner!=msg.sender||!strategies[tokenId].config.autoCompound)_reserveAccrued(op);
        newId=_run(op,swap,bounds,deadline,0);
        if(strategies[tokenId].owner!=address(0)){delete strategies[tokenId];emit StrategyDisabled(tokenId,msg.sender,++nonces[tokenId]);}
    }
    function collectFees(uint256 tokenId) external lock returns(uint256 amount0,uint256 amount1) {
        LMPoolKey memory key;
        (key,amount0,amount1)=_collect(tokenId,msg.sender);
        _reserve(msg.sender,tokenId,key.currency0,amount0);_reserve(msg.sender,tokenId,key.currency1,amount1);
    }
    function collectAndWithdraw(uint256 tokenId) external lock {
        (LMPoolKey memory key,uint256 a0,uint256 a1)=_collect(tokenId,msg.sender);
        _reserve(msg.sender,tokenId,key.currency0,a0);_reserve(msg.sender,tokenId,key.currency1,a1);
        _withdrawCredit(msg.sender,key.currency0,feeVault.credits(msg.sender,key.currency0));
        _withdrawCredit(msg.sender,key.currency1,feeVault.credits(msg.sender,key.currency1));
    }
    function withdrawFees(address currency,uint256 amount) external lock {
        if(amount==0)revert InsufficientFees();_withdrawCredit(msg.sender,currency,amount);
    }
    function withdrawFeesAsEth(uint256 collectTokenId,LiquidityFeeVault.Withdrawal[] calldata withdrawals,uint256 minimumEth,uint256 deadline) external lock returns(uint256) {
        if(collectTokenId!=0){
            (LMPoolKey memory key,uint256 a0,uint256 a1)=_collect(collectTokenId,msg.sender);
            _reserve(msg.sender,collectTokenId,key.currency0,a0);_reserve(msg.sender,collectTokenId,key.currency1,a1);
        }
        return feeVault.withdrawAsEthFor(msg.sender,withdrawals,minimumEth,deadline);
    }
    function manualCompound(uint256 tokenId,uint256 credit0,uint256 credit1,uint16 slippageBps,Swap calldata swap,Bounds calldata bounds,uint256 deadline) external virtual lock {
        _deadline(deadline);if(pm.ownerOf(tokenId)!=msg.sender)revert Unauthorized();
        (Operation memory op,)=_operation(tokenId,msg.sender,slippageBps,false);
        if(bounds.minimumPrice==0||bounds.minimumPrice>=bounds.maximumPrice||bounds.minimumLiquidity==0)revert InvalidConfiguration();
        _debit(msg.sender,op.key.currency0,credit0);_debit(msg.sender,op.key.currency1,credit1);
        _run(op,swap,bounds,deadline,0);
        Strategy storage s=strategies[tokenId];
        if(s.owner==msg.sender){s.nonce=++nonces[tokenId];s.lastCompound=uint48(block.timestamp);emit StrategyConfigured(tokenId,msg.sender,s.nonce,s.config);}
        emit FeesReinvested(msg.sender,tokenId,credit0,credit1);
    }
    function _collect(uint256 tokenId,address owner) private returns(LMPoolKey memory key,uint256 amount0,uint256 amount1) {
        if(pm.ownerOf(tokenId)!=owner)revert Unauthorized();
        _enrollForOwner(tokenId);
        (key,)=pm.getPoolAndPositionInfo(tokenId);_plain(key);
        uint128 beforeLiquidity=pm.getPositionLiquidity(tokenId);uint256 before0=_balance(key.currency0);uint256 before1=_balance(key.currency1);
        bytes[] memory actions=new bytes[](2);
        actions[0]=abi.encode(tokenId,uint256(0),uint128(0),uint128(0),bytes(""));actions[1]=abi.encode(key.currency0,key.currency1,address(this));
        pm.modifyLiquidities(abi.encode(hex"0111",actions),block.timestamp);
        LiquidityPositionLedger book=_shareLedger();
        if(address(book)!=address(0)){
            (uint256 f0,uint256 f1)=book.takeOutsideFees(tokenId);
            _send(key.currency0,owner,f0);_send(key.currency1,owner,f1);
        }
        if(pm.ownerOf(tokenId)!=owner||pm.getPositionLiquidity(tokenId)!=beforeLiquidity)revert InvalidPosition();
        amount0=_balance(key.currency0)-before0;amount1=_balance(key.currency1)-before1;
    }
    function _reserveAccrued(Operation memory op) private {
        (,uint256 a0,uint256 a1)=_collect(op.tokenId,op.owner);
        _reserve(op.owner,op.tokenId,op.key.currency0,a0);_reserve(op.owner,op.tokenId,op.key.currency1,a1);
        _unchangedPrice(op.key,op.price);
    }
    function _reserve(address owner,uint256 tokenId,address currency,uint256 amount) private {
        if(amount==0)return;
        uint256 beforeBalance=currency==address(0)?address(feeVault).balance:ILMToken(currency).balanceOf(address(feeVault));
        _send(currency,address(feeVault),amount);
        uint256 afterBalance=currency==address(0)?address(feeVault).balance:ILMToken(currency).balanceOf(address(feeVault));
        if(afterBalance!=beforeBalance+amount)revert BalanceChanged();feeVault.credit(owner,currency,amount);
        emit FeesReserved(owner,tokenId,currency,amount);
    }
    function _debit(address owner,address currency,uint256 amount) private {
        if(amount>0)feeVault.reinvestFor(owner,currency,amount);
    }
    function _withdrawCredit(address owner,address currency,uint256 amount) private {
        if(amount==0)return;feeVault.withdrawFor(owner,currency,amount);emit FeesWithdrawn(owner,currency,amount);
    }
    function _usdValue(LMPoolKey memory key,uint256 a0,uint256 a1,uint160 price) internal view virtual returns(uint256) {
        if(usdPricing.codehash!=usdPricingHash)revert UsdPriceUnavailable();address root;uint256 value;
        if(key.currency0==address(0)||key.currency0==USDG){root=key.currency0;value=a0+_value0(a1,price);}
        else if(key.currency1==USDG){root=key.currency1;value=_value1(a0,a1,price);}
        else revert UsdPriceUnavailable();
        (uint256 n,uint256 d)=ILMUsdPricing(usdPricing).quoteUsd(root);if(n==0||d==0)revert UsdPriceUnavailable();
        return FullMath.mulDiv(value,n,d);
    }
    function _operation(uint256 tokenId,address owner,uint16 slippageBps,bool rebalance) private view returns(Operation memory op,int24 tick) {
        _requireOrigin(tokenId);
        if(slippageBps>=10000) revert InvalidConfiguration();
        (LMPoolKey memory key,uint256 info)=pm.getPoolAndPositionInfo(tokenId);_plain(key);
        (uint160 price,int24 current,,)=viewState.getSlot0(keccak256(abi.encode(key)));
        (int24 lower,int24 upper)=_ticks(info);
        op.managedBefore=_managedLiquidity(tokenId);
        if(price==0||lower>=upper||op.managedBefore==0) revert InvalidPosition();
        op.ledger=_shareLedger();
        op.wholePosition=walletPositionTerms();
        op.tokenId=tokenId;op.owner=owner;op.key=key;op.price=price;op.valuationPrice=price;op.lower=lower;op.upper=upper;
        op.baseline0=_balance(key.currency0);op.baseline1=_balance(key.currency1);
        op.slippageBps=slippageBps;op.rebalance=rebalance;tick=current;
    }
    function _rebalanceTick(LMPoolKey memory,int24 localTick,Swap calldata,bytes memory) internal view virtual returns(int24){return localTick;}
    function _requireOrigin(uint256) internal view virtual {}
    function _shareLedger() internal view virtual returns(LiquidityPositionLedger){return LiquidityPositionLedger(address(0));}
    function _managedLiquidity(uint256 id) private view returns(uint128){
        LiquidityPositionLedger book=_shareLedger();
        return address(book)==address(0)?pm.getPositionLiquidity(id):book.managedLiquidity(id);
    }
    function _keepPosition(uint256 tokenId,Strategy memory s) private returns(uint256){
        // Consume this intent so a later crossing can be acted on with the same user settings.
        s.nonce=++nonces[tokenId];
        strategies[tokenId].nonce=s.nonce;
        emit StrategyConfigured(tokenId,s.owner,s.nonce,s.config);
        return tokenId;
    }
    function _automationTreasury() internal view virtual returns(address){return address(0);}
    function _requiresCompoundQuote() internal pure virtual returns(bool){return false;}
    function _replaceOrigin(uint256,uint256) internal virtual {}
    function _run(Operation memory op,Swap calldata swap,Bounds memory bounds,uint256 deadline,uint256 minimumUsd) private returns(uint256 id){
        id=abi.decode(_delegate(abi.encodeCall(LiquidityExecutionV2.run,(op,swap,bounds,deadline,minimumUsd))),(uint256));
        if(op.rebalance)_replaceOrigin(op.tokenId,id);
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory){if(msg.sender!=POOL_MANAGER)revert Unauthorized();return abi.decode(_delegate(abi.encodeCall(LiquidityExecutionV2.unlockCallback,(data))),(bytes));}
    function _delegate(bytes memory data) private returns(bytes memory){(bool ok,bytes memory result)=address(executionEngine).delegatecall(data);if(!ok){assembly ("memory-safe"){revert(add(result,32),mload(result))}}return result;}
    function feeValueUsd(LMPoolKey calldata key,uint256 amount0,uint256 amount1,uint160 price) external view returns(uint256){return _usdValue(key,amount0,amount1,price);}
    function _unchangedPrice(LMPoolKey memory key,uint160 expected) private view {(uint160 actual,,,)=viewState.getSlot0(keccak256(abi.encode(key)));if(actual!=expected)revert InsufficientOutput();}
    function _balance(address token) private view returns(uint256) {return token==address(0)?address(this).balance:ILMToken(token).balanceOf(address(this));}
    function _send(address token,address recipient,uint256 amount) private {if(amount==0)return;if(token==address(0)){(bool ok,)=recipient.call{value:amount}("");if(!ok)revert TransferFailed();}else _tokenCall(token,abi.encodeWithSignature("transfer(address,uint256)",recipient,amount));}
    function _tokenCall(address token,bytes memory data) private {(bool ok,bytes memory result)=token.call(data);if(!ok||(result.length!=0&&(result.length!=32||!abi.decode(result,(bool)))))revert TransferFailed();}
    function _plain(LMPoolKey memory key) private pure {if(key.hooks!=address(0))revert UnsupportedHook();if(key.currency0>=key.currency1||key.tickSpacing<=0||key.fee>1000000)revert InvalidPosition();}
    function _ticks(uint256 info) private pure returns(int24,int24){return(int24(uint24(info>>8)),int24(uint24(info>>32)));}
    function _floor(int24 tick,int24 spacing) private pure returns(int256){int256 result=int256(tick)/spacing*spacing;if(tick<0&&tick%spacing!=0)result-=spacing;return result;}
    function _value1(uint256 a0,uint256 a1,uint160 price) internal view returns(uint256){return liquidityMath.value1(a0,a1,price);}
    function _value0(uint256 a1,uint160 price) internal view returns(uint256){return liquidityMath.value0(a1,price);}
    function _deadline(uint256 deadline) private view {if(deadline<block.timestamp||deadline>block.timestamp+1200)revert Expired();}
}

contract LiquidityControllerV2 is LiquidityControllerCore {
    constructor(address pricing,bytes32 pricingHash) LiquidityControllerCore(pricing,pricingHash){
        feeVault=new LiquidityFeeVault();
        liquidityMath=new LiquidityMath();
        executionEngine=new LiquidityExecutionV2();
    }
}
