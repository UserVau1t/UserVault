pragma solidity ^0.8.30;
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {PassiveCrossMath} from "./PassiveCrossMath.sol";
import {FeeVaultMath} from "./FeeVaultMath.sol";
import {CreateGroupMath} from "./CreateGroupMath.sol";
interface ICreateGraphModule {
    function host() external view returns(address);
    function group() external view returns(address);
    function internalSettlementPolicy() external view returns(address);
}
interface ICreateGraphSnapshot {
    function vault() external view returns(address);
    function limits() external view returns(address);
    function pricing() external view returns(address);
}

interface IInternalPositionSource {
    function vault() external view returns(address);
    function pricing() external view returns(address);
    function internalPositionExecution() external view returns(bool);
}
interface IInternalPolicyVault {
    function internalSettlementPolicy() external view returns(InternalSettlementPolicy);
    function feeParentHash(address parent) external view returns(bytes32);
    function pricing() external view returns(address);
}

contract InternalSettlementPolicy {
    address public immutable installer;

    FeeVaultMath public immutable math;
    CreateGroupMath public immutable groupMath;
    bytes32 public immutable groupMathHash;
    PassiveCrossMath public immutable crossMath;
    bytes32 public immutable crossMathHash;
    address public createModule;
    bytes32 public createModuleHash;
    address public createSnapshot;
    bytes32 public createSnapshotHash;
    address public vault;
    address public pricing;
    address public manager;
    bytes32 public managerHash;
    error InvalidInternalSource();

    constructor(address installer_,FeeVaultMath math_,CreateGroupMath groupMath_,PassiveCrossMath crossMath_) {
        if(address(math_).code.length==0||address(groupMath_).code.length==0||address(crossMath_).code.length==0)revert InvalidInternalSource();
        math=math_;groupMath=groupMath_;crossMath=crossMath_;groupMathHash=address(groupMath_).codehash;crossMathHash=address(crossMath_).codehash;
        if(installer_==address(0))revert InvalidInternalSource();
        installer=installer_;
    }
    function bind(address source) external {
        if(msg.sender!=installer||manager!=address(0)||source.code.length==0
            ||source==address(this))revert InvalidInternalSource();
        bytes32 codeHash=source.codehash;
        address sourceVault=IInternalPositionSource(source).vault();
        address sourcePricing=IInternalPositionSource(source).pricing();
        if(sourceVault.code.length==0||sourcePricing.code.length==0
            ||address(IInternalPolicyVault(sourceVault).internalSettlementPolicy())!=address(this)
            ||IInternalPolicyVault(sourceVault).pricing()!=sourcePricing
            ||IInternalPositionSource(source).internalPositionExecution()
            ||IInternalPolicyVault(sourceVault).feeParentHash(source)!=codeHash)revert InvalidInternalSource();
        vault=sourceVault;pricing=sourcePricing;manager=source;managerHash=codeHash;
    }
    function bindCreation(address module,address snapshot) external {
        if(msg.sender!=installer||manager==address(0)||createModule!=address(0)
            ||module.code.length==0||snapshot.code.length==0
            ||ICreateGraphModule(module).host()!=vault
            ||ICreateGraphModule(module).group()!=snapshot
            ||ICreateGraphModule(module).internalSettlementPolicy()!=address(this)
            ||ICreateGraphSnapshot(snapshot).vault()!=vault
            ||ICreateGraphSnapshot(snapshot).limits()!=manager
            ||ICreateGraphSnapshot(snapshot).pricing()!=pricing
            ||IInternalPolicyVault(manager).feeParentHash(vault)!=vault.codehash)revert InvalidInternalSource();
        createModule=module;createModuleHash=module.codehash;
        createSnapshot=snapshot;createSnapshotHash=snapshot.codehash;
    }
    function creationTarget(address host) public view returns(address){
        if(host!=vault||createModule==address(0)||createModule.codehash!=createModuleHash
            ||createSnapshot.codehash!=createSnapshotHash||address(groupMath).codehash!=groupMathHash||address(crossMath).codehash!=crossMathHash)revert InvalidInternalSource();
        return createModule;
    }
    function settlementSnapshot() external view returns(address){
        if(!canSettle(msg.sender))revert InvalidInternalSource();
        creationTarget(vault);return createSnapshot;
    }
    function conversionFingerprint(address base) external view returns(bytes32){
        PinnedMarketPricing oracle=PinnedMarketPricing(pricing);
        return math.fingerprint(oracle,base,oracle.usdg());
    }
    function canSettle(address source) public view returns(bool) {
        return manager!=address(0)&&source==manager&&source.codehash==managerHash;
    }
    function feeBpsFor(address caller,uint256 ordinaryBps) external view returns(uint256) {
        if(caller!=manager||manager==address(0))return ordinaryBps;
        if(!canSettle(caller))revert InvalidInternalSource();
        return IInternalPositionSource(caller).internalPositionExecution()?0:ordinaryBps;
    }
}
