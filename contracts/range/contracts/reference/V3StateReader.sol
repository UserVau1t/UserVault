pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";

interface IV3PoolIdentity {
    function factory() external view returns(address);
    function token0() external view returns(address);
    function token1() external view returns(address);
    function fee() external view returns(uint24);
    function tickSpacing() external view returns(int24);
    function liquidity() external view returns(uint128);
    function protocolFees() external view returns(uint128,uint128);
    function slot0() external view returns(uint160,int24,uint16,uint16,uint16,uint8,bool);
}
interface IV3FactoryIdentity {
    function getPool(address,address,uint24) external view returns(address);
    function feeAmountTickSpacing(uint24) external view returns(int24);
}
