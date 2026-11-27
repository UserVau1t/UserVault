import {PriceContextConsumer} from "cached/PriceContextConsumer.sol";

pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeePayerContext, FeeAttributedCollector} from "./FeeAttribution.sol";
import {MainnetGroupedV2Vault} from "./MainnetGroupedV2Vault.sol";
import {MainnetLimitOrderManager} from "./MainnetLimitOrderManager.sol";
import {MainnetProRataExecution} from "./MainnetProRataExecution.sol";
import {MainnetCrossProRataExecution} from "./MainnetCrossProRataExecution.sol";

import {MainnetLiquiditySnapshot} from "./MainnetLiquiditySnapshot.sol";
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {V2NativeQuoteAdapter} from "../adapters/V2NativeQuoteAdapter.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";
import {FeeVaultMath} from "./FeeVaultMath.sol";
import {InternalSettlementPolicy} from "./InternalSettlementPolicy.sol";

interface IAtomicAdmission {function consumer() external view returns(address);function registerFor(address payer,address base,bytes calldata permission) external;}
contract FeeAwareVaultCore is MainnetGroupedV2Vault,FeeAttributedCollector {
    FeeVaultMath internal immutable feeVaultMath;
    InternalSettlementPolicy public immutable internalSettlementPolicy;
    bytes32 internal immutable internalPolicyHash;
    constructor(uint256 chain,address admin,PinnedMarketPricing pricing,V2NativeQuoteAdapter adapter,InternalSettlementPolicy policy,address consumer)
        MainnetGroupedV2Vault(chain,admin,pricing,adapter){
        if(IAtomicAdmission(address(pricing)).consumer()!=consumer)revert E.InvalidRequest();
        if(address(policy).code.length==0||policy.installer()!=admin||(consumer==address(this)&&policy.manager()!=address(0)))revert E.InvalidRequest();
        internalSettlementPolicy=policy;internalPolicyHash=address(policy).codehash;feeVaultMath=policy.math();
    }
    function _prepareToken(address base,bytes calldata permission) internal override {
        IAtomicAdmission(address(pricing)).registerFor(msg.sender,base,permission);
    }
    function _checkCapacityAmounts(uint256[3] memory amounts,P.Ratio[3] memory rates) internal view override {feeVaultMath.checkCapacity(amounts,rates);}
    function _fingerprint(address base) internal view override returns(bytes32){return feeVaultMath.fingerprint(pricing,base,_s().usdg);}
    function plan(E.DirectRequest memory q,uint256 inventory,P.Ratio memory rate) internal view virtual override returns(uint256,uint256,uint256){if(address(internalSettlementPolicy).codehash!=internalPolicyHash)revert E.InvalidRequest();return feeVaultMath.plan(q,inventory,rate,internalSettlementPolicy.feeBpsFor(msg.sender,30));}
    function _feePayer(address caller) internal view override returns(address){return _resolveFeePayer(caller);}
    function _recordProtocolFee(address asset,uint256 amount,address payer) internal override {
        super._recordProtocolFee(asset,amount,payer);_capturePaidFee(payer,asset,amount);
    }
    function exportFee(uint256 id) external virtual nonReentrant {_exportPaidFee(id);}
    function _debitProtocolFee(address asset,uint256 amount) internal override {_s().fees[asset]-=amount;}
    function _checkFeeSolvency(address asset) internal view override {_solvent(asset);}
    receive() external payable override {
        if(msg.sender!=_conversionTarget()&&!(currentFeePayer!=address(0)&&_s().lock!=0
            &&internalSettlementPolicy.canSettle(msg.sender)))revert Unauthorized();
    }
}

