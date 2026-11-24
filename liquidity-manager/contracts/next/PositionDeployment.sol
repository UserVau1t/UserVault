// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PositionModuleProxy} from "./PositionModuleProxy.sol";
import {PositionObserver} from "./PositionObserver.sol";
import {PositionPayment, IERC20} from "./PositionPayment.sol";

/// Stable fee recipient and initial directory. The administrator owns each proxy directly.
contract PositionDeployment {
    address public immutable owner;
    address public immutable observer;
    address public immutable funding;
    address public immutable controller;
    address public immutable gasModule;
    address public immutable rangeModule;
    error InvalidWithdrawal();
    event TreasuryWithdrawal(address indexed currency,address indexed recipient,uint256 amount);

    constructor(address admin) {
        if(admin==address(0) || msg.sender!=admin) revert InvalidWithdrawal();
        owner=admin;
        observer=address(new PositionObserver());
        funding=address(new PositionModuleProxy(admin));
        controller=address(new PositionModuleProxy(admin));
        gasModule=address(new PositionModuleProxy(admin));
        rangeModule=address(new PositionModuleProxy(admin));
    }

    receive() external payable {}
    function treasuryEth() public view returns(uint256){return address(this).balance;}
    function withdrawTreasury(address payable recipient,uint256 amount) external {
        withdrawAsset(address(0),recipient,amount);
    }
    function withdrawAsset(address currency,address recipient,uint256 amount) public {
        if(msg.sender!=owner || recipient==address(0) || recipient==address(this)) revert InvalidWithdrawal();
        uint256 available=currency==address(0)?treasuryEth():IERC20(currency).balanceOf(address(this));
        if(amount==type(uint256).max) amount=available;
        if(amount==0 || amount>available) revert InvalidWithdrawal();
        PositionPayment.pay(currency,recipient,amount);
        emit TreasuryWithdrawal(currency,recipient,amount);
    }
}
