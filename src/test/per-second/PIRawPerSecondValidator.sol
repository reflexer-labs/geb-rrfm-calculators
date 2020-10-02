pragma solidity ^0.6.7;

import "ds-test/test.sol";

import {PIRawPerSecondValidator} from '../../validator/per-second/raw/PIRawPerSecondValidator.sol';
import {MockRateSetter} from "../utils/mock/MockRateSetter.sol";
import "../utils/mock/MockOracleRelayer.sol";

contract Feed {
    bytes32 public price;
    bool public validPrice;
    uint public lastUpdateTime;
    constructor(uint256 price_, bool validPrice_) public {
        price = bytes32(price_);
        validPrice = validPrice_;
        lastUpdateTime = now;
    }
    function updateTokenPrice(uint256 price_) external {
        price = bytes32(price_);
        lastUpdateTime = now;
    }
    function getResultWithValidity() external view returns (uint256, bool) {
        return (uint(price), validPrice);
    }
}

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract PIRawPerSecondValidatorTest is DSTest {
    Hevm hevm;

    MockOracleRelayer oracleRelayer;
    MockRateSetter rateSetter;

    PIRawPerSecondValidator validator;
    Feed orcl;

    uint256 Kp                                = EIGHTEEN_DECIMAL_NUMBER;
    uint256 Ki                                = EIGHTEEN_DECIMAL_NUMBER;
    uint256 integralPeriodSize                = 3600;
    uint256 baseUpdateCallerReward            = 10 ether;
    uint256 maxUpdateCallerReward             = 30 ether;
    uint256 perSecondCallerRewardIncrease     = 1000002763984612345119745925;
    uint256 perSecondCumulativeLeak           = 999997208243937652252849536; // 1% per hour
    uint256 noiseBarrier                      = EIGHTEEN_DECIMAL_NUMBER;
    uint256 feedbackOutputUpperBound          = TWENTY_SEVEN_DECIMAL_NUMBER * EIGHTEEN_DECIMAL_NUMBER;
    int256  feedbackOutputLowerBound          = -int(NEGATIVE_RATE_LIMIT);
    uint8   integralGranularity               = 24;

    int256[] importedState = new int[](5);
    address self;

    function setUp() public {
      hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
      hevm.warp(604411200);

      oracleRelayer = new MockOracleRelayer();
      orcl = new Feed(1 ether, true);

      validator = new PIRawPerSecondValidator(
        Kp,
        Ki,
        perSecondCumulativeLeak,
        integralPeriodSize,
        noiseBarrier,
        feedbackOutputUpperBound,
        feedbackOutputLowerBound,
        importedState
      );

      rateSetter = new MockRateSetter(address(orcl), address(oracleRelayer), address(validator));
      validator.modifyParameters("seedProposer", address(rateSetter));

      self = address(this);
    }

    // --- Math ---
    uint constant defaultGlobalTimeline = 1;
    uint constant TWENTY_SEVEN_DECIMAL_NUMBER = 10 ** 27;
    uint constant EIGHTEEN_DECIMAL_NUMBER = 10 ** 18;
    uint256 constant NEGATIVE_RATE_LIMIT = TWENTY_SEVEN_DECIMAL_NUMBER - 1;

    function rpower(uint x, uint n, uint base) internal pure returns (uint z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, base)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function wmultiply(uint x, uint y) internal pure returns (uint z) {
        z = multiply(x, y) / EIGHTEEN_DECIMAL_NUMBER;
    }
    function rmultiply(uint x, uint y) internal pure returns (uint z) {
        z = multiply(x, y) / TWENTY_SEVEN_DECIMAL_NUMBER;
    }
    function rdivide(uint x, uint y) internal pure returns (uint z) {
        z = multiply(x, TWENTY_SEVEN_DECIMAL_NUMBER) / y;
    }

    function test_correct_setup() public {
        assertEq(validator.readers(address(this)), 1);
        assertEq(validator.readers(address(rateSetter)), 1);
        assertEq(validator.authorities(address(this)), 1);

        assertEq(validator.nb(), noiseBarrier);
        assertEq(validator.foub(), feedbackOutputUpperBound);
        assertEq(validator.folb(), feedbackOutputLowerBound);
        assertEq(validator.lut(), 0);
        assertEq(validator.ips(), integralPeriodSize);
        assertEq(validator.pdc(), 0);
        assertEq(validator.pscl(), perSecondCumulativeLeak);
        assertEq(validator.drr(), TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(Kp, validator.ag());
        assertEq(Ki, validator.sg());
        assertEq(validator.oll(), 0);
        assertEq(validator.mrt(), 1);
        assertEq(validator.tlv(), 0);
    }
    function test_modify_parameters() public {
        // Uint
        validator.modifyParameters("nb", EIGHTEEN_DECIMAL_NUMBER);
        validator.modifyParameters("ips", uint(2));
        validator.modifyParameters("sg", uint(1));
        validator.modifyParameters("ag", uint(1));
        validator.modifyParameters("foub", uint(TWENTY_SEVEN_DECIMAL_NUMBER + 1));
        validator.modifyParameters("folb", -int(1));
        validator.modifyParameters("pscl", uint(TWENTY_SEVEN_DECIMAL_NUMBER - 5));

        assertEq(validator.nb(), EIGHTEEN_DECIMAL_NUMBER);
        assertEq(validator.ips(), uint(2));
        assertEq(validator.foub(), uint(TWENTY_SEVEN_DECIMAL_NUMBER + 1));
        assertEq(validator.folb(), -int(1));
        assertEq(validator.pscl(), TWENTY_SEVEN_DECIMAL_NUMBER - 5);
        assertEq(validator.mrt(), 1);

        assertEq(uint(1), validator.ag());
        assertEq(uint(1), validator.sg());
    }
    function test_get_new_rate_no_proportional_no_integral() public {
        (uint newRedemptionRate, int pTerm, int iTerm, uint rateTimeline) =
          validator.getNextRedemptionRate(EIGHTEEN_DECIMAL_NUMBER, TWENTY_SEVEN_DECIMAL_NUMBER, rateSetter.iapcr());
        assertEq(newRedemptionRate, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(pTerm, 0);
        assertEq(iTerm, 0);
        assertEq(rateTimeline, defaultGlobalTimeline);

        // Verify that it did not change state
        assertEq(validator.readers(address(this)), 1);
        assertEq(validator.readers(address(rateSetter)), 1);
        assertEq(validator.authorities(address(this)), 1);

        assertEq(validator.nb(), noiseBarrier);
        assertEq(validator.foub(), feedbackOutputUpperBound);
        assertEq(validator.folb(), feedbackOutputLowerBound);
        assertEq(validator.lut(), 0);
        assertEq(validator.ips(), integralPeriodSize);
        assertEq(validator.pdc(), 0);
        assertEq(validator.pscl(), perSecondCumulativeLeak);
        assertEq(validator.drr(), TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(Kp, validator.ag());
        assertEq(Ki, validator.sg());
        assertEq(validator.oll(), 0);
        assertEq(validator.mrt(), 1);
        assertEq(validator.tlv(), 0);
    }
    function test_first_update_rate_no_deviation() public {
        hevm.warp(now + validator.ips() + 1);

        rateSetter.updateRate(TWENTY_SEVEN_DECIMAL_NUMBER, address(this));
        assertEq(uint(validator.lut()), now);
        assertEq(uint(validator.pdc()), 0);

        assertEq(oracleRelayer.redemptionPrice(), TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(oracleRelayer.redemptionRate(), TWENTY_SEVEN_DECIMAL_NUMBER);

        (uint timestamp, int proportional, int integral) =
          validator.dos(validator.oll() - 1);

        assertEq(timestamp, now);
        assertEq(proportional, 0);
        assertEq(integral, 0);
    }
    function testFail_update_invalid_market_price() public {
        orcl = new Feed(1 ether, false);
        rateSetter.modifyParameters("orcl", address(orcl));
        hevm.warp(now + validator.ips() + 1);
        rateSetter.updateRate(TWENTY_SEVEN_DECIMAL_NUMBER, address(this));
    }
    function testFail_update_same_period_warp() public {
        hevm.warp(now + validator.ips() + 1);
        rateSetter.updateRate(TWENTY_SEVEN_DECIMAL_NUMBER, address(this));
        rateSetter.updateRate(TWENTY_SEVEN_DECIMAL_NUMBER, address(this));
    }
    function testFail_update_same_period_no_warp() public {
        rateSetter.updateRate(TWENTY_SEVEN_DECIMAL_NUMBER, address(this));
        rateSetter.updateRate(TWENTY_SEVEN_DECIMAL_NUMBER, address(this));
    }
    function test_get_new_rate_no_warp_zero_current_integral() public {
        validator.modifyParameters("nb", uint(0.94E18));

        orcl.updateTokenPrice(1.05E18); // 5% deviation

        (uint newRedemptionRate, int pTerm, int iTerm, uint rateTimeline) =
          validator.getNextRedemptionRate(1.05E18, TWENTY_SEVEN_DECIMAL_NUMBER, rateSetter.iapcr());
        assertEq(newRedemptionRate, 1E27);
        assertEq(pTerm, -0.05E27);
        assertEq(iTerm, 0);
        assertEq(rateTimeline, defaultGlobalTimeline);

        orcl.updateTokenPrice(0.995E18); // -0.5% deviation

        (newRedemptionRate, pTerm, iTerm, rateTimeline) =
          validator.getNextRedemptionRate(0.995E18, TWENTY_SEVEN_DECIMAL_NUMBER, rateSetter.iapcr());
        assertEq(newRedemptionRate, 1E27);
        assertEq(pTerm, 0.005E27);
        assertEq(iTerm, 0);
        assertEq(rateTimeline, defaultGlobalTimeline);
    }
    function test_first_small_positive_deviation() public {
        assertEq(uint(validator.pdc()), 0);

        validator.modifyParameters("nb", uint(0.995E18));

        hevm.warp(now + validator.ips());
        orcl.updateTokenPrice(1.05E18);

        (uint newRedemptionRate, int pTerm, int iTerm, uint rateTimeline) =
          validator.getNextRedemptionRate(1.05E18, TWENTY_SEVEN_DECIMAL_NUMBER, rateSetter.iapcr());
        assertEq(newRedemptionRate, 0.95E27);
        assertEq(pTerm, -0.05E27);
        assertEq(iTerm, 0);
        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(1, address(this)); // irrelevant because the contract computes everything by itself

        assertEq(uint(validator.lut()), now);
        assertEq(validator.pdc(), 0);
        assertEq(oracleRelayer.redemptionPrice(), TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(oracleRelayer.redemptionRate(), 0.95E27);

        (uint timestamp, int proportional, int integral) =
          validator.dos(validator.oll() - 1);

        assertEq(timestamp, now);
        assertEq(proportional, -0.05E27);
        assertEq(integral, 0);
    }
    function test_first_small_negative_deviation() public {
        assertEq(uint(validator.pdc()), 0);

        validator.modifyParameters("nb", uint(0.995E18));

        hevm.warp(now + validator.ips());

        orcl.updateTokenPrice(0.95E18);

        (uint newRedemptionRate, int pTerm, int iTerm, uint rateTimeline) =
          validator.getNextRedemptionRate(0.95E18, TWENTY_SEVEN_DECIMAL_NUMBER, rateSetter.iapcr());
        assertEq(newRedemptionRate, 1.05E27);
        assertEq(pTerm, 0.05E27);
        assertEq(iTerm, 0);
        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(2, address(this));

        assertEq(uint(validator.lut()), now);
        assertEq(validator.pdc(), 0);
        assertEq(oracleRelayer.redemptionPrice(), TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(oracleRelayer.redemptionRate(), 1.05E27);
    }
    function test_two_small_positive_deviations() public {
        assertEq(uint(validator.pdc()), 0);
        validator.modifyParameters("nb", uint(0.995E18));

        hevm.warp(now + validator.ips());

        orcl.updateTokenPrice(1.05E18);
        rateSetter.updateRate(42, address(this)); // -5% global rate

        hevm.warp(now + validator.ips());
        assertEq(oracleRelayer.redemptionPrice(), 1);

        (uint newRedemptionRate, int pTerm, int iTerm, uint rateTimeline) =
          validator.getNextRedemptionRate(1.05E18, oracleRelayer.redemptionPrice(), rateSetter.iapcr());
        assertEq(newRedemptionRate, 1);
        assertEq(pTerm, -1049999999999999999999999999);
        assertEq(iTerm, -1979999999999999999999999996400);

        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(42, address(this));

        assertEq(uint(validator.lut()), now);
        assertEq(validator.pdc(), -1979999999999999999999999996400);
        assertEq(oracleRelayer.redemptionPrice(), 1);
        assertEq(oracleRelayer.redemptionRate(), 1);
    }
    function test_big_delay_positive_deviation() public {
        assertEq(uint(validator.pdc()), 0);
        validator.modifyParameters("nb", uint(0.995E18));

        hevm.warp(now + validator.ips());

        orcl.updateTokenPrice(1.05E18);
        rateSetter.updateRate(42, address(this));

        hevm.warp(now + validator.ips() * 10); // 10 hours

        (uint newRedemptionRate, int pTerm, int iTerm, uint rateTimeline) =
          validator.getNextRedemptionRate(1.05E18, oracleRelayer.redemptionPrice(), rateSetter.iapcr());
        assertEq(newRedemptionRate, 1);
        assertEq(pTerm, -1049999999999999999999999999);
        assertEq(iTerm, -19799999999999999999999999964000);
        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(42, address(this));
    }
    function test_normalized_pi_result() public {
        assertEq(uint(validator.pdc()), 0);
        validator.modifyParameters("nb", EIGHTEEN_DECIMAL_NUMBER - 1);

        hevm.warp(now + validator.ips());
        orcl.updateTokenPrice(0.95E18);

        (uint newRedemptionRate, int pTerm, int iTerm, uint rateTimeline) =
          validator.getNextRedemptionRate(0.95E18, TWENTY_SEVEN_DECIMAL_NUMBER, rateSetter.iapcr());
        assertEq(newRedemptionRate, 1.05E27);
        assertEq(pTerm, 0.05E27);
        assertEq(iTerm, 0);
        assertEq(rateTimeline, defaultGlobalTimeline);

        Kp = Kp / 4 / (validator.ips() * 24);
        Ki = Ki / 4 / validator.ips() ** 2 / 24;

        assertEq(Kp, 2893518518518);
        assertEq(Ki, 803755144);

        validator.modifyParameters("sg", Kp);
        validator.modifyParameters("ag", Ki);

        (int gainAdjustedP, int gainAdjustedI) = validator.getGainAdjustedTerms(int(0.05E27), int(0));
        assertEq(gainAdjustedP, 144675925925900000000);
        assertEq(gainAdjustedI, 0);

        (newRedemptionRate, pTerm, iTerm, rateTimeline) =
          validator.getNextRedemptionRate(0.95E18, TWENTY_SEVEN_DECIMAL_NUMBER, rateSetter.iapcr());
        assertEq(newRedemptionRate, 1000000144675925925900000000);
        assertEq(pTerm, 0.05E27);
        assertEq(iTerm, 0);
        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(42, address(this));
        hevm.warp(now + validator.ips());

        (newRedemptionRate, pTerm, iTerm, rateTimeline) =
          validator.getNextRedemptionRate(0.95E18, oracleRelayer.redemptionPrice(), rateSetter.iapcr());
        assertEq(newRedemptionRate, 1000000291613001814917161083);
        assertEq(pTerm, 50520968952868729114836237);
        assertEq(iTerm, 180937744115163712406705224800);
        assertEq(rateTimeline, defaultGlobalTimeline);
    }
}
