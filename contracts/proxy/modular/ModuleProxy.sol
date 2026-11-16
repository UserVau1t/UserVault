pragma solidity ^0.8.30;
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ModuleProxy is BeaconProxy {
    error InvalidGenesisStorage();
    constructor(address beacon,bytes32[] memory slots,bytes32[] memory values) BeaconProxy(beacon,"") {
        if(slots.length!=values.length||slots.length>64)revert InvalidGenesisStorage();
        for(uint256 i;i<slots.length;i++){
            bytes32 slot=slots[i];bytes32 value=values[i];
            if(slot==ERC1967Utils.BEACON_SLOT||slot==ERC1967Utils.IMPLEMENTATION_SLOT||slot==ERC1967Utils.ADMIN_SLOT)
                revert InvalidGenesisStorage();
            for(uint256 j;j<i;j++)if(slots[j]==slot)revert InvalidGenesisStorage();
            bytes32 previous;assembly("memory-safe"){previous:=sload(slot)}
            if(previous!=bytes32(0))revert InvalidGenesisStorage();
            assembly("memory-safe"){sstore(slot,value)}
        }
    }
}

contract UninstalledModule {
    error ModuleNotInstalled();
    fallback() external payable {revert ModuleNotInstalled();}
}

contract ModuleInstaller is Ownable {
    struct Module {address proxy;address beacon;address implementation;}
    struct Reservation {bytes32 role;bytes32[] slots;bytes32[] values;}
    mapping(bytes32=>Module) public modules;
    bytes32[] public roles;
    address public immutable placeholder;
    bool public installationSealed;
    error InvalidModule();
    event Reserved(bytes32 indexed role,address proxy,address beacon);
    event Installed(bytes32 indexed role,address implementation,bytes32 codeHash);
    event ImplementationDeployed(address implementation,bytes32 codeHash);
    event InstallationCompleted();
    constructor(address administrator) Ownable(administrator){placeholder=address(new UninstalledModule());}

    function administrator() external view returns(address){return owner();}
    function vault() external view returns(address){return modules[keccak256("vault")].proxy;}
    function pricing() external view returns(address){return modules[keccak256("pricing")].proxy;}
    function reserve(Reservation[] calldata entries) external onlyOwner {
        if(installationSealed||entries.length==0||roles.length+entries.length>32)revert InvalidModule();
        for(uint256 i;i<entries.length;i++){
            Reservation calldata e=entries[i];if(e.role==bytes32(0)||modules[e.role].proxy!=address(0))revert InvalidModule();
            UpgradeableBeacon beacon=new UpgradeableBeacon(placeholder,address(this));
            ModuleProxy proxy=new ModuleProxy(address(beacon),e.slots,e.values);
            modules[e.role]=Module(address(proxy),address(beacon),address(0));roles.push(e.role);
            emit Reserved(e.role,address(proxy),address(beacon));
        }
    }
    function install(bytes32 role,bytes calldata creationCode,bytes32 expectedCodeHash) external onlyOwner returns(address implementation){
        Module storage m=modules[role];
        if(installationSealed||m.proxy==address(0)||m.implementation!=address(0)||creationCode.length==0||creationCode.length>49152)revert InvalidModule();
        implementation=_deploy(creationCode,expectedCodeHash);
        m.implementation=implementation;UpgradeableBeacon(m.beacon).upgradeTo(implementation);
        UpgradeableBeacon(m.beacon).transferOwnership(owner());
        emit Installed(role,implementation,expectedCodeHash);
    }
    function deployImplementation(bytes calldata creationCode,bytes32 expectedCodeHash) external onlyOwner returns(address){
        return _deploy(creationCode,expectedCodeHash);
    }
    function _deploy(bytes calldata creationCode,bytes32 expectedCodeHash) private returns(address implementation){
        if(creationCode.length==0||creationCode.length>49152)revert InvalidModule();bytes memory code=creationCode;
        assembly("memory-safe"){implementation:=create(0,add(code,32),mload(code))}
        if(implementation.code.length==0||implementation.codehash!=expectedCodeHash)revert InvalidModule();
        emit ImplementationDeployed(implementation,expectedCodeHash);
    }
    function wire(bytes32 role,bytes calldata data) external onlyOwner returns(bytes memory result){
        Module storage m=modules[role];if(installationSealed||m.implementation==address(0)||data.length<4)revert InvalidModule();
        bytes4 selector=bytes4(data[:4]);
        if(selector!=bytes4(keccak256("configureFeeParents(address[])"))
          &&selector!=bytes4(keccak256("bindFeeProcessor(address)"))
          &&selector!=bytes4(keccak256("bindSharedDistribution(address)")))revert InvalidModule();
        bool ok;(ok,result)=m.proxy.call(data);if(!ok){assembly("memory-safe"){revert(add(result,32),mload(result))}}
    }
    function seal() external onlyOwner {
        if(installationSealed||roles.length==0)revert InvalidModule();
        for(uint256 i;i<roles.length;i++){Module storage m=modules[roles[i]];
            if(m.implementation==address(0)||UpgradeableBeacon(m.beacon).owner()!=owner())revert InvalidModule();
        }
        installationSealed=true;emit InstallationCompleted();
    }
}
