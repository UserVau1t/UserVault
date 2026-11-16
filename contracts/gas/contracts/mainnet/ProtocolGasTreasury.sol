pragma solidity ^0.8.30;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IProtocolGasFunds {
    function owner() external view returns(address);
    function FEE_SPLIT_VERSION() external view returns(uint256);
    function claimableModuleFee(address recipient) external view returns(uint256);
    function claimModuleFee(uint256 amountETH) external;
}

contract ProtocolGasTreasury is Ownable2Step {
    IProtocolGasFunds public immutable distribution;
    bytes32 public immutable distributionHash;
    address payable public immutable keeper;
    uint256 public refillBelow;
    uint256 public refillTarget;
    uint256 public totalKeeperFunding;
    uint256 private entered;
    error InvalidConfiguration();
    error DistributionChanged();
    error Reentrancy();
    error InvalidWithdrawal();
    error PaymentFailed();
    event KeeperFunded(uint256 amountETH,uint256 balanceAfter);
    event KeeperFundingDeferred(uint256 requestedETH);
    event ProjectFundsCollected(uint256 amountETH);
    event ProjectFundsWithdrawn(address indexed recipient,uint256 amountETH);
    event RefillLevelsChanged(uint256 below,uint256 target);

    constructor(address funds,address administrator,address payable feeKeeper,uint256 below,uint256 target)
        Ownable(administrator) {
        if(block.chainid!=4663||funds.code.length==0||feeKeeper==address(0)||feeKeeper==administrator
            ||feeKeeper==funds||feeKeeper==address(this)||administrator==funds)revert InvalidConfiguration();
        distribution=IProtocolGasFunds(funds);distributionHash=funds.codehash;keeper=feeKeeper;
        if(distribution.owner()!=administrator||distribution.FEE_SPLIT_VERSION()!=2)revert InvalidConfiguration();
        _setLevels(below,target);
    }
    modifier nonReentrant(){if(entered!=0)revert Reentrancy();entered=1;_;entered=0;}
    function _pin() private view {if(address(distribution).codehash!=distributionHash)revert DistributionChanged();}
    function _setLevels(uint256 below,uint256 target) private {
        if(below==0||target<=below||target>type(uint128).max)revert InvalidConfiguration();
        refillBelow=below;refillTarget=target;emit RefillLevelsChanged(below,target);
    }
    function setRefillLevels(uint256 below,uint256 target) external onlyOwner nonReentrant {_setLevels(below,target);}
    function availableProjectETH() external view returns(uint256){_pin();return address(this).balance+distribution.claimableModuleFee(address(this));}
    function _collect(uint256 needed) private {
        if(needed==0)return;_pin();
        uint256 amount=distribution.claimableModuleFee(address(this));if(amount>needed)amount=needed;
        if(amount==0)return;
        uint256 beforeBalance=address(this).balance;
        distribution.claimModuleFee(amount);
        if(address(this).balance!=beforeBalance+amount)revert PaymentFailed();
        emit ProjectFundsCollected(amount);
    }

    function refill() external nonReentrant returns(uint256){return _refill();}

    function fund() external payable nonReentrant returns(uint256){return _refill();}
    function _refill() private returns(uint256 amount){
        _pin();uint256 balance=keeper.balance;if(balance>=refillBelow)return 0;
        uint256 needed=refillTarget-balance;
        if(address(this).balance<needed)_collect(needed-address(this).balance);
        amount=address(this).balance;if(amount>needed)amount=needed;if(amount==0)return 0;

        (bool ok,)=keeper.call{value:amount,gas:30000}("");
        if(!ok){emit KeeperFundingDeferred(amount);return 0;}
        totalKeeperFunding+=amount;emit KeeperFunded(amount,keeper.balance);
    }
    function withdrawProject(address payable recipient,uint256 amount) external onlyOwner nonReentrant {
        if(recipient==address(0)||recipient==address(this)||amount==0)revert InvalidWithdrawal();
        _pin();if(address(this).balance<amount)_collect(amount-address(this).balance);
        if(address(this).balance<amount)revert InvalidWithdrawal();
        (bool ok,)=recipient.call{value:amount}("");if(!ok)revert PaymentFailed();
        emit ProjectFundsWithdrawn(recipient,amount);
    }

    receive() external payable {}
}
