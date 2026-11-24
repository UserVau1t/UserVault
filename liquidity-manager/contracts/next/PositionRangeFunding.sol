// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PositionFunding,PositionFeeSwap,LMPoolKey} from "./PositionFunding.sol";
import {PositionCompoundController} from "./PositionCompoundController.sol";
import {PositionPayout} from "./PositionPayout.sol";
import {LiquidityControllerCore} from "../LiquidityControllerV2.sol";

interface IRangeModule {function moduleImplementation() external view returns(address);}
interface IPreviousSubscription {function subscriber(uint256 id) external view returns(address);function unsubscribe(uint256 id) external payable;}

interface IConfigureMintedStrategy {
    function configurePayout(uint256 id,address owner,PositionCompoundController.Policy calldata policy,
        int24 low,int24 high,uint48 deadline,uint8 mode) external;
    function configureMinted(uint256 id,address owner,PositionCompoundController.Policy calldata policy,
        int24 lowerOffset,int24 upperOffset,uint48 deadline) external;
}

/// Stable spender for wallet deposits and NFT authorization in the sponsored release.
contract PositionRangeFunding is PositionFunding {
    address private constant V42_LEDGER=address(uint160(0x008b4b4bdf79bd7c5545d08d72eac5543e3102b54a));
    address private constant V42_CONTROLLER=address(uint160(0x002f65739ebf5595fc9e9aeb0da358da5f7f08cde9));
    IRangeModule public immutable rangeModule;
    constructor(address treasury_,address controller_,IRangeModule range_) PositionFunding(treasury_,controller_) {
        if(address(range_).code.length==0) revert InvalidInput();
        rangeModule=range_;
    }

    struct RangePlan {
        uint256 id;
        uint64 nonce;
        uint48 deadline;
        int24 lower;
        int24 upper;
        uint128 previousLiquidity;
        uint128 minimumLiquidity;
        uint128 expectedOut;
        bool forward;
        PositionFeeSwap.Quote swap;
        bytes marketProof;
        bytes marketRoute;
    }
    struct Reserve {address owner; address currency; address module; uint256 amount; bool includeFees;}

    function moduleBinding() external view returns(bytes32) {
        return keccak256(abi.encode("PositionRangeFunding.storage.v1",treasury,automationController,rangeModule));
    }

    // A V4.2 owner explicitly moves this NFT when enrolling in the new controller.
    // Uniswap notifies the old ledger and retires the old keeper strategy atomically.
    function attachAutomation(uint256 id,address observer) public override {
        if(msg.sender!=automationController) revert Unauthorized();
        IPreviousSubscription manager=IPreviousSubscription(address(PM));
        if(manager.subscriber(id)==V42_LEDGER){
            manager.unsubscribe(id);
            if(LiquidityControllerCore(payable(V42_CONTROLLER)).strategy(id).owner!=address(0)) revert Unauthorized();
        }
        super.attachAutomation(id,observer);
    }

    function createAutomated(LMPoolKey calldata key,int24 lower,int24 upper,uint160 initialPrice,Deposit calldata deposit,
        PositionCompoundController.Policy calldata policy,int24 lowerOffset,int24 upperOffset) external payable returns(uint256 id) {
        id=create(key,lower,upper,initialPrice,deposit);
        IConfigureMintedStrategy(automationController).configureMinted(id,msg.sender,policy,lowerOffset,upperOffset,deposit.deadline);
    }

    event RangeFunded(uint256 indexed oldId,uint256 indexed newId,uint128 liquidity,
        uint256 moved0,uint256 moved1,uint256 fee0,uint256 fee1);

    function createWithPayout(LMPoolKey calldata key,int24 lower,int24 upper,uint160 initialPrice,Deposit calldata deposit,
        PositionCompoundController.Policy calldata policy,int24 low,int24 high,uint8 mode) external payable returns(uint256 id) {
        id=create(key,lower,upper,initialPrice,deposit);
        IConfigureMintedStrategy(automationController).configurePayout(id,msg.sender,policy,low,high,deposit.deadline,mode);
    }
    function payoutFor(PositionPayout.Plan calldata p,PositionPayout.Terms calldata) external locked(p.deadline) {
        _executeRangeModule();
    }

    function moveRange(RangePlan calldata p,Reserve calldata r) external locked(p.deadline) returns(uint256 newId) {
        return abi.decode(_executeRangeModule(),(uint256));
    }
    function _executeRangeModule() private returns(bytes memory) {
        if(msg.sender!=automationController) revert Unauthorized();
        address impl=rangeModule.moduleImplementation();
        if(impl.code.length==0) revert InvalidInput();
        (bool ok,bytes memory result)=impl.delegatecall(msg.data);
        if(!ok) assembly ("memory-safe"){revert(add(result,32),mload(result))}
        return result;
    }
}
