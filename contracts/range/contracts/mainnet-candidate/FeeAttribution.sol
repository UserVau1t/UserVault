pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MainnetFeeProcessing} from "./MainnetFeeProcessing.sol";
interface IFeePayerContext {
    function currentFeePayer() external view returns(address);
    function currentFeeCashbackEligible() external view returns(bool);
}

abstract contract FeePayerContext {
    address internal immutable feeInstaller=msg.sender;
    mapping(address=>bytes32) public feeParentHash;
    bool public feeParentsConfigured;
    address public currentFeePayer;
    bool public currentFeeCashbackEligible;
    error FeeAttributionError();
    constructor(){if(block.chainid!=4663)revert FeeAttributionError();}
    function configureFeeParents(address[] calldata parents) external virtual {
        if(msg.sender!=feeInstaller||feeParentsConfigured)revert FeeAttributionError();
        feeParentsConfigured=true;
        for(uint256 i=0;i<parents.length;i++){
            address parent=parents[i];
            if(parent==address(this)||parent.code.length==0||feeParentHash[parent]!=bytes32(0))revert FeeAttributionError();
            feeParentHash[parent]=parent.codehash;
        }
    }
    function _resolveFeePayer(address caller) internal view returns(address payer){
        if(!feeParentsConfigured)revert FeeAttributionError();
        bytes32 pinned=feeParentHash[caller];
        if(pinned==bytes32(0))return caller;
        if(caller.codehash!=pinned)revert FeeAttributionError();
        payer=IFeePayerContext(caller).currentFeePayer();
        if(payer==address(0)||payer==address(this))revert FeeAttributionError();
    }
    function _enterFeePayer(address payer) internal {
        _enterFeePayer(payer,true);
    }
    function _resolveCashbackEligible(address caller) internal view returns(bool){
        bytes32 pinned=feeParentHash[caller];
        if(pinned==bytes32(0))return true;
        if(caller.codehash!=pinned)revert FeeAttributionError();
        return IFeePayerContext(caller).currentFeeCashbackEligible();
    }
    function _enterResolvedFeePayer() internal {
        _enterFeePayer(_resolveFeePayer(msg.sender),_resolveCashbackEligible(msg.sender));
    }
    function _enterFeePayer(address payer,bool eligible) internal {
        if(currentFeePayer!=address(0)||payer==address(0)||payer==address(this))revert FeeAttributionError();
        currentFeePayer=payer;currentFeeCashbackEligible=eligible;
    }
    function _leaveFeePayer() internal {currentFeePayer=address(0);currentFeeCashbackEligible=false;}
}

abstract contract FeeAttributedCollector is FeePayerContext {
    using SafeERC20 for IERC20;
    struct PaidFee {address payer;address asset;uint256 amount;bool exported;bool cashbackEligible;}
    mapping(uint256=>PaidFee) public paidFees;
    uint256 public nextPaidFee;
    MainnetFeeProcessing public feeProcessor;
    event ProtocolFeeAttributed(uint256 indexed id,address indexed payer,address indexed asset,uint256 amount);
    event ProtocolFeeExported(uint256 indexed id,bytes32 indexed processorKey);
    event ProtocolFeeEligibility(uint256 indexed id,bool cashbackEligible);
    function bindFeeProcessor(MainnetFeeProcessing processor) external virtual {
        if(msg.sender!=feeInstaller||address(feeProcessor)!=address(0)||address(processor).code.length==0
            ||processor.collectorHash(address(this))!=address(this).codehash)revert FeeAttributionError();
        feeProcessor=processor;
    }
    function _capturePaidFee(address payer,address asset,uint256 amount) internal {
        if(amount==0)return;
        if(payer==address(0)||payer==address(this))revert FeeAttributionError();
        uint256 id=++nextPaidFee;
        bool eligible=currentFeePayer!=address(0)?currentFeeCashbackEligible:_resolveCashbackEligible(msg.sender);
        paidFees[id]=PaidFee(payer,asset,amount,false,eligible);
        emit ProtocolFeeAttributed(id,payer,asset,amount);
        emit ProtocolFeeEligibility(id,eligible);
    }
    function _exportPaidFee(uint256 id) internal {
        PaidFee storage f=paidFees[id];
        if(address(feeProcessor)==address(0)||f.payer==address(0)||f.exported)revert FeeAttributionError();
        f.exported=true;
        _debitProtocolFee(f.asset,f.amount);
        if(f.asset!=address(0))IERC20(f.asset).forceApprove(address(feeProcessor),f.amount);
        bytes32 key=feeProcessor.recordAttributedFee{value:f.asset==address(0)?f.amount:0}(bytes32(id),f.payer,f.asset,f.amount,f.cashbackEligible);
        if(f.asset!=address(0))IERC20(f.asset).forceApprove(address(feeProcessor),0);
        _checkFeeSolvency(f.asset);
        emit ProtocolFeeExported(id,key);
    }
    function _debitProtocolFee(address asset,uint256 amount) internal virtual;
    function _checkFeeSolvency(address asset) internal view virtual;
}
