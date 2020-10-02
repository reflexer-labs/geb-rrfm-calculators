/// PIScaledGlobalValidator.sol

// Copyright (C) 2020 Reflexer Labs, INC

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

pragma solidity ^0.6.7;

import "../../../math/SafeMath.sol";
import "../../../math/SignedSafeMath.sol";

contract PIScaledGlobalValidator is SafeMath, SignedSafeMath {
    // --- Authorities ---
    mapping (address => uint) public authorities;
    function addAuthority(address account) external isAuthority { authorities[account] = 1; }
    function removeAuthority(address account) external isAuthority { authorities[account] = 0; }
    modifier isAuthority {
        require(authorities[msg.sender] == 1, "PIScaledGlobalValidator/not-an-authority");
        _;
    }

    // --- Readers ---
    mapping (address => uint) public readers;
    function addReader(address account) external isAuthority { readers[account] = 1; }
    function removeReader(address account) external isAuthority { readers[account] = 0; }
    modifier isReader {
        require(readers[msg.sender] == 1, "PIScaledGlobalValidator/not-a-reader");
        _;
    }

    // --- Structs ---
    struct ControllerGains {
        uint Kp;                                      // [EIGHTEEN_DECIMAL_NUMBER]
        uint Ki;                                      // [EIGHTEEN_DECIMAL_NUMBER]
    }
    struct DeviationObservation {
        uint timestamp;
        int  proportional;
        int  integral;
    }

    // -- Static & Default Variables ---
    // Kp & Ki
    ControllerGains internal controllerGains;
    // Percentage of the current redemptionPrice that must be passed by priceDeviationCumulative in order to set a redemptionRate != 0%
    uint256 internal noiseBarrier;                   // [EIGHTEEN_DECIMAL_NUMBER]
    // Default redemptionRate (0% yearly)
    uint256 internal defaultRedemptionRate;          // [TWENTY_SEVEN_DECIMAL_NUMBER]
    // Max possible annual redemption rate
    uint256 internal feedbackOutputUpperBound;       // [TWENTY_SEVEN_DECIMAL_NUMBER]
    // Min possible annual redemption rate
    int256  internal feedbackOutputLowerBound;       // [TWENTY_SEVEN_DECIMAL_NUMBER]
    // Seconds that must pass between validateSeed calls
    uint256 internal integralPeriodSize;             // [seconds]

    // --- Fluctuating/Dynamic Variables ---
    // Deviation history
    DeviationObservation[] internal deviationObservations;
    // Accumulator for price deviations
    int256  internal priceDeviationCumulative;             // [TWENTY_SEVEN_DECIMAL_NUMBER]
    // Leak applied to priceDeviationCumulative before adding the latest time adjusted deviation
    uint256 internal perSecondCumulativeLeak;              // [EIGHTEEN_DECIMAL_NUMBER]
    // Lower allowed deviation of the per second rate when checking that, after it is raised to defaultGlobalTimeline seconds, it is close to the contract computed global rate
    uint256 internal lowerPrecomputedRateAllowedDeviation; // [EIGHTEEN_DECIMAL_NUMBER]
    // Upper allowed deviation of the per second rate when checking that, after it is raised to defaultGlobalTimeline seconds, it is close to the contract computed global rate
    uint256 internal upperPrecomputedRateAllowedDeviation; // [EIGHTEEN_DECIMAL_NUMBER]
    // Rate applied to lowerPrecomputedRateAllowedDeviation as time passes by and no new seed is validated
    uint256 internal allowedDeviationIncrease;             // [TWENTY_SEVEN_DECIMAL_NUMBER]
    // Minimum rate timeline
    uint256 internal minRateTimeline;                      // [seconds]
    // Last time when the rate was computed
    uint256 internal lastUpdateTime;                       // [timestamp]
    // Default timeline for the global rate
    uint256 internal defaultGlobalTimeline = 31536000;

    // Address that can validate seeds
    address public seedProposer;

    uint256 internal constant NEGATIVE_RATE_LIMIT         = TWENTY_SEVEN_DECIMAL_NUMBER - 1;
    uint256 internal constant TWENTY_SEVEN_DECIMAL_NUMBER = 10 ** 27;
    uint256 internal constant EIGHTEEN_DECIMAL_NUMBER     = 10 ** 18;

    constructor(
        uint256 Kp_,
        uint256 Ki_,
        uint256 perSecondCumulativeLeak_,
        uint256 integralPeriodSize_,
        uint256 lowerPrecomputedRateAllowedDeviation_,
        uint256 upperPrecomputedRateAllowedDeviation_,
        uint256 allowedDeviationIncrease_,
        uint256 noiseBarrier_,
        uint256 feedbackOutputUpperBound_,
        uint256 minRateTimeline_,
        int256  feedbackOutputLowerBound_,
        int256[] memory importedState
    ) public {
        defaultRedemptionRate           = TWENTY_SEVEN_DECIMAL_NUMBER;
        require(lowerPrecomputedRateAllowedDeviation_ < EIGHTEEN_DECIMAL_NUMBER, "PIScaledGlobalValidator/invalid-lprad");
        require(upperPrecomputedRateAllowedDeviation_ <= lowerPrecomputedRateAllowedDeviation_, "PIScaledGlobalValidator/invalid-uprad");
        require(allowedDeviationIncrease_ <= TWENTY_SEVEN_DECIMAL_NUMBER, "PIScaledGlobalValidator/invalid-adi");
        require(Kp_ > 0, "PIScaledGlobalValidator/null-sg");
        require(feedbackOutputUpperBound_ < subtract(subtract(uint(-1), defaultRedemptionRate), 1) && feedbackOutputLowerBound_ < 0, "PIScaledGlobalValidator/invalid-foub-or-folb");
        require(integralPeriodSize_ > 0, "PIScaledGlobalValidator/invalid-ips");
        require(minRateTimeline_ <= defaultGlobalTimeline, "PIScaledGlobalValidator/invalid-mrt");
        require(uint(importedState[0]) <= now, "PIScaledGlobalValidator/invalid-imported-time");
        require(noiseBarrier_ <= EIGHTEEN_DECIMAL_NUMBER, "PIScaledGlobalValidator/invalid-nb");
        authorities[msg.sender]              = 1;
        readers[msg.sender]                  = 1;
        feedbackOutputUpperBound             = feedbackOutputUpperBound_;
        feedbackOutputLowerBound             = feedbackOutputLowerBound_;
        integralPeriodSize                   = integralPeriodSize_;
        controllerGains                      = ControllerGains(Kp_, Ki_);
        lowerPrecomputedRateAllowedDeviation = lowerPrecomputedRateAllowedDeviation_;
        upperPrecomputedRateAllowedDeviation = upperPrecomputedRateAllowedDeviation_;
        allowedDeviationIncrease             = allowedDeviationIncrease_;
        perSecondCumulativeLeak              = perSecondCumulativeLeak_;
        minRateTimeline                      = minRateTimeline_;
        priceDeviationCumulative             = importedState[3];
        noiseBarrier                         = noiseBarrier_;
        lastUpdateTime                       = uint(importedState[0]);
        if (importedState[4] > 0) {
          deviationObservations.push(
            DeviationObservation(uint(importedState[4]), importedState[1], importedState[2])
          );
        }
    }

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- Administration ---
    function modifyParameters(bytes32 parameter, address addr) external isAuthority {
        if (parameter == "seedProposer") {
          readers[seedProposer] = 0;
          seedProposer = addr;
          readers[seedProposer] = 1;
        }
        else revert("PIScaledGlobalValidator/modify-unrecognized-param");
    }
    function modifyParameters(bytes32 parameter, uint256 val) external isAuthority {
        if (parameter == "nb") {
          require(val <= EIGHTEEN_DECIMAL_NUMBER, "PIScaledGlobalValidator/invalid-nb");
          noiseBarrier = val;
        }
        else if (parameter == "ips") {
          require(val > 0, "PIScaledGlobalValidator/null-ips");
          integralPeriodSize = val;
        }
        else if (parameter == "sg") {
          require(val > 0, "PIScaledGlobalValidator/null-sg");
          controllerGains.Kp = val;
        }
        else if (parameter == "ag") {
          controllerGains.Ki = val;
        }
        else if (parameter == "mrt") {
          require(both(val > 0, val <= defaultGlobalTimeline), "PIScaledGlobalValidator/invalid-mrt");
          minRateTimeline = val;
        }
        else if (parameter == "foub") {
          require(val < subtract(subtract(uint(-1), defaultRedemptionRate), 1), "PIScaledGlobalValidator/big-foub");
          feedbackOutputUpperBound = val;
        }
        else if (parameter == "pscl") {
          require(val <= TWENTY_SEVEN_DECIMAL_NUMBER, "PIScaledGlobalValidator/invalid-pscl");
          perSecondCumulativeLeak = val;
        }
        else if (parameter == "lprad") {
          require(val <= EIGHTEEN_DECIMAL_NUMBER && val >= upperPrecomputedRateAllowedDeviation, "PIScaledGlobalValidator/invalid-lprad");
          lowerPrecomputedRateAllowedDeviation = val;
        }
        else if (parameter == "uprad") {
          require(val <= EIGHTEEN_DECIMAL_NUMBER && val <= lowerPrecomputedRateAllowedDeviation, "PIScaledGlobalValidator/invalid-uprad");
          upperPrecomputedRateAllowedDeviation = val;
        }
        else if (parameter == "adi") {
          require(val <= TWENTY_SEVEN_DECIMAL_NUMBER, "PIScaledGlobalValidator/invalid-adi");
          allowedDeviationIncrease = val;
        }
        else if (parameter == "dgt") {
          require(val > 0, "PIScaledGlobalValidator/invalid-dgt");
          defaultGlobalTimeline = val;
        }
        else revert("PIScaledGlobalValidator/modify-unrecognized-param");
    }
    function modifyParameters(bytes32 parameter, int256 val) external isAuthority {
        if (parameter == "folb") {
          require(val < 0, "PIScaledGlobalValidator/invalid-folb");
          feedbackOutputLowerBound = val;
        }
        else if (parameter == "pdc") {
          require(controllerGains.Ki == 0, "PIScaledGlobalValidator/cannot-set-pdc");
          priceDeviationCumulative = val;
        }
        else revert("PIScaledGlobalValidator/modify-unrecognized-param");
    }

    // --- PI Specific Math ---
    function riemannSum(int x, int y) internal pure returns (int z) {
        return addition(x, y) / 2;
    }
    function absolute(int x) internal pure returns (uint z) {
        z = (x < 0) ? uint(-x) : uint(x);
    }

    // --- PI Utils ---
    function getLastProportionalTerm() public isReader view returns (int256) {
        if (oll() == 0) return 0;
        return deviationObservations[oll() - 1].proportional;
    }
    function getLastIntegralTerm() public isReader view returns (int256) {
        if (oll() == 0) return 0;
        return deviationObservations[oll() - 1].integral;
    }
    /**
    * @notice Get the observation list length
    **/
    function oll() public isReader view returns (uint256) {
        return deviationObservations.length;
    }
    function getBoundedRedemptionRate(int piOutput) public isReader view returns (uint256, uint256) {
        int  boundedPIOutput = piOutput;
        uint newRedemptionRate;
        uint rateTimeline = defaultGlobalTimeline;

        if (piOutput < feedbackOutputLowerBound) {
          boundedPIOutput = feedbackOutputLowerBound;
        } else if (piOutput > int(feedbackOutputUpperBound)) {
          boundedPIOutput = int(feedbackOutputUpperBound);
        }

        bool negativeOutputExceedsHundred = (boundedPIOutput < 0 && -boundedPIOutput >= int(defaultRedemptionRate));
        if (negativeOutputExceedsHundred) {
          rateTimeline = divide(multiply(rateTimeline, TWENTY_SEVEN_DECIMAL_NUMBER), uint(-int(boundedPIOutput)));
          if (rateTimeline == 0) {
            rateTimeline = (minRateTimeline == 0) ? 1 : minRateTimeline;
          }
          newRedemptionRate   = uint(addition(int(defaultRedemptionRate), -int(NEGATIVE_RATE_LIMIT)));
        } else {
          if (boundedPIOutput < 0 && boundedPIOutput <= -int(NEGATIVE_RATE_LIMIT)) {
            newRedemptionRate = uint(addition(int(defaultRedemptionRate), -int(NEGATIVE_RATE_LIMIT)));
          } else {
            newRedemptionRate = uint(addition(int(defaultRedemptionRate), boundedPIOutput));
          }
        }

        return (newRedemptionRate, rateTimeline);
    }
    function breaksNoiseBarrier(uint piSum, uint redemptionPrice) public isReader view returns (bool) {
        uint deltaNoise = subtract(multiply(uint(2), EIGHTEEN_DECIMAL_NUMBER), noiseBarrier);
        return piSum >= subtract(divide(multiply(redemptionPrice, deltaNoise), EIGHTEEN_DECIMAL_NUMBER), redemptionPrice);
    }
    function correctPreComputedRate(uint precomputedRate, uint contractComputedRate, uint precomputedAllowedDeviation) public isReader view returns (bool) {
        if (precomputedRate == contractComputedRate) return true;
        bool withinBounds = (
          precomputedRate >= divide(multiply(contractComputedRate, precomputedAllowedDeviation), EIGHTEEN_DECIMAL_NUMBER) &&
          precomputedRate <= divide(multiply(contractComputedRate, subtract(multiply(uint(2), EIGHTEEN_DECIMAL_NUMBER), precomputedAllowedDeviation)), EIGHTEEN_DECIMAL_NUMBER)
        );
        bool sameSign = true;
        if (
          contractComputedRate < TWENTY_SEVEN_DECIMAL_NUMBER && precomputedRate >= TWENTY_SEVEN_DECIMAL_NUMBER ||
          contractComputedRate > TWENTY_SEVEN_DECIMAL_NUMBER && precomputedRate <= TWENTY_SEVEN_DECIMAL_NUMBER
        ) {
          sameSign = false;
        }
        return (withinBounds && sameSign);
    }
    function getNextPriceDeviationCumulative(int proportionalTerm, uint accumulatedLeak) public isReader view returns (int256, int256) {
        int256 lastProportionalTerm      = getLastProportionalTerm();
        uint256 timeElapsed              = (lastUpdateTime == 0) ? 0 : subtract(now, lastUpdateTime);
        int256 newTimeAdjustedDeviation  = multiply(riemannSum(proportionalTerm, lastProportionalTerm), int(timeElapsed));
        int256 leakedPriceCumulative     = divide(multiply(int(accumulatedLeak), priceDeviationCumulative), int(TWENTY_SEVEN_DECIMAL_NUMBER));

        return (
          addition(leakedPriceCumulative, newTimeAdjustedDeviation),
          newTimeAdjustedDeviation
        );
    }
    function getGainAdjustedPIOutput(int proportionalTerm, int integralTerm) public isReader view returns (int256) {
        (int adjustedProportional, int adjustedIntegral) = getGainAdjustedTerms(proportionalTerm, integralTerm);
        return addition(adjustedProportional, adjustedIntegral);
    }
    function getGainAdjustedTerms(int proportionalTerm, int integralTerm) public isReader view returns (int256, int256) {
        bool pTermExceedsMaxUint = (absolute(proportionalTerm) >= uint(-1) / controllerGains.Kp);
        bool iTermExceedsMaxUint = (controllerGains.Ki == 0) ? false : (absolute(integralTerm) >= uint(-1) / controllerGains.Ki);

        int adjustedProportional = (pTermExceedsMaxUint) ? proportionalTerm : multiply(proportionalTerm, int(controllerGains.Kp)) / int(EIGHTEEN_DECIMAL_NUMBER);
        int adjustedIntegral     = (iTermExceedsMaxUint) ? integralTerm : multiply(integralTerm, int(controllerGains.Ki)) / int(EIGHTEEN_DECIMAL_NUMBER);

        return (adjustedProportional, adjustedIntegral);
    }

    // --- Rate Validation ---
    function validateSeed(
      uint seed,
      uint inputAccumulatedPreComputedRate,
      uint marketPrice,
      uint redemptionPrice,
      uint accumulatedLeak,
      uint precomputedAllowedDeviation
    ) external returns (uint256) {
        // Only the proposer can call
        require(seedProposer == msg.sender, "PIScaledGlobalValidator/invalid-msg-sender");
        // Can't update same observation twice
        require(subtract(now, lastUpdateTime) >= integralPeriodSize || lastUpdateTime == 0, "PIScaledGlobalValidator/wait-more");
        // Get the scaled market price
        uint256 scaledMarketPrice = multiply(marketPrice, 10**9);
        // Calculate proportional term
        int256 proportionalTerm = multiply(subtract(int(redemptionPrice), int(scaledMarketPrice)), int(TWENTY_SEVEN_DECIMAL_NUMBER)) / int(redemptionPrice);
        // Update deviation history
        updateDeviationHistory(proportionalTerm, accumulatedLeak);
        // Update timestamp
        lastUpdateTime = now;
        // Calculate the adjusted PI output
        int piOutput = getGainAdjustedPIOutput(proportionalTerm, priceDeviationCumulative);
        // Check if P + I is greater than noise and non null
        if (
          breaksNoiseBarrier(absolute(piOutput), redemptionPrice) &&
          piOutput != 0
        ) {
          // Make sure the global rate doesn't exceed the bounds
          (uint newRedemptionRate, ) = getBoundedRedemptionRate(piOutput);
          // Sanitize the precomputed allowed deviation
          uint256 sanitizedAllowedDeviation =
            (precomputedAllowedDeviation > upperPrecomputedRateAllowedDeviation) ?
            upperPrecomputedRateAllowedDeviation : precomputedAllowedDeviation;
          // Check that the caller provided a correct precomputed rate
          require(
            correctPreComputedRate(inputAccumulatedPreComputedRate, newRedemptionRate, sanitizedAllowedDeviation),
            "PIScaledGlobalValidator/invalid-seed"
          );
          return seed;
        } else {
          return TWENTY_SEVEN_DECIMAL_NUMBER;
        }
    }
    // Update accumulator and deviation history
    function updateDeviationHistory(int proportionalTerm, uint accumulatedLeak) internal {
        (int256 virtualDeviationCumulative, int256 nextTimeAdjustedDeviation) =
          getNextPriceDeviationCumulative(proportionalTerm, accumulatedLeak);
        priceDeviationCumulative = virtualDeviationCumulative;
        deviationObservations.push(DeviationObservation(now, proportionalTerm, priceDeviationCumulative));
    }
    function getNextRedemptionRate(uint marketPrice, uint redemptionPrice, uint accumulatedLeak)
      public isReader view returns (uint256, int256, int256, uint256) {
        // Get the scaled market price
        uint256 scaledMarketPrice = multiply(marketPrice, 10**9);
        // Calculate proportional term
        int256 proportionalTerm = multiply(subtract(int(redemptionPrice), int(scaledMarketPrice)), int(TWENTY_SEVEN_DECIMAL_NUMBER)) / int(redemptionPrice);
        // Get cumulative price deviation
        (int cumulativeDeviation, ) = getNextPriceDeviationCumulative(proportionalTerm, accumulatedLeak);
        // Calculate the PI output
        int piOutput = getGainAdjustedPIOutput(proportionalTerm, cumulativeDeviation);
        // Check if P + I is greater than noise
        if (
          breaksNoiseBarrier(absolute(piOutput), redemptionPrice) &&
          piOutput != 0
        ) {
          // Get the new rate as well as the timeline
          (uint newRedemptionRate, uint rateTimeline) = getBoundedRedemptionRate(piOutput);
          // Return the bounded result
          return (newRedemptionRate, proportionalTerm, cumulativeDeviation, rateTimeline);
        } else {
          // If it's not, simply return the default global rate and the computed terms
          return (TWENTY_SEVEN_DECIMAL_NUMBER, proportionalTerm, cumulativeDeviation, defaultGlobalTimeline);
        }
    }

    // --- Parameter Getters ---
    function rt(uint marketPrice, uint redemptionPrice, uint accumulatedLeak) external isReader view returns (uint256) {
        (, , , uint rateTimeline) = getNextRedemptionRate(marketPrice, redemptionPrice, accumulatedLeak);
        return rateTimeline;
    }
    function sg() external isReader view returns (uint256) {
        return controllerGains.Kp;
    }
    function ag() external isReader view returns (uint256) {
        return controllerGains.Ki;
    }
    function nb() external isReader view returns (uint256) {
        return noiseBarrier;
    }
    function drr() external isReader view returns (uint256) {
        return defaultRedemptionRate;
    }
    function foub() external isReader view returns (uint256) {
        return feedbackOutputUpperBound;
    }
    function folb() external isReader view returns (int256) {
        return feedbackOutputLowerBound;
    }
    function ips() external isReader view returns (uint256) {
        return integralPeriodSize;
    }
    function dos(uint256 i) external isReader view returns (uint256, int256, int256) {
        return (deviationObservations[i].timestamp, deviationObservations[i].proportional, deviationObservations[i].integral);
    }
    function pdc() external isReader view returns (int256) {
        return priceDeviationCumulative;
    }
    function pscl() external isReader view returns (uint256) {
        return perSecondCumulativeLeak;
    }
    function lprad() external isReader view returns (uint256) {
        return lowerPrecomputedRateAllowedDeviation;
    }
    function uprad() external isReader view returns (uint256) {
        return upperPrecomputedRateAllowedDeviation;
    }
    function adi() external isReader view returns (uint256) {
        return allowedDeviationIncrease;
    }
    function mrt() external isReader view returns (uint256) {
        return minRateTimeline;
    }
    function lut() external isReader view returns (uint256) {
        return lastUpdateTime;
    }
    function dgt() external isReader view returns (uint256) {
        return defaultGlobalTimeline;
    }
    function adat() external isReader view returns (uint256) {
        uint elapsed = subtract(now, lastUpdateTime);
        if (elapsed < integralPeriodSize) {
          return 0;
        }
        return subtract(elapsed, integralPeriodSize);
    }
    function tlv() external isReader view returns (uint256) {
        uint elapsed = (lastUpdateTime == 0) ? 0 : subtract(now, lastUpdateTime);
        return elapsed;
    }
}