contract FeeAwareGroupedVault is FeeAwareVaultCore,PriceContextConsumer {
 function _contextPricing() internal view override returns(address){return address(pricing);}

    function prepareLimitToken(address payer,address base,bytes calldata permission) external nonReentrant {
        if(_s().paused||address(internalSettlementPolicy).codehash!=internalPolicyHash
            ||!internalSettlementPolicy.canSettle(msg.sender))revert Unauthorized();
        IAtomicAdmission(address(pricing)).registerFor(payer,base,permission);
    }
    error LimitPricePreview(uint256 n,uint256 d);

    function previewLimitPrice(address base,address quote,bytes calldata permission) external nonReentrant {
        if(_s().paused)revert Unauthorized();
        IAtomicAdmission(address(pricing)).registerFor(msg.sender,base,permission);
        (,P.Ratio memory usd)=pricing.read(base,quote);
        revert LimitPricePreview(usd.n,usd.d);
    }
    constructor(uint256 chain,address admin,PinnedMarketPricing p,V2NativeQuoteAdapter adapter,InternalSettlementPolicy policy,address proxyConsumer)
        FeeAwareVaultCore(chain,admin,p,adapter,policy,proxyConsumer){}
    function createPosition(E.DirectRequest calldata,bytes calldata,uint256) public payable override returns(CreateResult memory){return _dispatchCreate();}
    function createCrossBuyPosition(E.DirectRequest calldata,bytes calldata,bytes calldata,uint256) public payable override returns(CreateResult memory){return _dispatchCreate();}
    function createCrossSellPosition(E.DirectRequest calldata,bytes calldata,bytes calldata,uint256) public payable override returns(CreateResult memory){return _dispatchCreate();}

    function creditCreation(address owner,address base,address quote,Side side,uint256 matched,uint256 output) external returns(uint256 id){
        if(msg.sender!=address(this)||_s().lock==0||output==0)revert Unauthorized();
        VaultStorage storage s=_s();
        bytes32 market=marketId(base,quote);
        bytes32 key=_idKey(owner,market,side);
        id=_groups().ids[key];
        if(id==0){

            uint256 eid=++s.nextEpoch;
            s.epochs[eid].market=market;s.epochs[eid].side=side;s.epochs[eid].ledger.closed=true;
            s.markets[market].base=base;s.markets[market].quote=quote;
            id=++s.nextPosition;
            s.positions[id].owner=owner;s.positions[id].epochId=eid;
            _groups().ids[key]=id;
            emit PositionOpened(id,owner,eid,0);
        }
        uint256 positionEpoch=s.positions[id].epochId;
        s.positions[id].deposited+=matched;
        s.positions[id].accrued+=output;
        s.epochs[positionEpoch].ledger.proceedsReceived+=output;
        (,address asset)=_assets(s.epochs[positionEpoch]);
        s.liabilities[asset]+=output;_solvent(asset);
    }
    function _dispatchCreate() private returns(CreateResult memory){
        if(address(internalSettlementPolicy).codehash!=internalPolicyHash)revert E.InvalidRequest();
        address target=internalSettlementPolicy.creationTarget(address(this));
        (bool ok,bytes memory result)=target.delegatecall(msg.data);
        if(!ok){assembly ("memory-safe"){revert(add(result,32),mload(result))}}
        return abi.decode(result,(CreateResult));
    }
}

contract FeeAwareSameExecution is MainnetProRataExecution,FeeAttributedCollector,PriceContextConsumer {
 function _contextPricing() internal view override returns(address){return address(liquidity.pricing());}
    constructor(MainnetLiquiditySnapshot snapshot) MainnetProRataExecution(snapshot){}
    function _beginFeeExecution() internal override {_enterResolvedFeePayer();}
    function _endFeeExecution() internal override {_leaveFeePayer();}
    function _recordCoordinatorFee(address asset,uint256 amount) internal override {
        super._recordCoordinatorFee(asset,amount);_capturePaidFee(currentFeePayer,asset,amount);
    }
    function exportFee(uint256 id) external nonReentrant {_exportPaidFee(id);}
    function _debitProtocolFee(address asset,uint256 amount) internal override {fees[asset]-=amount;}
    function _checkFeeSolvency(address asset) internal view override {
        if((asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this)))<fees[asset])revert FeeAttributionError();
    }
}

contract FeeAwareCrossExecution is MainnetCrossProRataExecution,FeeAttributedCollector,PriceContextConsumer {
 function _contextPricing() internal view override returns(address){return address(coordinator.liquidity().pricing());}
    constructor(MainnetProRataExecution execution,V2NativeQuoteAdapter adapter) MainnetCrossProRataExecution(execution,adapter){}
    function _beginFeeExecution() internal override {_enterResolvedFeePayer();}
    function _endFeeExecution() internal override {_leaveFeePayer();}
    function _recordCoordinatorFee(address asset,uint256 amount) internal override {
        super._recordCoordinatorFee(asset,amount);_capturePaidFee(currentFeePayer,asset,amount);
    }
    function exportFee(uint256 id) external nonReentrant {_exportPaidFee(id);}
    function _debitProtocolFee(address asset,uint256 amount) internal override {fees[asset]-=amount;}
    function _checkFeeSolvency(address asset) internal view override {
        if((asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this)))<fees[asset])revert FeeAttributionError();
    }
}
