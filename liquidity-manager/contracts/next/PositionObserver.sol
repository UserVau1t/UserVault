// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IPositionNotifications {
    function subscriber(uint256 id) external view returns (address);
    function subscribe(uint256 id,address observer,bytes calldata data) external payable;
}

/// One stable, read-only subscriber shared by the automation modules. Reattachment always
/// starts a new epoch even if Uniswap could not deliver a previous unsubscribe callback.
contract PositionObserver {
    IPositionNotifications internal constant PM = IPositionNotifications(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    mapping(uint256 => uint64) private generations;
    error Unauthorized();

    constructor() { if (block.chainid != 4663) revert Unauthorized(); }
    modifier onlyManager() { if (msg.sender != address(PM)) revert Unauthorized(); _; }
    function epoch(uint256 id) external view returns (uint64) {
        return PM.subscriber(id) == address(this) ? generations[id] : 0;
    }
    function notifySubscribe(uint256 id,bytes calldata) external onlyManager { ++generations[id]; }
    function notifyUnsubscribe(uint256) external view onlyManager {}
    function notifyBurn(uint256,address,uint256,uint256,int256) external view onlyManager {}
    function notifyModifyLiquidity(uint256,int256,int256) external view onlyManager {}
}
