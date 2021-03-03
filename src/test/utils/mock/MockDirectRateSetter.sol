// Copyright (C) 2020 Maker Ecosystem Growth Holdings, INC, Reflexer Labs, INC.

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity 0.6.7;

import "../RateSetterMath.sol";

abstract contract OracleLike {
    function getResultWithValidity() virtual external view returns (uint256, bool);
}
abstract contract OracleRelayerLike {
    function redemptionPrice() virtual external returns (uint256);
    function redemptionRate() virtual public view returns (uint256);
}
abstract contract SetterRelayer {
    function relayRate(uint256) virtual external;
}
abstract contract DirectRateCalculator {
    function computeRate(uint256, uint256, uint256) virtual external returns (uint256);
}

contract MockDirectRateSetter is RateSetterMath {
    // --- System Dependencies ---
    // OSM or medianizer for the system coin
    OracleLike                public orcl;
    // OracleRelayer where the redemption price is stored
    OracleRelayerLike         public oracleRelayer;
    // The contract that will pass the new redemption rate to the oracle relayer
    SetterRelayer             public setterRelayer;
    // Calculator for the redemption rate
    DirectRateCalculator      public directRateCalculator;

    constructor(address orcl_, address oracleRelayer_, address directCalculator_, address setterRelayer_) public {
        oracleRelayer        = OracleRelayerLike(oracleRelayer_);
        orcl                 = OracleLike(orcl_);
        setterRelayer        = SetterRelayer(setterRelayer_);
        directRateCalculator = DirectRateCalculator(directCalculator_);
    }

    function modifyParameters(bytes32 parameter, address addr) external {
        if (parameter == "orcl") orcl = OracleLike(addr);
        else if (parameter == "oracleRelayer") oracleRelayer = OracleRelayerLike(addr);
        else if (parameter == "setterRelayer") setterRelayer = SetterRelayer(addr);
        else if (parameter == "directRateCalculator") {
          directRateCalculator = DirectRateCalculator(addr);
        }
        else revert("RateSetter/modify-unrecognized-param");
    }

    function updateRate(address feeReceiver) external {
        // Get price feed updates
        (uint256 marketPrice, bool hasValidValue) = orcl.getResultWithValidity();
        // If the oracle has a value
        require(hasValidValue, "DirectRateSetter/invalid-oracle-value");
        // If the price is non-zero
        require(marketPrice > 0, "DirectRateSetter/null-price");
        // Get the latest redemption price
        uint redemptionPrice = oracleRelayer.redemptionPrice();
        // Calculate the new rate
        uint256 calculated = directRateCalculator.computeRate(
            marketPrice,
            redemptionPrice,
            oracleRelayer.redemptionRate()
        );
        // Update the rate using the setter relayer
        try setterRelayer.relayRate(calculated) {}
        catch(bytes memory revertReason) {}
    }
}
