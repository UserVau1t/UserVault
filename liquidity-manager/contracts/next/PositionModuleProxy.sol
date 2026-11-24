// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

interface IPositionModuleIdentity {function moduleBinding() external view returns(bytes32);}

/// The administrator can replace bound module code immediately. Accounting and mandates
/// remain at the module's stable address.
contract PositionModuleProxy is Proxy {
    bytes32 private constant SLOT=keccak256("UserVault.PositionModuleProxy.upgrades.v1");
    uint256 public constant UPDATE_DELAY=0;
    address public immutable administrator;
    struct Upgrade {bytes32 binding;}
    error InvalidUpdate();

    constructor(address administrator_) {
        if(block.chainid!=4663 || administrator_==address(0)) revert InvalidUpdate();
        administrator=administrator_;
    }
    function _state() private pure returns(Upgrade storage s) {
        bytes32 slot=SLOT;
        assembly ("memory-safe"){s.slot:=slot}
    }
    function moduleImplementation() public view returns(address){return ERC1967Utils.getImplementation();}
    function installedBinding() external view returns(bytes32){return _state().binding;}
    function _implementation() internal view override returns(address impl){
        impl=moduleImplementation();
        if(impl==address(0)) revert InvalidUpdate();
    }
    function installModule(address impl,bytes32 runtimeHash,bytes32 binding) external {
        if(msg.sender!=administrator || moduleImplementation()!=address(0) || binding==0) revert InvalidUpdate();
        _check(impl,runtimeHash,binding);
        _state().binding=binding;
        ERC1967Utils.upgradeToAndCall(impl,"");
    }
    function upgradeModule(address impl,bytes32 runtimeHash) external {
        bytes32 binding=_state().binding;
        if(msg.sender!=administrator || binding==0 || impl==moduleImplementation()) revert InvalidUpdate();
        _check(impl,runtimeHash,binding);
        ERC1967Utils.upgradeToAndCall(impl,"");
    }
    function _check(address impl,bytes32 hash,bytes32 binding) private view {
        if(impl==address(this) || impl.code.length==0 || impl.codehash!=hash ||
            IPositionModuleIdentity(impl).moduleBinding()!=binding) revert InvalidUpdate();
    }
}
