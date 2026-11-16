pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";

interface IV2Identity {
    function factory() external view returns(address);
    function token0() external view returns(address);
    function token1() external view returns(address);
    function getReserves() external view returns(uint112,uint112,uint32);
    function price0CumulativeLast() external view returns(uint256);
    function price1CumulativeLast() external view returns(uint256);
}
interface IV2FactoryIdentity {function getPair(address,address) external view returns(address);}
