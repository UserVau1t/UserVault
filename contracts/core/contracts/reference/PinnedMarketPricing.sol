pragma solidity ^0.8.30;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PinnedReferencePrice} from "./PinnedReferencePrice.sol";
import {UsdQuoteFeed} from "./UsdQuoteFeed.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";
interface IUsdBackedPrice {function usdFeed() external view returns(address);}

contract PinnedMarketPricing is Ownable2Step {
    struct Binding {address priceSource;bytes32 runtimeHash;}
    mapping(bytes32=>Binding) public bindings;
    address public immutable usdg;
    address public immutable wrappedNative;
    uint256 public immutable configuredChainId;
    UsdQuoteFeed public immutable ethFeed;
    UsdQuoteFeed public immutable usdgFeed;
    bytes32 private immutable ethHash;
    bytes32 private immutable usdgHash;
    error InvalidPricing();
    event MarketBound(address indexed base,address indexed quote,address indexed priceSource);
    constructor(address administrator,address usdg_,address wrapper,UsdQuoteFeed eth_,UsdQuoteFeed usd_)
        Ownable(administrator) {
        if(usdg_.code.length==0 || (wrapper!=address(0)&&wrapper.code.length==0)
            || eth_.quoteAsset()!=address(0) || usd_.quoteAsset()!=usdg_
            || eth_.configuredChainId()!=block.chainid || usd_.configuredChainId()!=block.chainid)
            revert InvalidPricing();
        usdg=usdg_;wrappedNative=wrapper;configuredChainId=block.chainid;
        ethFeed=eth_;usdgFeed=usd_;ethHash=address(eth_).codehash;usdgHash=address(usd_).codehash;
    }
    function key(address base,address quote) public pure returns(bytes32){return keccak256(abi.encode(base,quote));}
    function bind(address base,address quote,PinnedReferencePrice priceSource) external onlyOwner {
        if(base.code.length==0 || base==usdg || address(priceSource).code.length==0
            || priceSource.base()!=base || priceSource.configuredChainId()!=configuredChainId)
            revert InvalidPricing();
        address poolQuote=priceSource.quote();
        if(quote==address(0)){
            if(poolQuote!=address(0) && (wrappedNative==address(0)||poolQuote!=wrappedNative))revert InvalidPricing();
        } else if(quote!=usdg || poolQuote!=usdg)revert InvalidPricing();
        bindings[key(base,quote)]=Binding(address(priceSource),address(priceSource).codehash);
        read(base,quote);
        emit MarketBound(base,quote,address(priceSource));
    }
    function quoteUsd(address quote) public view returns(P.Ratio memory rate){
        UsdQuoteFeed f=_feed(quote);(rate,,)=f.read();
    }
    function _feed(address quote) private view returns(UsdQuoteFeed f){
        if(block.chainid!=configuredChainId)revert InvalidPricing();
        if(quote==address(0)){f=ethFeed;if(address(f).codehash!=ethHash)revert InvalidPricing();}
        else if(quote==usdg){f=usdgFeed;if(address(f).codehash!=usdgHash)revert InvalidPricing();}
        else revert InvalidPricing();
    }
    function read(address base,address quote) public view returns(P.Ratio memory quotePerBase,P.Ratio memory usdPerBase){
        UsdQuoteFeed feed=_feed(quote);
        Binding memory b=bindings[key(base,quote)];
        if(b.priceSource==address(0)||b.priceSource.codehash!=b.runtimeHash)revert InvalidPricing();
        PinnedReferencePrice priceSource=PinnedReferencePrice(b.priceSource);

        if(IUsdBackedPrice(priceSource.source()).usdFeed()!=address(feed))revert InvalidPricing();
        (usdPerBase,,)=priceSource.read();
        (P.Ratio memory usdPerQuote,,)=feed.read();
        quotePerBase=P.compose(usdPerBase,P.Ratio(usdPerQuote.d,usdPerQuote.n));
    }
    function meetsMinimum(address base,address quote,bool sell,uint256 amount,uint256 usdMinimum) external view returns(bool){
        (,P.Ratio memory usdPerBase)=read(base,quote);
        return P.atLeast(amount,sell?usdPerBase:quoteUsd(quote),usdMinimum);
    }
}
