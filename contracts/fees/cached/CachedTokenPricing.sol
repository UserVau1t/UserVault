pragma solidity ^0.8.30;
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SharedPoolReader} from "contracts/reference/SharedPoolReader.sol";
import {UsdQuoteFeed} from "contracts/reference/UsdQuoteFeed.sol";
import {ReferencePriceMath as P} from "contracts/libraries/ReferencePriceMath.sol";
import {ProjectedQuoteMath as Q} from "contracts/libraries/ProjectedQuoteMath.sol";

contract CachedTokenPricing is EIP712 {
    struct Conversion {bytes32 tokenCodeHash;uint8 decimals;SharedPoolReader.Pool pool;}
    struct Source {
        address token; bytes32 tokenCodeHash; uint8 decimals;
        SharedPoolReader.Pool pool;
        Conversion conversion;
        uint256 revision; uint64 observedAt; uint64 validUntil;
        bytes32 selectionDigest;
    }
    struct Selection {SharedPoolReader.Pool pool;bytes32 identity;bool present;}
    uint256 public immutable configuredChainId;
    address public immutable catalogService;
    address public immutable consumer;
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
    bytes32 private constant OWNER=keccak256("UserVault.CachedPricing.Owner.v1");
    bytes32 private constant COUNT=keccak256("UserVault.CachedPricing.Count.v1");
    bytes32 private constant LIST=keccak256("UserVault.CachedPricing.List.v1");
    bytes32 public constant SOURCE_TYPEHASH=keccak256("PoolSource(address token,bytes32 tokenCodeHash,uint8 decimals,bytes32 poolHash,bytes32 conversionHash,uint256 revision,uint64 observedAt,uint64 validUntil,bytes32 selectionDigest)");
    error InvalidConfiguration();error InvalidSource();error ContextBusy();error ContextMissing();error Unauthorized();
    constructor(uint256 chain,address service,address predictedConsumer,SharedPoolReader r,address usd,address wrapped,UsdQuoteFeed eth,UsdQuoteFeed dollar)
        EIP712("UserVault cached pool source","1") {
        if(chain!=block.chainid||service==address(0)||predictedConsumer==address(0)||address(r).code.length==0||r.configuredChainId()!=chain
            ||usd==wrapped||usd.code.length==0||wrapped.code.length==0||eth.quoteAsset()!=address(0)||dollar.quoteAsset()!=usd
            ||eth.configuredChainId()!=chain||dollar.configuredChainId()!=chain
            ||IERC20Metadata(wrapped).decimals()!=18||IERC20Metadata(usd).decimals()!=dollar.quoteDecimals())revert InvalidConfiguration();
        configuredChainId=chain;catalogService=service;consumer=predictedConsumer;reader=r;usdg=usd;wrappedNative=wrapped;ethFeed=eth;usdgFeed=dollar;
        readerHash=address(r).codehash;ethHash=address(eth).codehash;usdHash=address(dollar).codehash;usdgHash=usd.codehash;wrappedHash=wrapped.codehash;
    }
    function _load(bytes32 slot) private view returns(uint256 v){assembly("memory-safe"){v:=tload(slot)}}
    function _store(bytes32 slot,uint256 v) private {assembly("memory-safe"){tstore(slot,v)}}
    function _slot(address token) private pure returns(bytes32){return keccak256(abi.encode("UserVault.CachedPricing.Source.v1",token));}
    function _word(bytes32 slot,uint256 offset) private pure returns(bytes32){return bytes32(uint256(slot)+offset);}
    function _identity() private view {
        if(block.chainid!=configuredChainId||address(reader).codehash!=readerHash||address(ethFeed).codehash!=ethHash||address(usdgFeed).codehash!=usdHash
            ||usdg.codehash!=usdgHash||wrappedNative.codehash!=wrappedHash)revert InvalidConfiguration();
    }
    function sourceDigest(Source memory s) public view returns(bytes32){
        return _hashTypedDataV4(keccak256(abi.encode(SOURCE_TYPEHASH,s.token,s.tokenCodeHash,s.decimals,keccak256(abi.encode(s.pool)),keccak256(abi.encode(s.conversion)),s.revision,s.observedAt,s.validUntil,s.selectionDigest)));
    }
    function _valid(Source memory s) private view {
        if(s.token==address(0)||s.token==usdg||s.token==wrappedNative||s.token==s.pool.quote||s.token.code.length==0
            ||s.token.codehash!=s.tokenCodeHash||IERC20Metadata(s.token).decimals()!=s.decimals||s.revision==0||s.selectionDigest==bytes32(0)
            ||s.observedAt>block.timestamp||s.validUntil<=block.timestamp||s.validUntil<=s.observedAt||s.validUntil-s.observedAt>120)revert InvalidSource();
    }
    function openContext(bytes[] calldata proofs) external {
        _identity();if(_load(OWNER)!=0)revert ContextBusy();if(proofs.length==0||proofs.length>16)revert InvalidSource();
        _store(OWNER,uint256(uint160(msg.sender)));_store(COUNT,proofs.length);
        for(uint256 i;i<proofs.length;i++){
            if(proofs[i].length>2048)revert InvalidSource();
            (Source memory s,bytes memory signature)=abi.decode(proofs[i],(Source,bytes));_valid(s);
            if(ECDSA.recover(sourceDigest(s),signature)!=catalogService)revert Unauthorized();
            bytes32 slot=_slot(s.token);if(_load(slot)!=0)revert InvalidSource();
            bytes memory encoded=abi.encode(s);uint256 words=encoded.length/32;
            if(words==0||words>32||encoded.length%32!=0)revert InvalidSource();
            _store(slot,words);_store(_word(LIST,i),uint256(uint160(s.token)));
            for(uint256 j;j<words;j++){uint256 v;assembly("memory-safe"){v:=mload(add(add(encoded,32),mul(j,32)))}_store(_word(slot,j+1),v);}
        }
        for(uint256 i;i<proofs.length;i++)_usd(address(uint160(_load(_word(LIST,i)))));
    }
    function closeContext() external {
        if(_load(OWNER)!=uint256(uint160(msg.sender)))revert Unauthorized();
        uint256 count=_load(COUNT);
        for(uint256 i;i<count;i++){
            bytes32 slot=_slot(address(uint160(_load(_word(LIST,i)))));uint256 words=_load(slot);
            for(uint256 j;j<=words;j++)_store(_word(slot,j),0);_store(_word(LIST,i),0);
        }
        _store(COUNT,0);_store(OWNER,0);
    }
    function _source(address token) private view returns(Source memory s){
        if(_load(OWNER)==0)revert ContextMissing();bytes32 slot=_slot(token);uint256 words=_load(slot);
        if(words==0||words>32)revert ContextMissing();bytes memory data=new bytes(words*32);
        for(uint256 j;j<words;j++){uint256 v=_load(_word(slot,j+1));assembly("memory-safe"){mstore(add(add(data,32),mul(j,32)),v)}}
        s=abi.decode(data,(Source));if(s.token!=token)revert InvalidSource();_valid(s);
    }
    function _root(address token) private view returns(bool){return token==address(0)||token==wrappedNative||token==usdg;}
    function _rootUsd(address token) private view returns(P.Ratio memory rate){
        if(token==address(0)||token==wrappedNative){(rate,,)=ethFeed.read();return rate;}
        if(token==usdg){(rate,,)=usdgFeed.read();return rate;}
        revert InvalidSource();
    }
    function _conversionUsd(Source memory s) private view returns(P.Ratio memory quote){
        address token=s.pool.quote;
        if(_root(token)){
            Conversion memory empty;
            if(keccak256(abi.encode(s.conversion))!=keccak256(abi.encode(empty)))revert InvalidSource();
            return _rootUsd(token);
        }

        Conversion memory c=s.conversion;
        if(token.codehash!=c.tokenCodeHash||IERC20Metadata(token).decimals()!=c.decimals||!_root(c.pool.quote))revert InvalidSource();
        P.Ratio memory liquidity;(quote,liquidity)=reader.inspect(token,c.pool,_rootUsd(c.pool.quote));
        if(quote.n==0||liquidity.n==0)revert InvalidSource();
    }
    function _usd(address token) private view returns(P.Ratio memory rate){
        if(_root(token))return _rootUsd(token);
        Source memory s=_source(token);P.Ratio memory quote=_conversionUsd(s);P.Ratio memory liquidity;
        (rate,liquidity)=reader.inspect(token,s.pool,quote);if(rate.n==0||liquidity.n==0)revert InvalidSource();
    }
    function quoteUsd(address quote) public view returns(P.Ratio memory){_identity();return _usd(quote);}
    function sourceQuoteUsd(address base) external view returns(P.Ratio memory){_identity();return _conversionUsd(_source(base));}
    function conversionSource(address base) external view returns(address token,SharedPoolReader.Pool memory pool){
        _identity();Source memory s=_source(base);if(_root(s.pool.quote))revert InvalidSource();
        _conversionUsd(s);return(s.pool.quote,s.conversion.pool);
    }
    function read(address base,address quote) public view returns(P.Ratio memory quotePerBase,P.Ratio memory usdPerBase){
        _identity();usdPerBase=_usd(base);P.Ratio memory target=_usd(quote);quotePerBase=Q.compose(usdPerBase,P.Ratio(target.d,target.n));
    }
    function selection(address base,address) external view returns(Selection memory){Source memory s=_source(base);return Selection(s.pool,reader.identity(s.pool),true);}
    function registered(address base) external view returns(bool){return _load(OWNER)!=0&&_load(_slot(base))!=0;}
    function tokens(address base) external view returns(bytes32,uint8,bytes32,uint256){Source memory s=_source(base);return(s.tokenCodeHash,s.decimals,s.selectionDigest,s.revision);}

    function registerFor(address payer,address base,bytes calldata) external view {
        if(msg.sender!=consumer||payer==address(0))revert Unauthorized();_identity();_source(base);
    }
    function meetsMinimum(address base,address quote,bool sell,uint256 amount,uint256 minimum) external view returns(bool){
        (,P.Ratio memory price)=read(base,quote);return P.atLeast(amount,sell?price:quoteUsd(quote),minimum);
    }
}
