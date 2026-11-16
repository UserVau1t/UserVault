pragma solidity ^0.8.30;

contract MainnetFeeDistribution {
    address public immutable settlementSource;
    bytes32 public immutable settlementSourceCodeHash;
    address public immutable treasury;
    address public immutable burnTreasury;
    mapping(bytes32 => bool) public recordedFee;

    mapping(address => uint256) public cashbackUnits;
    uint256 public treasuryUnits;
    uint256 public burnUnits;
    uint256 public accountedETH;
    uint256 public totalFundedETH;
    uint256 public totalClaimedETH;
    uint256 private entered;

    error Unauthorized();
    error InvalidFee();
    error InvalidConfiguration();
    error InvalidClaim();
    error TransferFailed();
    error Reentrancy();
    event FeeFunded(bytes32 indexed feeId, address indexed payer, uint256 convertedETH);
    event CashbackClaimed(address indexed payer, uint256 amountETH);
    event TreasuryClaimed(address indexed recipient, bool indexed burn, uint256 amountETH);

    constructor(address source, address projectTreasury, address burn) {
        if (block.chainid != 4663 || source.code.length == 0 || projectTreasury == address(0)
            || burn == address(0) || projectTreasury == burn || projectTreasury == address(this)
            || burn == address(this)) revert InvalidConfiguration();
        settlementSource = source;
        settlementSourceCodeHash = source.codehash;
        treasury = projectTreasury;
        burnTreasury = burn;
    }
    modifier nonReentrant() {
        if (entered != 0) revert Reentrancy();
        entered = 1;
        _;
        entered = 0;
    }

    function fundConvertedFee(bytes32 feeId, address payer) external payable virtual nonReentrant {
        if (msg.sender != settlementSource || msg.sender.codehash != settlementSourceCodeHash) revert Unauthorized();
        if (feeId == bytes32(0) || recordedFee[feeId] || payer == address(0)
            || payer == address(this) || msg.value == 0) revert InvalidFee();
        recordedFee[feeId] = true;
        _creditFee(feeId,payer,msg.value);
        accountedETH += msg.value;
        totalFundedETH += msg.value;
        emit FeeFunded(feeId, payer, msg.value);
    }
    function _creditFee(bytes32,address payer,uint256 amount) internal virtual {
        treasuryUnits+=amount*12;burnUnits+=amount*5;cashbackUnits[payer]+=amount*3;
    }
    function _unitScale() internal pure virtual returns(uint256){return 20;}
    function claimableCashback(address payer) external view returns (uint256) { return cashbackUnits[payer] / _unitScale(); }
    function claimableTreasury() external view returns (uint256) { return treasuryUnits / _unitScale(); }
    function claimableBurnTreasury() external view returns (uint256) { return burnUnits / _unitScale(); }
    function claimCashback(uint256 amountETH) external nonReentrant {
        uint256 units = _claimUnits(amountETH, cashbackUnits[msg.sender]);
        cashbackUnits[msg.sender] -= units;
        _pay(msg.sender, amountETH);
        emit CashbackClaimed(msg.sender, amountETH);
    }
    function claimTreasury(uint256 amountETH) external nonReentrant {
        if (msg.sender != treasury) revert Unauthorized();
        treasuryUnits -= _claimUnits(amountETH, treasuryUnits);
        _pay(treasury, amountETH);
        emit TreasuryClaimed(treasury, false, amountETH);
    }

    function claimBurnTreasury(uint256 amountETH) external virtual nonReentrant {
        if (msg.sender != burnTreasury) revert Unauthorized();
        burnUnits -= _claimUnits(amountETH, burnUnits);
        _pay(burnTreasury, amountETH);
        emit TreasuryClaimed(burnTreasury, true, amountETH);
    }
    function _claimUnits(uint256 amountETH, uint256 available) internal view returns (uint256) {
        if (amountETH == 0 || amountETH > available / _unitScale()) revert InvalidClaim();
        return amountETH * _unitScale();
    }
    function _pay(address recipient, uint256 amountETH) internal {
        accountedETH -= amountETH;
        totalClaimedETH += amountETH;
        (bool ok,) = payable(recipient).call{value:amountETH}("");
        if (!ok) revert TransferFailed();
    }

}
