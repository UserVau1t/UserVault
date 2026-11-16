pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";
import {IV2Identity, IV2FactoryIdentity} from "./V2StateReader.sol";
import {IV3PoolIdentity, IV3FactoryIdentity} from "./V3StateReader.sol";
import {IV4ExternalStorage, V4StateReader} from "./V4StateReader.sol";

interface ISharedPonsInspector {
    function validate(address base,V4StateReader.PoolKey calldata key,bytes32 launchIdentity,bytes32 curveHash) external view;
}

contract SharedPoolReader {
    struct Roots {
        address v2; bytes32 v2Hash; bytes32 pairHash;
        address v3; bytes32 v3Hash;
        address manager; bytes32 managerHash;
        address ponsHook; bytes32 ponsHookHash;
        address ponsInspector; bytes32 inspectorHash;
    }
    struct Pool {
        uint8 kind;
        address pool;
        address quote;
        bytes32 codeHash;
        V4StateReader.PoolKey key;
        bytes32 launchIdentity;
        bytes32 curveHash;
    }
    Roots public roots;
    uint256 public immutable configuredChainId;
    error InvalidPool(); error InvalidState(); error UnsupportedHook();
    constructor(uint256 chain,Roots memory r) {
        if(chain!=block.chainid || r.pairHash==bytes32(0))revert InvalidPool();
        _pin(r.v2,r.v2Hash);_pin(r.v3,r.v3Hash);_pin(r.manager,r.managerHash);
        _pin(r.ponsHook,r.ponsHookHash);_pin(r.ponsInspector,r.inspectorHash);
        roots=r;configuredChainId=chain;
    }
    function _pin(address a,bytes32 h) private view {
        if(a.code.length==0 || a.codehash!=h)revert InvalidPool();
    }
    function identity(Pool calldata p) public view returns(bytes32) {
        if(p.kind==2)return keccak256(abi.encode(uint8(2),roots.v2,p.pool));
        if(p.kind==3)return keccak256(abi.encode(uint8(3),roots.v3,p.pool));
        if(p.kind==4 || p.kind==5)return keccak256(abi.encode(uint8(4),roots.manager,keccak256(abi.encode(p.key))));
        revert InvalidPool();
    }
    function inspect(address base,Pool calldata p,P.Ratio calldata usdPerQuote) external view returns(P.Ratio memory rate,P.Ratio memory quoteLiquidity) {
        if(block.chainid!=configuredChainId || base.code.length==0 || base==p.quote || (p.quote!=address(0)&&p.quote.code.length==0))revert InvalidPool();
        Roots memory r=roots;
        if(p.kind==2 || p.kind==3) {
            if(p.quote==address(0)||p.key.currency0!=address(0)||p.key.currency1!=address(0)||p.key.fee!=0||p.key.tickSpacing!=0||p.key.hooks!=address(0)||p.launchIdentity!=bytes32(0)||p.curveHash!=bytes32(0))revert InvalidPool();
            _pin(p.pool,p.codeHash);
        } else if(p.pool!=address(0)||p.codeHash!=bytes32(0))revert InvalidPool();
        if(p.kind==2) {
            _pin(r.v2,r.v2Hash);if(p.codeHash!=r.pairHash)revert InvalidPool();
            IV2Identity pair=IV2Identity(p.pool);address t0=pair.token0();address t1=pair.token1();
            if(t0>=t1||pair.factory()!=r.v2||IV2FactoryIdentity(r.v2).getPair(t0,t1)!=p.pool)revert InvalidPool();
            bool reverse=_direction(base,p.quote,t0,t1);
            (uint112 r0,uint112 r1,)=pair.getReserves();
            if(IERC20(t0).balanceOf(p.pool)<r0||IERC20(t1).balanceOf(p.pool)<r1)revert InvalidState();
            if(r0==0||r1==0)return(P.Ratio(0,1),P.Ratio(0,1));
            rate=P.compose(reverse?P.ratio(r0,r1):P.ratio(r1,r0),usdPerQuote);
            quoteLiquidity=P.compose(P.Ratio(2*uint256(reverse?r0:r1),1),usdPerQuote);
        } else if(p.kind==3) {
            _pin(r.v3,r.v3Hash);IV3PoolIdentity pool=IV3PoolIdentity(p.pool);
            address t0=pool.token0();address t1=pool.token1();uint24 fee=pool.fee();
            bool reverse=_direction(base,p.quote,t0,t1);
            if(t0>=t1||pool.factory()!=r.v3||IV3FactoryIdentity(r.v3).getPool(t0,t1,fee)!=p.pool||pool.tickSpacing()<=0||IV3FactoryIdentity(r.v3).feeAmountTickSpacing(fee)!=pool.tickSpacing())revert InvalidPool();
            (uint160 sqrt,int24 tick,,,,,bool unlocked)=pool.slot0();if(!unlocked)revert InvalidState();
            (uint128 f0,uint128 f1)=pool.protocolFees();
            if(f0>IERC20(t0).balanceOf(p.pool)||f1>IERC20(t1).balanceOf(p.pool))revert InvalidState();
            return _concentrated(sqrt,tick,pool.liquidity(),reverse,usdPerQuote);
        } else if(p.kind==4 || p.kind==5) {
            _pin(r.manager,r.managerHash);V4StateReader.PoolKey memory k=p.key;
            bool reverse=_direction(base,p.quote,k.currency0,k.currency1);
            if(k.currency0>=k.currency1||k.tickSpacing<=0||k.tickSpacing>32767||(k.fee>1000000&&k.fee!=0x800000))revert InvalidPool();
            if(p.kind==4){if(p.launchIdentity!=bytes32(0)||p.curveHash!=bytes32(0))revert UnsupportedHook();}
            else {
                if(k.hooks!=r.ponsHook)revert UnsupportedHook();_pin(r.ponsHook,r.ponsHookHash);_pin(r.ponsInspector,r.inspectorHash);
                ISharedPonsInspector(r.ponsInspector).validate(base,k,p.launchIdentity,p.curveHash);
            }
            IV4ExternalStorage m=IV4ExternalStorage(r.manager);
            if(m.exttload(bytes32(uint256(keccak256("Unlocked"))-1))!=bytes32(0))revert InvalidState();
            bytes32 slot=keccak256(abi.encode(keccak256(abi.encode(k)),uint256(6)));
            uint256 word=uint256(m.extsload(slot));uint256 liquidity=uint256(m.extsload(bytes32(uint256(slot)+3)));
            uint24 lpFee=uint24(word>>208);
            if(word>>232!=0||liquidity>type(uint128).max||lpFee>1000000||(k.fee!=0x800000&&lpFee!=k.fee))revert InvalidState();
            return _concentrated(uint160(word),int24(uint24(word>>160)),uint128(liquidity),reverse,usdPerQuote);
        } else revert InvalidPool();
    }
    function _direction(address base,address quote,address t0,address t1) private pure returns(bool) {
        if(base==t0&&quote==t1)return false;if(base==t1&&quote==t0)return true;revert InvalidPool();
    }
    function _concentrated(uint160 sqrt,int24 tick,uint128 liquidity,bool reverse,P.Ratio memory usdPerQuote) private pure returns(P.Ratio memory rate,P.Ratio memory quoteLiquidity) {
        if(sqrt<4295128739||sqrt>=1461446703485210103287273052203988822378723970342||tick< -887272||tick>887272)revert InvalidState();
        P.Ratio memory root=reverse?P.ratio(1<<96,sqrt):P.ratio(sqrt,1<<96);

        rate=P.compose(P.compose(root,usdPerQuote),root);
        quoteLiquidity=liquidity==0?P.Ratio(0,1):P.compose(P.compose(root,usdPerQuote),P.Ratio(2*uint256(liquidity),1));
    }
}
