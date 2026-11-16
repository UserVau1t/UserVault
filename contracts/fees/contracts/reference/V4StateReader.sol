pragma solidity ^0.8.30;
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";

interface IV4ExternalStorage {
    function extsload(bytes32 slot) external view returns(bytes32);
    function exttload(bytes32 slot) external view returns(bytes32);
}

contract V4StateReader {
    struct PoolKey {address currency0;address currency1;uint24 fee;int24 tickSpacing;address hooks;}
    struct Snapshot {
        uint160 sqrtPriceX96;int24 tick;uint24 protocolFee;uint24 lpFee;
        uint128 activeLiquidity;bool reversed;bool requiresHookAdapter;bytes32 stateHash;
    }
    address public immutable manager;
    bytes32 public immutable managerCodeHash;
    uint256 public immutable configuredChainId;
    bytes32 public immutable poolId;
    bytes32 public immutable hookCodeHash;
    PoolKey public key;

    bytes32 private constant POOLS_SLOT=bytes32(uint256(6));
    bytes32 private constant UNLOCKED_SLOT=bytes32(uint256(keccak256("Unlocked"))-1);
    error InvalidConfiguration();error InvalidState();error StateChanged();error HookAdapterRequired();

    constructor(uint256 chainId,address manager_,bytes32 runtimeHash,PoolKey memory key_) {
        if(chainId!=block.chainid || manager_.code.length==0 || manager_.codehash!=runtimeHash
            || key_.currency0>=key_.currency1 || key_.currency1.code.length==0
            || (key_.currency0!=address(0) && key_.currency0.code.length==0)
            || key_.tickSpacing<=0 || key_.tickSpacing>32767
            || (key_.fee>1000000 && key_.fee!=0x800000)
            || (key_.hooks!=address(0) && key_.hooks.code.length==0)
            || (key_.fee==0x800000 && key_.hooks==address(0)))revert InvalidConfiguration();
        configuredChainId=chainId;manager=manager_;managerCodeHash=runtimeHash;
        key=key_;poolId=keccak256(abi.encode(key_));hookCodeHash=key_.hooks.codehash;
        read(key_.currency0,key_.currency1);
    }
    function read(address base,address quote) public view returns(Snapshot memory s){
        PoolKey memory k=key;
        if(block.chainid!=configuredChainId || manager.codehash!=managerCodeHash
            || (k.hooks!=address(0) && k.hooks.codehash!=hookCodeHash))revert InvalidConfiguration();
        if(base==k.currency0 && quote==k.currency1)s.reversed=false;
        else if(base==k.currency1 && quote==k.currency0)s.reversed=true;
        else revert InvalidConfiguration();
        IV4ExternalStorage m=IV4ExternalStorage(manager);

        if(m.exttload(UNLOCKED_SLOT)!=bytes32(0))revert InvalidState();
        bytes32 slot=keccak256(abi.encode(poolId,POOLS_SLOT));
        uint256 packed=uint256(m.extsload(slot));
        s.sqrtPriceX96=uint160(packed);s.tick=int24(uint24(packed>>160));
        s.protocolFee=uint24(packed>>184);s.lpFee=uint24(packed>>208);
        uint256 liquidity=uint256(m.extsload(bytes32(uint256(slot)+3)));
        if(packed>>232!=0 || liquidity>type(uint128).max
            || s.sqrtPriceX96<4295128739 || s.sqrtPriceX96>=1461446703485210103287273052203988822378723970342
            || s.tick < -887272 || s.tick>887272 || s.lpFee>1000000
            || (k.fee!=0x800000 && s.lpFee!=k.fee))revert InvalidState();
        s.activeLiquidity=uint128(liquidity);s.requiresHookAdapter=k.hooks!=address(0);
        s.stateHash=keccak256(abi.encode(block.chainid,address(this),manager,poolId,base,quote,s));
    }

    function price(address base,address quote) external view returns(P.Ratio memory){
        Snapshot memory s=read(base,quote);if(s.requiresHookAdapter)revert HookAdapterRequired();
        P.Ratio memory root=s.reversed?P.ratio(1<<96,s.sqrtPriceX96):P.ratio(s.sqrtPriceX96,1<<96);
        return P.compose(root,root);
    }
    function revalidate(address base,address quote,bytes32 expected) external view returns(Snapshot memory s){
        s=read(base,quote);if(s.stateHash!=expected)revert StateChanged();
    }
}
