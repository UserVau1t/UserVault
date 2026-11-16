pragma solidity ^0.8.30;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {ReferencePriceMath as R} from "../libraries/ReferencePriceMath.sol";
interface IBurnableUSER { function burnFrom(address owner,uint256 amount) external; function balanceOf(address owner) external view returns(uint256); function totalSupply() external view returns(uint256); }
interface ISharedBurnFunds {
    function controller() external view returns(address);
    function availableBurnETH() external view returns(uint256);
    function payBurn(address recipient,uint256 amount) external;
}

contract MainnetSharedBurnAndClaim is ReentrancyGuard {
    IBurnableUSER public immutable user;
    PinnedMarketPricing public immutable pricing;
    address public immutable referenceQuote;
    bytes32 public immutable userHash;
    bytes32 public immutable pricingHash;
    ISharedBurnFunds public treasury;
    bytes32 public treasuryHash;
    address private immutable installer;
    uint256 public constant MIN_BURN_USD=100e18;
    uint256 public constant MAX_BURN_USD=1000e18;
    uint256 public constant DAILY_PAYOUT_USD=20000e18;
    uint256 public constant WALLET_COOLDOWN=12 hours;
    uint256 public constant GLOBAL_COOLDOWN=30 minutes;
    uint256 public nextGlobalAt;
    mapping(address=>uint256) public nextWalletAt;
    mapping(uint256=>uint256) public dailyPaidUsd;
    uint256 public totalBurnedUSER;
    uint256 public totalPaidETH;
    error InvalidConfiguration();
    error InvalidAmount();
    error Cooldown();
    error Capacity();
    error Constraint();
    error BurnMismatch();
    event BurnedAndClaimed(address indexed owner,uint256 amountUSER,uint256 payoutETH,uint256 chargedUsd,uint256 indexed utcDay);
    constructor(address token,PinnedMarketPricing prices,address quote){
        if(block.chainid!=4663||token.code.length==0||address(prices).code.length==0
            ||prices.configuredChainId()!=4663||token==prices.usdg()||token==prices.wrappedNative()
            ||(quote!=address(0)&&quote!=prices.usdg()))revert InvalidConfiguration();
        user=IBurnableUSER(token);pricing=prices;referenceQuote=quote;
        userHash=token.codehash;pricingHash=address(prices).codehash;
        prices.read(token,quote);prices.quoteUsd(address(0));
        installer=msg.sender;
    }
    function bindTreasury(ISharedBurnFunds funds) external {
        if(msg.sender!=installer||address(treasury)!=address(0)||address(funds).code.length==0||funds.controller()!=address(this))revert InvalidConfiguration();
        treasury=funds;treasuryHash=address(funds).codehash;
    }
    function _funds() private view returns(uint256){
        if(address(treasury)==address(0)||address(treasury).codehash!=treasuryHash)revert InvalidConfiguration();
        return treasury.availableBurnETH();
    }
    function _rates() private view returns(R.Ratio memory usd,R.Ratio memory payoutUsd,R.Ratio memory eth){
        if(block.chainid!=4663||address(user).codehash!=userHash||address(pricing).codehash!=pricingHash)revert InvalidConfiguration();
        (,usd)=pricing.read(address(user),referenceQuote);
        payoutUsd=R.compose(usd,R.Ratio(6,5));
        R.Ratio memory ethUsd=pricing.quoteUsd(address(0));
        eth=R.compose(payoutUsd,R.Ratio(ethUsd.d,ethUsd.n));
    }
    function remainingDailyUsd() public view returns(uint256){return DAILY_PAYOUT_USD-dailyPaidUsd[block.timestamp/1 days];}

    function maximumBurnUSER() external view returns(uint256 amount){
        (R.Ratio memory usd,R.Ratio memory cost,R.Ratio memory eth)=_rates();
        amount=R.consideration(MAX_BURN_USD,R.Ratio(usd.d,usd.n),false);
        uint256 byFunds=R.consideration(_funds(),R.Ratio(eth.d,eth.n),false);
        uint256 byDay=R.consideration(remainingDailyUsd(),R.Ratio(cost.d,cost.n),false);
        if(byFunds<amount)amount=byFunds;if(byDay<amount)amount=byDay;
        if(!R.atLeast(amount,usd,MIN_BURN_USD))return 0;
    }
    function quote(address owner,uint256 amount) public view returns(uint256 payoutETH,uint256 chargedUsd){
        if(owner==address(0)||amount==0)revert InvalidAmount();
        if(block.timestamp<nextGlobalAt||block.timestamp<nextWalletAt[owner])revert Cooldown();
        (R.Ratio memory usd,R.Ratio memory cost,R.Ratio memory eth)=_rates();
        if(!R.atLeast(amount,usd,MIN_BURN_USD)||!R.atMost(amount,usd,MAX_BURN_USD))revert InvalidAmount();
        payoutETH=R.consideration(amount,eth,false);

        chargedUsd=R.consideration(amount,cost,true);
        if(payoutETH==0||!R.atMost(amount,eth,_funds())||chargedUsd>remainingDailyUsd())revert Capacity();
    }
    function burnAndClaim(uint256 amount,uint256 minimumETH,uint256 deadline) external nonReentrant {
        if(minimumETH==0||block.timestamp>deadline)revert Constraint();
        (uint256 payout,uint256 charged)=quote(msg.sender,amount);
        if(payout<minimumETH)revert Constraint();
        uint256 balance=user.balanceOf(msg.sender);uint256 supply=user.totalSupply();
        uint256 day=block.timestamp/1 days;
        dailyPaidUsd[day]+=charged;nextGlobalAt=block.timestamp+GLOBAL_COOLDOWN;
        nextWalletAt[msg.sender]=block.timestamp+WALLET_COOLDOWN;
        totalBurnedUSER+=amount;totalPaidETH+=payout;
        user.burnFrom(msg.sender,amount);
        if(balance<amount||supply<amount||user.balanceOf(msg.sender)!=balance-amount||user.totalSupply()!=supply-amount)revert BurnMismatch();
        treasury.payBurn(msg.sender,payout);
        emit BurnedAndClaimed(msg.sender,amount,payout,charged,day);
    }
}
