pragma solidity 0.6.7;

abstract contract OracleRelayerLike {
    function redemptionPrice() virtual external returns (uint256);
    function modifyParameters(bytes32,uint256) virtual external;
}

contract MockSetterRelayer {
    // --- Variables ---
    // The address that's allowed to pass new redemption rates
    address           public setter;
    // The oracle relayer contract
    OracleRelayerLike public oracleRelayer;

    constructor(address oracleRelayer_) public {
        oracleRelayer = OracleRelayerLike(oracleRelayer_);
    }

    // --- Administration ---
    /*
    * @notice Change the setter address
    * @param parameter Must be "setter"
    * @param addr The new setter address
    */
    function modifyParameters(bytes32 parameter, address addr) external {
        require(addr != address(0), "MockSetterRelayer/null-addr");
        if (parameter == "setter") {
            setter = addr;
        }
        else revert("MockSetterRelayer/modify-unrecognized-param");
    }

    // --- Core Logic ---
    /*
    * @notice Relay a new redemption rate to the OracleRelayer
    * @param redemptionRate The new redemption rate to relay
    */
    function relayRate(uint256 redemptionRate) external {
        require(setter == msg.sender, "MockSetterRelayer/invalid-caller");
        oracleRelayer.redemptionPrice();
        oracleRelayer.modifyParameters("redemptionRate", redemptionRate);
    }
}
