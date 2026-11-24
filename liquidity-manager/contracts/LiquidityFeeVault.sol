pragma solidity 0.8.30;

struct LMFeePoolKey {address currency0;address currency1;uint24 fee;int24 tickSpacing;address hooks;}
struct LMFeeSwapParams {bool zeroForOne;int256 amountSpecified;uint160 sqrtPriceLimitX96;}
interface ILMFeePoolManager {
    function unlock(bytes calldata) external returns(bytes memory);
    function swap(LMFeePoolKey calldata,LMFeeSwapParams calldata,bytes calldata) external returns(int256);
    function sync(address) external;
    function settle() external payable returns(uint256);
    function take(address,address,uint256) external;
}
interface ILMFeeToken {function balanceOf(address) external view returns(uint256);}

contract LiquidityFeeVault {
    error Unauthorized();error Reentrant();error InvalidFeeRoute();error InsufficientFees();
    error InsufficientOutput();error InvalidSwap();error BalanceChanged();error TransferFailed();error Expired();
    address public immutable controller;
    address public constant POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951;
    ILMFeePoolManager private constant pools=ILMFeePoolManager(POOL_MANAGER);
    mapping(address=>mapping(address=>uint256)) public credits;
    mapping(address=>uint256) public totalCredits;
    uint256 private entered;
    bytes32 private commitment;
    struct Hop {LMFeePoolKey key;uint160 sqrtPriceLimitX96;uint256 minimumOut;}
    struct Withdrawal {address currency;uint256 amount;Hop[] route;}
    event Credited(address indexed owner,address indexed currency,uint256 amount);
    event Withdrawn(address indexed owner,address indexed currency,uint256 amount);
    event Reinvested(address indexed owner,address indexed currency,uint256 amount);
    modifier onlyController(){if(msg.sender!=controller)revert Unauthorized();_;}
    modifier lock(){if(entered!=0)revert Reentrant();entered=1;_;entered=0;}
    constructor(){controller=msg.sender;}
    receive() external payable {if(msg.sender!=controller&&msg.sender!=POOL_MANAGER)revert Unauthorized();}
    function credit(address owner,address currency,uint256 amount) external onlyController lock {
        if(owner==address(0)||amount==0)revert InsufficientFees();
        credits[owner][currency]+=amount;totalCredits[currency]+=amount;
        if(_balance(currency)<totalCredits[currency])revert BalanceChanged();emit Credited(owner,currency,amount);
    }
    function withdraw(address currency,uint256 amount) external lock {_pay(msg.sender,currency,amount,msg.sender);}
    function withdrawFor(address owner,address currency,uint256 amount) external onlyController lock {_pay(owner,currency,amount,owner);}
    function reinvestFor(address owner,address currency,uint256 amount) external onlyController lock {
        _debit(owner,currency,amount);_sendExact(currency,controller,amount);emit Reinvested(owner,currency,amount);
    }
    function withdrawAsEth(Withdrawal[] calldata requests,uint256 minimumEth,uint256 deadline) external lock returns(uint256){return _eth(msg.sender,requests,minimumEth,deadline);}
    function withdrawAsEthFor(address owner,Withdrawal[] calldata requests,uint256 minimumEth,uint256 deadline) external onlyController lock returns(uint256){return _eth(owner,requests,minimumEth,deadline);}
    function _eth(address owner,Withdrawal[] calldata requests,uint256 minimumEth,uint256 deadline) private returns(uint256 received){
        if(deadline<block.timestamp||deadline>block.timestamp+1200)revert Expired();
        if(requests.length==0||requests.length>8||minimumEth==0)revert InvalidFeeRoute();
        uint256 baseline=address(this).balance;
        for(uint256 i;i<requests.length;i++){
            Withdrawal calldata request=requests[i];
            uint256 original=request.amount==type(uint256).max?credits[owner][request.currency]:request.amount;
            _debit(owner,request.currency,original);uint256 amount=original;
            if(request.currency==address(0)){
                if(request.route.length!=0)revert InvalidFeeRoute();baseline-=amount;received+=amount;
            }else{
                if(request.route.length==0||request.route.length>3)revert InvalidFeeRoute();address currency=request.currency;
                for(uint256 j;j<request.route.length;j++){
                    Hop calldata hop=request.route[j];
                    if(hop.key.hooks!=address(0)||hop.key.currency0>=hop.key.currency1||hop.key.tickSpacing<=0||hop.key.fee>1000000)revert InvalidFeeRoute();
                    bool direction=currency==hop.key.currency0;if(!direction&&currency!=hop.key.currency1)revert InvalidFeeRoute();
                    address next=direction?hop.key.currency1:hop.key.currency0;
                    if(next==address(0)&&j+1!=request.route.length)revert InvalidFeeRoute();
                    if(amount>uint256(uint128(type(int128).max))||hop.minimumOut==0)revert InvalidFeeRoute();
                    uint256 beforeInput=_balance(currency);uint256 beforeOutput=_balance(next);
                    bytes memory payload=abi.encode(hop.key,LMFeeSwapParams(direction,-int256(amount),hop.sqrtPriceLimitX96));
                    commitment=keccak256(payload);pools.unlock(payload);
                    if(commitment!=bytes32(0)||_balance(currency)+amount!=beforeInput)revert InvalidSwap();
                    amount=_balance(next)-beforeOutput;if(amount<hop.minimumOut)revert InsufficientOutput();currency=next;
                }
                if(currency!=address(0))revert InvalidFeeRoute();received+=amount;
            }
            emit Withdrawn(owner,request.currency,original);
        }
        if(received<minimumEth||address(this).balance!=baseline+received)revert InsufficientOutput();
        _sendExact(address(0),owner,received);if(address(this).balance!=baseline)revert BalanceChanged();
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory){
        if(msg.sender!=POOL_MANAGER||entered!=1||commitment==bytes32(0)||keccak256(data)!=commitment)revert Unauthorized();commitment=bytes32(0);
        (LMFeePoolKey memory key,LMFeeSwapParams memory params)=abi.decode(data,(LMFeePoolKey,LMFeeSwapParams));
        int256 packed=pools.swap(key,params,"");int128 d0=int128(packed>>128);int128 d1=int128(packed);
        if(params.zeroForOne?(d0>=0||d1<=0):(d1>=0||d0<=0))revert InvalidSwap();
        _settle(key.currency0,d0);_settle(key.currency1,d1);return "";
    }
    function _settle(address currency,int128 delta) private {
        if(delta<0){uint256 amount=uint256(-int256(delta));if(currency==address(0)){if(pools.settle{value:amount}()!=amount)revert BalanceChanged();}else{pools.sync(currency);_sendExact(currency,POOL_MANAGER,amount);if(pools.settle()!=amount)revert BalanceChanged();}}
        else if(delta>0)pools.take(currency,address(this),uint128(delta));
    }
    function _debit(address owner,address currency,uint256 amount) private {
        if(amount==0||amount>credits[owner][currency])revert InsufficientFees();credits[owner][currency]-=amount;totalCredits[currency]-=amount;
    }
    function _pay(address owner,address currency,uint256 amount,address recipient) private {
        _debit(owner,currency,amount);_sendExact(currency,recipient,amount);emit Withdrawn(owner,currency,amount);
    }
    function _balance(address currency) private view returns(uint256){return currency==address(0)?address(this).balance:ILMFeeToken(currency).balanceOf(address(this));}
    function _sendExact(address currency,address recipient,uint256 amount) private {
        uint256 beforeBalance=_balance(currency);
        if(currency==address(0)){(bool ok,)=recipient.call{value:amount}("");if(!ok)revert TransferFailed();}
        else{(bool ok,bytes memory result)=currency.call(abi.encodeWithSignature("transfer(address,uint256)",recipient,amount));if(!ok||(result.length!=0&&(result.length!=32||!abi.decode(result,(bool)))))revert TransferFailed();}
        if(_balance(currency)+amount!=beforeBalance)revert BalanceChanged();
    }
}
