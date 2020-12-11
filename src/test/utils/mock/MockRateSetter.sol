pragma solidity 0.6.7;

import "../RateSetterMath.sol";

abstract contract OracleLike {
    function getResultWithValidity() virtual external returns (uint256, bool);
    function lastUpdateTime() virtual external view returns (uint64);
}
abstract contract OracleRelayerLike {
    function redemptionPrice() virtual external returns (uint256);
    function modifyParameters(bytes32,uint256) virtual external;
}
abstract contract PIDCalculator {
    function computeRate(uint256, uint256, uint256) virtual external returns (uint256);
    function rt(uint256, uint256, uint256) virtual external view returns (uint256);
    function pscl() virtual external view returns (uint256);
    function tlv() virtual external view returns (uint256);
}

contract MockRateSetter is RateSetterMath {
    // --- System Dependencies ---
    // OSM or medianizer for the system coin
    OracleLike                public orcl;
    // OracleRelayer where the redemption price is stored
    OracleRelayerLike         public oracleRelayer;
    // Calculator for the redemption rate
    PIDCalculator              public pidCalculator;

    constructor(address orcl_, address oracleRelayer_, address pidCalculator_) public {
        oracleRelayer  = OracleRelayerLike(oracleRelayer_);
        orcl           = OracleLike(orcl_);
        pidCalculator  = PIDCalculator(pidCalculator_);
    }

    function modifyParameters(bytes32 parameter, address addr) external {
        if (parameter == "orcl") orcl = OracleLike(addr);
        else if (parameter == "oracleRelayer") oracleRelayer = OracleRelayerLike(addr);
        else if (parameter == "pidCalculator") {
          pidCalculator = PIDCalculator(addr);
        }
        else revert("RateSetter/modify-unrecognized-param");
    }

    function updateRate(address feeReceiver) public {
        // Get price feed updates
        (uint256 marketPrice, bool hasValidValue) = orcl.getResultWithValidity();
        // If the oracle has a value
        require(hasValidValue, "MockRateSetter/invalid-oracle-value");
        // If the price is non-zero
        require(marketPrice > 0, "MockRateSetter/null-market-price");
        // Get the latest redemption price
        uint redemptionPrice = oracleRelayer.redemptionPrice();
        // Calculate the new redemption rate
        uint256 tlv       = pidCalculator.tlv();
        uint256 iapcr     = rpower(pidCalculator.pscl(), tlv, RAY);
        uint256 validated = pidCalculator.computeRate(
            marketPrice,
            redemptionPrice,
            iapcr
        );
        // Update the rate inside the system (if it doesn't throw)
        try oracleRelayer.modifyParameters("redemptionRate", validated) {}
        catch(bytes memory revertReason) {}
    }

    function iapcr() public view returns (uint256) {
        return rpower(pidCalculator.pscl(), pidCalculator.tlv(), RAY);
    }
}
