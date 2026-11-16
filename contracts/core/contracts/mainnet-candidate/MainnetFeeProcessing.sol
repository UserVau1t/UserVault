pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MainnetFeeDistribution} from "./MainnetFeeDistribution.sol";

interface IFeeProcessingPolicy {
    function supportsAsset(address asset) external view returns(bool);
    function valueUsd(address asset,uint256 amount) external view returns(uint256 usd18);
    function minimumETH(address asset,uint256 amount,bytes calldata route) external view returns(uint256);
    function validateAfter(address asset,uint256 amount,uint256 output,bytes calldata route) external view;
}
interface IFeeETHConverter {
    function supportsAsset(address asset) external view returns(bool);
    function convert(address asset,uint256 amount,uint256 minimum,uint256 deadline,bytes calldata route)
        external returns(uint256 reportedOutput);
}

contract MainnetFeeProcessing {
    using SafeERC20 for IERC20;
    function PROCESS_MIN_USD18() public pure virtual returns(uint256){return 10e18;}
    IFeeProcessingPolicy public immutable policy;
    IFeeETHConverter public immutable converter;
    bytes32 public immutable policyHash;
    bytes32 public immutable converterHash;
    address internal immutable installer;
    MainnetFeeDistribution public distribution;
    mapping(address=>bytes32) public collectorHash;
    mapping(address=>uint256) public currentEpoch;
    mapping(address=>uint256) public pending;
    mapping(address=>mapping(uint256=>uint256)) public processedInput;
    uint256 public reservedETH;
    uint256 private entered;
    struct Epoch { uint256 input; uint256 output; uint256 allocated; bool converted; }
    struct Fee { address asset; address payer; uint256 epoch; uint256 start; uint256 amount; bool allocated; }
    mapping(address=>mapping(uint256=>Epoch)) public epochs;
    mapping(bytes32=>Fee) public fees;
    mapping(bytes32=>bool) public feeCashbackEligible;
    event FeeEligibilityRecorded(bytes32 indexed feeId,bool cashbackEligible);
    error InvalidConfiguration(); error Unauthorized(); error InvalidFee();
    error InvalidProcessing(); error BalanceMismatch(); error Reentrancy();
    event FeeReceived(bytes32 indexed feeId,address indexed collector,address indexed payer,address asset,uint256 epoch,uint256 start,uint256 amount);
    event EpochConverted(address indexed asset,uint256 indexed epoch,uint256 input,uint256 outputETH);
    event EpochPartConverted(address indexed asset,uint256 indexed epoch,uint256 input,uint256 outputETH,uint256 remaining);
    event FeeAllocated(bytes32 indexed feeId,address indexed payer,uint256 outputETH);
    constructor(address[] memory collectors,IFeeProcessingPolicy p,IFeeETHConverter c) {
        if(block.chainid!=4663||collectors.length==0||address(p).code.length==0||address(c).code.length==0)
            revert InvalidConfiguration();
        installer=msg.sender;policy=p;converter=c;policyHash=address(p).codehash;converterHash=address(c).codehash;
        for(uint256 i=0;i<collectors.length;i++){
            address source=collectors[i];
            if(source.code.length==0||collectorHash[source]!=bytes32(0))revert InvalidConfiguration();
            collectorHash[source]=source.codehash;
        }
    }
    modifier nonReentrant(){if(entered!=0)revert Reentrancy();entered=1;_;entered=0;}

    function createDistribution(address treasury,address burnTreasury) external virtual {
        if(msg.sender!=installer||address(distribution)!=address(0))revert InvalidConfiguration();
        distribution=new MainnetFeeDistribution(address(this),treasury,burnTreasury);
    }
    function feeKey(address collector,bytes32 localId) public view returns(bytes32){
        return keccak256(abi.encode("uservault.new-fee.v1",block.chainid,collector,localId));
    }

    function recordFee(bytes32 localId,address payer,address asset,uint256 amount) external payable virtual nonReentrant returns(bytes32 key){
        return _recordFee(localId,payer,asset,amount,true);
    }
    function recordAttributedFee(bytes32 localId,address payer,address asset,uint256 amount,bool eligible) external payable nonReentrant returns(bytes32 key){
        return _recordFee(localId,payer,asset,amount,eligible);
    }
    function _recordFee(bytes32 localId,address payer,address asset,uint256 amount,bool eligible) internal returns(bytes32 key){
        bytes32 pinned=collectorHash[msg.sender];
        if(pinned==bytes32(0)||msg.sender.codehash!=pinned)revert Unauthorized();
        if(address(distribution)==address(0)||localId==bytes32(0)||amount==0||payer==address(0)
            ||payer==address(this)||payer==address(distribution)||asset==address(this)||asset==address(distribution))revert InvalidFee();

        if(address(policy).codehash!=policyHash||address(converter).codehash!=converterHash
            ||!policy.supportsAsset(asset)||(asset!=address(0)&&!converter.supportsAsset(asset)))revert InvalidFee();

        if(processedInput[asset][currentEpoch[asset]]!=0)revert InvalidFee();
        key=feeKey(msg.sender,localId);if(fees[key].payer!=address(0))revert InvalidFee();
        if(asset==address(0)){if(msg.value!=amount)revert BalanceMismatch();}
        else{
            if(msg.value!=0||asset.code.length==0)revert InvalidFee();
            uint256 beforeBalance=IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransferFrom(msg.sender,address(this),amount);
            if(IERC20(asset).balanceOf(address(this))-beforeBalance!=amount)revert BalanceMismatch();
        }
        uint256 epoch=currentEpoch[asset];Epoch storage e=epochs[asset][epoch];
        fees[key]=Fee(asset,payer,epoch,e.input,amount,false);e.input+=amount;pending[asset]+=amount;
        feeCashbackEligible[key]=eligible;
        emit FeeEligibilityRecorded(key,eligible);
        emit FeeReceived(key,msg.sender,payer,asset,epoch,e.input-amount,amount);
    }

    function process(address asset,uint256 minimumETH,uint256 deadline,bytes calldata route) external nonReentrant {
        uint256 epoch=currentEpoch[asset];
        _process(asset,epochs[asset][epoch].input-processedInput[asset][epoch],minimumETH,deadline,route);
    }
    function processingMinimumUsd18() public pure returns(uint256){return PROCESS_MIN_USD18();}
    function _checkBatch(address asset,uint256 amount,uint256 remaining,uint256 alreadyProcessed) internal view virtual {
        if(amount!=remaining||alreadyProcessed!=0||policy.valueUsd(asset,amount)<processingMinimumUsd18())revert InvalidProcessing();
    }
    function _process(address asset,uint256 amount,uint256 minimumETH,uint256 deadline,bytes memory route) internal {
        if(address(distribution)==address(0)||block.timestamp>deadline||address(policy).codehash!=policyHash
            ||address(converter).codehash!=converterHash)revert InvalidProcessing();
        uint256 epoch=currentEpoch[asset];Epoch storage e=epochs[asset][epoch];
        uint256 processed=processedInput[asset][epoch];uint256 remaining=e.input-processed;
        if(amount==0||amount>remaining||e.converted||pending[asset]!=remaining)revert InvalidProcessing();
        _checkBatch(asset,amount,remaining,processed);
        uint256 output=_convert(asset,amount,minimumETH,deadline,route);
        if(address(policy).codehash!=policyHash||address(converter).codehash!=converterHash)revert InvalidProcessing();
        processedInput[asset][epoch]=processed+amount;e.output+=output;pending[asset]=remaining-amount;reservedETH+=output;
        if(amount==remaining){
            e.converted=true;currentEpoch[asset]=epoch+1;
            emit EpochConverted(asset,epoch,e.input,e.output);
        }else emit EpochPartConverted(asset,epoch,amount,output,remaining-amount);
    }
    function _convert(address asset,uint256 amount,uint256 minimumETH,uint256 deadline,bytes memory route) private returns(uint256 output){
        if(asset==address(0)){
            if(route.length!=0||minimumETH>amount||address(this).balance<reservedETH+amount)revert InvalidProcessing();
            output=amount;
        }else{
            uint256 floor=policy.minimumETH(asset,amount,route);
            if(floor==0||minimumETH<floor)revert InvalidProcessing();
            uint256 nativeBefore=address(this).balance;
            uint256 tokenBefore=IERC20(asset).balanceOf(address(this));
            IERC20(asset).forceApprove(address(converter),amount);
            uint256 reported=converter.convert(asset,amount,minimumETH,deadline,route);
            IERC20(asset).forceApprove(address(converter),0);
            output=address(this).balance-nativeBefore;
            if(tokenBefore-IERC20(asset).balanceOf(address(this))!=amount||output<minimumETH||reported!=output)
                revert BalanceMismatch();
            policy.validateAfter(asset,amount,output,route);
        }
    }

    function allocate(bytes32 key) external nonReentrant returns(uint256 amountETH){
        Fee storage f=fees[key];Epoch storage e=epochs[f.asset][f.epoch];
        if(f.payer==address(0)||f.allocated||!e.converted)revert InvalidFee();

        amountETH=Math.mulDiv(f.start+f.amount,e.output,e.input)-Math.mulDiv(f.start,e.output,e.input);
        f.allocated=true;e.allocated+=amountETH;reservedETH-=amountETH;
        if(amountETH!=0)_fundAllocation(key,f.payer,amountETH);
        emit FeeAllocated(key,f.payer,amountETH);
    }
    function _fundAllocation(bytes32 key,address payer,uint256 amountETH) internal virtual {
        distribution.fundConvertedFee{value:amountETH}(key,payer);
    }
    receive() external payable {if(msg.sender!=address(converter)||entered!=1)revert Unauthorized();}
}
