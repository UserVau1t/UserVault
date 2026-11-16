pragma solidity ^0.8.30;

interface IDeferredBurnFunds {
    function settlementSource() external view returns (address);
    function settlementSourceCodeHash() external view returns (bytes32);
    function controller() external view returns (address);
    function controllerHash() external view returns (bytes32);
    function availableBurnETH() external view returns (uint256);
    function payBurn(address recipient, uint256 amount) external;
}
interface IDeferredBurnModule {
    function treasury() external view returns (address);
    function treasuryHash() external view returns (bytes32);
}

contract MainnetDeferredBurnBridge {
    address public immutable administrator;
    address public immutable settlementSource;
    bytes32 public immutable settlementSourceHash;
    IDeferredBurnFunds public treasury;
    bytes32 public treasuryHash;
    address public controller;
    bytes32 public controllerHash;
    bool public active;
    bool private entered;
    error InvalidConfiguration();
    error Unauthorized();
    error Unavailable();
    event TreasuryBound(address indexed treasury, bytes32 codeHash);
    event ControllerNominated(address indexed controller, bytes32 codeHash);
    event ControllerActivated(address indexed controller);

    constructor(address source, address admin) {
        if (block.chainid != 4663 || source.code.length == 0 || admin == address(0)) revert InvalidConfiguration();
        settlementSource = source;
        settlementSourceHash = source.codehash;
        administrator = admin;
    }
    modifier onlyAdministrator() {
        if (msg.sender != administrator) revert Unauthorized();
        _;
    }
    function bindTreasury(IDeferredBurnFunds funds, bytes32 expectedHash) external onlyAdministrator {
        if (address(treasury) != address(0) || address(funds).code.length == 0
            || address(funds).codehash != expectedHash || funds.controller() != address(this)
            || funds.controllerHash() != address(this).codehash
            || funds.settlementSource() != settlementSource
            || funds.settlementSourceCodeHash() != settlementSourceHash
            || settlementSource.codehash != settlementSourceHash) revert InvalidConfiguration();
        treasury = funds;
        treasuryHash = expectedHash;
        emit TreasuryBound(address(funds), expectedHash);
    }
    function _checkTreasury() private view {
        if (block.chainid != 4663 || address(treasury) == address(0)
            || address(treasury).codehash != treasuryHash
            || settlementSource.codehash != settlementSourceHash) revert Unavailable();
    }

    function nominateController(address module, bytes32 expectedHash) external onlyAdministrator {
        _checkTreasury();
        if (controller != address(0) || module == address(this) || module == address(treasury)
            || module == settlementSource || module.code.length == 0 || module.codehash != expectedHash
            || IDeferredBurnModule(module).treasury() != address(0)) revert InvalidConfiguration();
        controller = module;
        controllerHash = expectedHash;
        emit ControllerNominated(module, expectedHash);
    }
    function _checkController() private view {
        if (controller == address(0) || controller.codehash != controllerHash
            || IDeferredBurnModule(controller).treasury() != address(this)
            || IDeferredBurnModule(controller).treasuryHash() != address(this).codehash) revert Unavailable();
    }
    function activateController() external onlyAdministrator {
        _checkTreasury();
        _checkController();
        if (active) revert InvalidConfiguration();
        active = true;
        emit ControllerActivated(controller);
    }
    function availableBurnETH() external view returns (uint256) {
        _checkTreasury();
        if (!active) return 0;
        _checkController();
        return treasury.availableBurnETH();
    }
    function payBurn(address recipient, uint256 amount) external {
        if (entered || !active || msg.sender != controller || recipient == address(0)
            || recipient == address(this) || amount == 0) revert Unauthorized();
        _checkTreasury();
        _checkController();
        entered = true;
        treasury.payBurn(recipient, amount);
        entered = false;
    }
}
