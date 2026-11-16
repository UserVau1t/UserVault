pragma solidity ^0.8.30;
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SharedPoolReader} from "./SharedPoolReader.sol";
import {UsdQuoteFeed} from "./UsdQuoteFeed.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";
import {ProjectedQuoteMath as Q} from "../libraries/ProjectedQuoteMath.sol";
interface ISharedArbSys {function arbChainID() external view returns(uint256);function arbBlockNumber() external view returns(uint256);}

contract SharedTokenPricing {
    struct Review {bytes32 candidatesDigest;bytes32 evidenceDigest;uint256 scanFrom;uint256 scanTo;bytes32 scanBlockHash;uint256 validUntil;}
    struct Selection {SharedPoolReader.Pool pool;bytes32 identity;bool present;}
    struct Token {bytes32 codeHash;uint8 decimals;bytes32 reviewDigest;uint256 admittedAt;}
    uint256 public immutable configuredChainId;
    address public immutable catalogService;
    address public immutable usdg;
    address public immutable wrappedNative;
    SharedPoolReader public immutable reader;
    UsdQuoteFeed public immutable ethFeed;
    UsdQuoteFeed public immutable usdgFeed;
    bytes32 private immutable readerHash;
    bytes32 private immutable ethHash;
    bytes32 private immutable usdHash;
    bytes32 private immutable usdgHash;
    bytes32 private immutable wrappedHash;
    mapping(address=>Token) public tokens;
    mapping(bytes32=>Selection) private selected;
    error InvalidConfiguration();error InvalidReview();error Unauthorized();error Unavailable();error AlreadyRegistered();
    event TokenRegistered(address indexed base,bytes32 indexed candidatesDigest,bytes32 nativePool,bytes32 usdgPool,bytes32 evidenceDigest);
    constructor(uint256 chain,address service,SharedPoolReader r,address usd,address wrapped,UsdQuoteFeed eth,UsdQuoteFeed dollar) {
        if(chain!=block.chainid||service==address(0)||address(r).code.length==0||r.configuredChainId()!=chain
            ||usd==wrapped||usd.code.length==0||wrapped.code.length==0||eth.quoteAsset()!=address(0)||dollar.quoteAsset()!=usd
            ||eth.configuredChainId()!=chain||dollar.configuredChainId()!=chain
            ||IERC20Metadata(wrapped).decimals()!=18||IERC20Metadata(usd).decimals()!=dollar.quoteDecimals())revert InvalidConfiguration();
        configuredChainId=chain;catalogService=service;reader=r;usdg=usd;wrappedNative=wrapped;ethFeed=eth;usdgFeed=dollar;
        readerHash=address(r).codehash;ethHash=address(eth).codehash;usdHash=address(dollar).codehash;usdgHash=usd.codehash;wrappedHash=wrapped.codehash;
    }
    function key(address base,address quote) public pure returns(bytes32){return keccak256(abi.encode(base,quote));}
    function registered(address base) public view returns(bool){return tokens[base].codeHash!=bytes32(0);}
    function selection(address base,address quote) external view returns(Selection memory){return selected[key(base,quote)];}
    function _identity() private view {
        if(block.chainid!=configuredChainId||address(reader).codehash!=readerHash||address(ethFeed).codehash!=ethHash||address(usdgFeed).codehash!=usdHash
            ||usdg.codehash!=usdgHash||wrappedNative.codehash!=wrappedHash||IERC20Metadata(wrappedNative).decimals()!=18||IERC20Metadata(usdg).decimals()!=usdgFeed.quoteDecimals())revert InvalidConfiguration();
    }
    function quoteUsd(address quote) public view returns(P.Ratio memory rate){
        _identity();
        if(quote==address(0))(rate,,)=ethFeed.read();
        else if(quote==usdg)(rate,,)=usdgFeed.read();
        else revert InvalidConfiguration();
    }
    function candidatesDigest(address base,SharedPoolReader.Pool[] calldata pools) public view returns(bytes32){
        return keccak256(abi.encode(block.chainid,address(this),base,pools));
    }

    function registerToken(address base,SharedPoolReader.Pool[] calldata pools,Review calldata review) external {
        if(msg.sender!=catalogService)revert Unauthorized();_identity();
        if(registered(base))revert AlreadyRegistered();
        if(base.code.length==0||base==usdg||base==wrappedNative||pools.length==0)revert InvalidReview();
        ISharedArbSys clock=ISharedArbSys(address(100));
        if(clock.arbChainID()!=configuredChainId||review.scanFrom!=0||review.scanTo>=clock.arbBlockNumber()
            ||review.scanBlockHash==bytes32(0)||review.evidenceDigest==bytes32(0)
            ||review.validUntil<=block.timestamp||review.validUntil>block.timestamp+300
            ||review.candidatesDigest!=candidatesDigest(base,pools))revert InvalidReview();

        P.Ratio memory eth=quoteUsd(address(0));P.Ratio memory usd=quoteUsd(usdg);
        P.Ratio[2] memory best;uint256[2] memory winner;bool[2] memory found;bytes32 last;
        for(uint256 i;i<pools.length;i++){
            SharedPoolReader.Pool calldata pool=pools[i];bytes32 id=reader.identity(pool);
            if(id<=last)revert InvalidReview();last=id;
            uint256 side=pool.quote==usdg?1:0;
            if(side==0&&pool.quote!=address(0)&&pool.quote!=wrappedNative)revert InvalidReview();
            (,P.Ratio memory score)=reader.inspect(base,pool,side==0?eth:usd);
            if(score.n==0)continue;

            bool greater=!found[side]||P.atLeast(score.n,P.Ratio(best[side].d,score.d),best[side].n);
            bool equal=found[side]&&greater&&P.atLeast(best[side].n,P.Ratio(score.d,best[side].d),score.n);
            uint8 version=pool.kind==5?4:pool.kind;
            uint8 oldVersion=found[side]?(pools[winner[side]].kind==5?4:pools[winner[side]].kind):0;
            if(greater&&(!equal||version>oldVersion)){best[side]=score;winner[side]=i;found[side]=true;}
        }
        if(!found[0]&&!found[1])revert Unavailable();
        for(uint256 side;side<2;side++){
            SharedPoolReader.Pool calldata pool=pools[winner[found[side]?side:1-side]];
            selected[key(base,side==0?address(0):usdg)]=Selection(pool,reader.identity(pool),true);
        }
        tokens[base]=Token(base.codehash,IERC20Metadata(base).decimals(),review.candidatesDigest,block.timestamp);
        read(base,address(0));read(base,usdg);
        emit TokenRegistered(base,review.candidatesDigest,selected[key(base,address(0))].identity,selected[key(base,usdg)].identity,review.evidenceDigest);
    }
    function read(address base,address quote) public view returns(P.Ratio memory quotePerBase,P.Ratio memory usdPerBase){
        P.Ratio memory target=quoteUsd(quote);Token memory t=tokens[base];
        if(!registered(base)||base.codehash!=t.codeHash||IERC20Metadata(base).decimals()!=t.decimals)revert Unavailable();
        Selection memory s=selected[key(base,quote)];if(!s.present)revert Unavailable();
        address origin=s.pool.quote==usdg?usdg:address(0);P.Ratio memory liquidity;
        (usdPerBase,liquidity)=reader.inspect(base,s.pool,origin==quote?target:quoteUsd(origin));
        if(usdPerBase.n==0||liquidity.n==0)revert Unavailable();
        quotePerBase=Q.compose(usdPerBase,P.Ratio(target.d,target.n));
    }
    function meetsMinimum(address base,address quote,bool sell,uint256 amount,uint256 minimum) external view returns(bool){
        (,P.Ratio memory price)=read(base,quote);return P.atLeast(amount,sell?price:quoteUsd(quote),minimum);
    }
}
