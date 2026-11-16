pragma solidity ^0.8.30;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {MainnetFeeDistribution} from "./MainnetFeeDistribution.sol";

contract MainnetSharedFeeDistribution is MainnetFeeDistribution,Ownable2Step {

    uint256 public constant SHARE_UNITS_PER_WEI=100000000;
    uint256 public constant FEE_SPLIT_VERSION=2;
    uint16 public constant CASHBACK_SHARE_BPS=1500;
    uint256 public constant TREASURY_WITHDRAWAL_VERSION=1;
    uint256 public constant BURN_TREASURY_WITHDRAWAL_VERSION=1;
    event ProjectTreasuryWithdrawn(address indexed administrator,address indexed recipient,uint256 amountETH);
    event BurnTreasuryWithdrawn(address indexed administrator,address indexed recipient,uint256 amountETH);
    uint16 public constant MIN_BURN_SHARE_BPS=100;
    uint16 public constant MAX_BURN_SHARE_BPS=2500;
    uint16 public burnShareBps=2500;
    uint16 public moduleShareBps;
    struct FeeModule {address recipient;uint16 shareBps;}
    FeeModule[] public feeModules;
    mapping(address=>uint256) public moduleUnits;
    event FeeModulesConfigured(address[] recipients,uint16[] sharesBps);
    event ModuleFeeClaimed(address indexed recipient,uint256 amountETH);
    event BurnShareChanged(uint16 previousBps,uint16 nextBps);
    event FeeSplitApplied(bytes32 indexed feeId,uint32 treasuryUnitsPerWei,uint32 burnUnitsPerWei,uint32 cashbackUnitsPerWei);
    event FeeCashbackEligibility(bytes32 indexed feeId,bool eligible);
    bytes32 public immutable controllerHash;
    uint256 public totalDonatedBurnETH;
    event BurnPaid(address indexed recipient,uint256 amountETH);
    event BurnDonation(address indexed donor,uint256 amountETH);
    constructor(address source,address projectTreasury,address burnController,address administrator)
        MainnetFeeDistribution(source,projectTreasury,burnController) Ownable(administrator) {
        if(burnController.code.length==0)revert InvalidConfiguration();
        controllerHash=burnController.codehash;
    }

    function treasuryShareBps() public view returns(uint16){return 10000-burnShareBps-moduleShareBps;}
    function feeModuleCount() external view returns(uint256){return feeModules.length;}

    function withdrawProjectTreasury(address recipient,uint256 amountETH) external onlyOwner nonReentrant {
        if(recipient==address(0)||recipient==address(this))revert InvalidClaim();
        treasuryUnits-=_claimUnits(amountETH,treasuryUnits);
        _pay(recipient,amountETH);
        emit ProjectTreasuryWithdrawn(msg.sender,recipient,amountETH);
    }

    function withdrawBurnTreasury(address recipient,uint256 amountETH) external onlyOwner nonReentrant {
        if(recipient==address(0)||recipient==address(this)||recipient==burnTreasury)revert InvalidClaim();
        burnUnits-=_claimUnits(amountETH,burnUnits);
        _pay(recipient,amountETH);
        emit BurnTreasuryWithdrawn(msg.sender,recipient,amountETH);
    }

    function configureFeeModules(address[] calldata recipients,uint16[] calldata shares) external onlyOwner nonReentrant {
        if(recipients.length!=shares.length)revert InvalidConfiguration();
        uint256 sum;address previous;
        delete feeModules;
        for(uint256 i;i<recipients.length;i++){
            address recipient=recipients[i];
            if(recipient<=previous||recipient.code.length==0||recipient==address(this)||recipient==burnTreasury
                ||recipient==treasury||shares[i]==0)revert InvalidConfiguration();
            sum+=shares[i];previous=recipient;
            feeModules.push(FeeModule(recipient,shares[i]));
        }
        if(sum+burnShareBps>10000)revert InvalidConfiguration();
        moduleShareBps=uint16(sum);emit FeeModulesConfigured(recipients,shares);
    }
    function claimableModuleFee(address recipient) external view returns(uint256){return moduleUnits[recipient]/_unitScale();}
    function claimModuleFee(uint256 amountETH) external nonReentrant {
        moduleUnits[msg.sender]-=_claimUnits(amountETH,moduleUnits[msg.sender]);
        _pay(msg.sender,amountETH);emit ModuleFeeClaimed(msg.sender,amountETH);
    }
    function setBurnShareBps(uint16 next) external onlyOwner nonReentrant {
        if(next<MIN_BURN_SHARE_BPS||next>MAX_BURN_SHARE_BPS||uint256(next)+moduleShareBps>10000)revert InvalidConfiguration();
        uint16 previous=burnShareBps;burnShareBps=next;emit BurnShareChanged(previous,next);
    }

    function fundConvertedFee(bytes32,address) external payable override {revert InvalidFee();}
    function fundAttributedFee(bytes32 feeId,address payer,bool cashbackEligible) external payable nonReentrant {
        if(msg.sender!=settlementSource||msg.sender.codehash!=settlementSourceCodeHash)revert Unauthorized();
        if(feeId==bytes32(0)||recordedFee[feeId]||payer==address(0)||payer==address(this)||msg.value==0)revert InvalidFee();
        recordedFee[feeId]=true;
        uint32 cashback=cashbackEligible?uint32(CASHBACK_SHARE_BPS)*10000:0;
        uint32 remainder=cashbackEligible?10000-CASHBACK_SHARE_BPS:10000;
        uint32 burn=remainder*uint32(burnShareBps);
        uint32 project=remainder*uint32(treasuryShareBps());
        for(uint256 i;i<feeModules.length;i++){
            FeeModule memory m=feeModules[i];moduleUnits[m.recipient]+=msg.value*remainder*m.shareBps;
        }
        treasuryUnits+=msg.value*project;burnUnits+=msg.value*burn;cashbackUnits[payer]+=msg.value*cashback;
        accountedETH+=msg.value;totalFundedETH+=msg.value;
        emit FeeFunded(feeId,payer,msg.value);
        emit FeeSplitApplied(feeId,project,burn,cashback);
        emit FeeCashbackEligibility(feeId,cashbackEligible);
    }
    function _unitScale() internal pure override returns(uint256){return SHARE_UNITS_PER_WEI;}
    function controller() external view returns(address){return burnTreasury;}
    function availableBurnETH() external view returns(uint256){return burnUnits/_unitScale();}

    function claimBurnTreasury(uint256) external pure override {revert Unauthorized();}
    function payBurn(address recipient,uint256 amountETH) external nonReentrant {
        if(msg.sender!=burnTreasury||msg.sender.codehash!=controllerHash||recipient==address(0)||recipient==address(this))revert Unauthorized();
        burnUnits-=_claimUnits(amountETH,burnUnits);
        _pay(recipient,amountETH);
        emit BurnPaid(recipient,amountETH);
    }

    function fundBurn() external payable nonReentrant {
        if(msg.value==0)revert InvalidFee();
        burnUnits+=msg.value*_unitScale();accountedETH+=msg.value;totalDonatedBurnETH+=msg.value;
        emit BurnDonation(msg.sender,msg.value);
    }
}
