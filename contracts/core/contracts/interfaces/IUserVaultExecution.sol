pragma solidity ^0.8.30;

interface IUserVaultExecution {
    enum Side { Buy, Sell }
    struct DirectRequest {
        uint256 chainId;
        address baseToken;
        address canonicalQuote;
        address inputAsset;
        Side side;
        uint256 maxGrossInput;
        uint256 minGrossInputFilled;
        uint256 minNetOutput;
        uint256 deadline;
        address payable recipient;
        bool allowCrossQuote;
    }
    struct Result {
        uint256 grossInputUsed;
        uint256 netOutput;
        uint256 inputRefund;
    }

    function executeDirect(DirectRequest calldata request, bytes calldata referenceHints, bytes calldata conversionHints)
        external payable returns (Result memory result);

    function availableLiquidity(address baseToken, address canonicalQuote, Side activeSide)
        external view returns (uint256 epochId, uint256 inventory);
    event DirectExecuted(address indexed caller, address indexed recipient, address indexed baseToken,
        address canonicalQuote, Side side, uint256 grossInputUsed, uint256 netOutput, uint256 inputRefund);
    error InvalidRequest();
    error PriceNotAdmitted();
    error ExecutionLimit();
    error OutputBelowMinimum();
    error UnsupportedRoute();
}
