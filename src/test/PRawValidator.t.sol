pragma solidity ^0.6.7;

import "ds-test/test.sol";

import {PRawValidator} from '../validator/raw/PRawValidator.sol';
import {MockRateSetter} from "./utils/mock/MockRateSetter.sol";
import "./utils/mock/MockOracleRelayer.sol";

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
    function getResultWithValidity() external view returns (bytes32, bool) {
        return (price, validPrice);
    }
}

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract PRawValidatorTest is DSTest {
    Hevm hevm;

    MockOracleRelayer oracleRelayer;
    MockRateSetter rateSetter;

    PRawValidator validator;
    Feed orcl;

    uint256 Kp                                   = EIGHTEEN_DECIMAL_NUMBER;
    uint256 periodSize                           = 3600;
    uint256 minRateTimeline                      = 0;
    uint256 lowerPrecomputedRateAllowedDeviation = 0.99E18;
    uint256 upperPrecomputedRateAllowedDeviation = 0.99E18;
    uint256 allowedDeviationIncrease             = TWENTY_SEVEN_DECIMAL_NUMBER;
    uint256 noiseBarrier                         = EIGHTEEN_DECIMAL_NUMBER;
    uint256 feedbackOutputUpperBound             = TWENTY_SEVEN_DECIMAL_NUMBER * EIGHTEEN_DECIMAL_NUMBER;
    int256  feedbackOutputLowerBound             = -int(TWENTY_SEVEN_DECIMAL_NUMBER * EIGHTEEN_DECIMAL_NUMBER);

    int256[] importedState = new int[](3);
    address self;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        orcl = new Feed(1 ether, true);
        oracleRelayer = new MockOracleRelayer();

        validator = new PRawValidator(
          Kp,
          periodSize,
          lowerPrecomputedRateAllowedDeviation,
          upperPrecomputedRateAllowedDeviation,
          allowedDeviationIncrease,
          noiseBarrier,
          feedbackOutputUpperBound,
          minRateTimeline,
          feedbackOutputLowerBound,
          importedState
        );

        rateSetter = new MockRateSetter(address(orcl), address(oracleRelayer), address(validator));
        validator.modifyParameters("seedProposer", address(rateSetter));

        self = address(this);
    }

    // --- Math ---
    uint constant defaultGlobalTimeline = 31536000;
    uint constant TWENTY_SEVEN_DECIMAL_NUMBER = 10 ** 27;
    uint constant EIGHTEEN_DECIMAL_NUMBER = 10 ** 18;

    function test_correct_setup() public {
        assertEq(validator.readers(address(this)), 1);
        assertEq(validator.readers(address(rateSetter)), 1);
        assertEq(validator.authorities(address(this)), 1);

        assertEq(validator.seedProposer(), address(rateSetter));
        assertEq(validator.nb(), noiseBarrier);
        assertEq(validator.foub(), feedbackOutputUpperBound);
        assertEq(validator.folb(), feedbackOutputLowerBound);
        assertEq(validator.lut(), 0);
        assertEq(validator.ps(), periodSize);
        assertEq(validator.lprad(), lowerPrecomputedRateAllowedDeviation);
        assertEq(validator.uprad(), upperPrecomputedRateAllowedDeviation);
        assertEq(validator.adi(), allowedDeviationIncrease);
        assertEq(Kp, validator.sg());
        assertEq(validator.drr(), TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(validator.pscl(), int(TWENTY_SEVEN_DECIMAL_NUMBER));
        assertEq(validator.oll(), 0);
        assertEq(validator.mrt(), 0);
        assertEq(validator.tlv(), 0);
    }
    function test_modify_parameters() public {
        // Addresses
        validator.modifyParameters("seedProposer", address(0x1234));
        assertTrue(address(validator.seedProposer()) == address(0x1234));

        assertEq(validator.readers(address(rateSetter)), 0);
        assertEq(validator.readers(address(0x1234)), 1);

        // Uint
        validator.modifyParameters("nb", EIGHTEEN_DECIMAL_NUMBER);
        validator.modifyParameters("ps", uint(1));
        validator.modifyParameters("sg", uint(1));
        validator.modifyParameters("foub", TWENTY_SEVEN_DECIMAL_NUMBER + 1);
        validator.modifyParameters("folb", -int(1));
        validator.modifyParameters("mrt", uint(24 * 3600));

        assertEq(validator.nb(), EIGHTEEN_DECIMAL_NUMBER);
        assertEq(validator.foub(), TWENTY_SEVEN_DECIMAL_NUMBER + 1);
        assertEq(validator.ps(), 1);
        assertEq(validator.sg(), 1);
        assertEq(validator.folb(), -int(1));
        assertEq(validator.mrt(), 24 * 3600);
        assertEq(1, validator.sg());
    }
    function test_get_annual_rate_no_proportional() public {
        (uint newRate, int pTerm, uint rateTimeline) = validator.getNextRedemptionRate(
          EIGHTEEN_DECIMAL_NUMBER, TWENTY_SEVEN_DECIMAL_NUMBER
        );
        assertEq(newRate, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(pTerm, 0);
        assertEq(rateTimeline, defaultGlobalTimeline);

        // Verify that it did not change state
        assertEq(validator.readers(address(this)), 1);
        assertEq(validator.readers(address(rateSetter)), 1);
        assertEq(validator.authorities(address(this)), 1);

        assertEq(validator.seedProposer(), address(rateSetter));
        assertEq(validator.nb(), noiseBarrier);
        assertEq(validator.foub(), feedbackOutputUpperBound);
        assertEq(validator.folb(), feedbackOutputLowerBound);
        assertEq(validator.lut(), 0);
        assertEq(validator.ps(), periodSize);
        assertEq(validator.lprad(), lowerPrecomputedRateAllowedDeviation);
        assertEq(validator.uprad(), upperPrecomputedRateAllowedDeviation);
        assertEq(validator.adi(), allowedDeviationIncrease);
        assertEq(Kp, validator.sg());
        assertEq(validator.drr(), TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(validator.pscl(), int(TWENTY_SEVEN_DECIMAL_NUMBER));
        assertEq(validator.oll(), 0);
        assertEq(validator.mrt(), 0);
        assertEq(validator.tlv(), 0);
    }
    function test_update_rate_no_deviation() public {
        hevm.warp(now + validator.ps() + 1);

        (uint newRate, ,) = validator.getNextRedemptionRate(
          EIGHTEEN_DECIMAL_NUMBER, TWENTY_SEVEN_DECIMAL_NUMBER
        );

        assertEq(rateSetter.iapcr(), TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(validator.rt(1 ether, TWENTY_SEVEN_DECIMAL_NUMBER, rateSetter.iapcr()), defaultGlobalTimeline);
        assertEq(rateSetter.getRTAdjustedSeed(TWENTY_SEVEN_DECIMAL_NUMBER, 1 ether, TWENTY_SEVEN_DECIMAL_NUMBER), TWENTY_SEVEN_DECIMAL_NUMBER);
        assertTrue(validator.correctPreComputedRate(TWENTY_SEVEN_DECIMAL_NUMBER, newRate, lowerPrecomputedRateAllowedDeviation));

        rateSetter.updateRate(TWENTY_SEVEN_DECIMAL_NUMBER, address(this));

        assertEq(validator.lut(), now);
        assertEq(oracleRelayer.redemptionPrice(), TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(oracleRelayer.redemptionRate(), TWENTY_SEVEN_DECIMAL_NUMBER);
        (uint timestamp, int timeAdjustedDeviation) = validator.dos(validator.oll() - 1);
        assertEq(timestamp, now);
        assertEq(timeAdjustedDeviation, 0);
    }
    function testFail_update_invalid_market_price() public {
        orcl = new Feed(1 ether, false);
        rateSetter.modifyParameters("orcl", address(orcl));
        hevm.warp(now + validator.ps() + 1);
        rateSetter.updateRate(TWENTY_SEVEN_DECIMAL_NUMBER, address(this));
    }
    function testFail_update_same_period_warp() public {
        hevm.warp(now + validator.ps() + 1);
        rateSetter.updateRate(TWENTY_SEVEN_DECIMAL_NUMBER, address(this));
        rateSetter.updateRate(TWENTY_SEVEN_DECIMAL_NUMBER, address(this));
    }
    function testFail_update_same_period_no_warp() public {
        rateSetter.updateRate(TWENTY_SEVEN_DECIMAL_NUMBER, address(this));
        rateSetter.updateRate(TWENTY_SEVEN_DECIMAL_NUMBER, address(this));
    }
    function test_get_annual_rate_no_warp_with_deviation() public {
        validator.modifyParameters("nb", uint(0.94E18));

        (uint newRate, int pTerm, uint rateTimeline) = validator.getNextRedemptionRate(1.05E18, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(newRate, 1E27);
        assertEq(pTerm, -0.05E27);
        assertEq(rateTimeline, defaultGlobalTimeline);

        (newRate, pTerm, rateTimeline) = validator.getNextRedemptionRate(0.995E18, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(newRate, 1E27);
        assertEq(pTerm, 0.005E27);
        assertEq(rateTimeline, defaultGlobalTimeline);
    }
    function test_get_annual_rate_with_warp_with_deviation() public {
        validator.modifyParameters("nb", uint(0.94E18));

        hevm.warp(now + validator.ps() * 2);

        (uint newRate, int pTerm, uint rateTimeline) = validator.getNextRedemptionRate(1.05E18, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(newRate, 1E27);
        assertEq(pTerm, -0.05E27);
        assertEq(rateTimeline, defaultGlobalTimeline);

        (newRate, pTerm, rateTimeline) = validator.getNextRedemptionRate(0.995E18, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(newRate, 1E27);
        assertEq(pTerm, 0.005E27);
        assertEq(rateTimeline, defaultGlobalTimeline);
    }
    function test_proportional_warp_positive_and_negative_deviation() public {
        validator.modifyParameters("nb", uint(0.995E18));

        orcl.updateTokenPrice(1.05E18);
        hevm.warp(now + validator.ps() * 2);

        (uint newRate, int pTerm, uint rateTimeline) = validator.getNextRedemptionRate(1.05E18, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(newRate, 0.95E27);
        assertEq(pTerm, -0.05E27);
        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(999999998373500306131523668, address(this));
        assertEq(oracleRelayer.redemptionPrice(), TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(oracleRelayer.redemptionRate(), 999999998373500306131523668);

        hevm.warp(now + validator.ps() * 2);
        assertEq(oracleRelayer.redemptionPrice(), 999988289270765748110637924);

        orcl.updateTokenPrice(0.95E18);

        (newRate, pTerm, rateTimeline) = validator.getNextRedemptionRate(0.95E18, oracleRelayer.redemptionPrice());
        assertEq(newRate, 1049988289270765748110637924);
        assertEq(pTerm, 49988289270765748110637924);
        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(1000000001546772294187589218, address(this));
        assertEq(oracleRelayer.redemptionRate(), 1000000001546772294187589218);
    }
    function test_proportional_warp_negative_ninety_nine_annual_rate() public {
        validator.modifyParameters("nb", uint(0.995E18));

        hevm.warp(now + validator.ps() * 2);
        orcl.updateTokenPrice(1.99E18);

        (uint newRate, int pTerm, uint rateTimeline) = validator.getNextRedemptionRate(1.99E18, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(newRate, 1E25);
        assertEq(pTerm, -99E25);
        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(999999853971022014715394140, address(this)); // -99% global rate
    }
    function test_proportional_warp_positive_ninety_nine_annual_rate() public {
        validator.modifyParameters("nb", uint(0.995E18));

        hevm.warp(now + validator.ps() * 2);
        orcl.updateTokenPrice(0.01E18);

        (uint newRate, int pTerm, uint rateTimeline) = validator.getNextRedemptionRate(0.01E18, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(newRate, 1.99E27);
        assertEq(pTerm, 99E25);
        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(1000000021820606489223699321, address(this)); // 99% global rate
    }
    function test_proportional_warp_positive_above_positive_hundred_percent() public {
        validator.modifyParameters("nb", uint(0.995E18));
        validator.modifyParameters("sg", uint(10E18));

        hevm.warp(now + validator.ps() * 2);
        orcl.updateTokenPrice(0.5E18);

        (uint newRate, int pTerm, uint rateTimeline) = validator.getNextRedemptionRate(0.5E18, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(newRate, 6E27);
        assertEq(pTerm, 50E25);
        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(1000000056816321668209211588, address(this)); // 500% global rate
    }
    function test_proportional_warp_positive_below_negative_hundred_percent_ray_divisible() public {
        validator.modifyParameters("nb", uint(0.995E18));
        validator.modifyParameters("sg", uint(10E18));

        hevm.warp(now + validator.ps() * 2);
        orcl.updateTokenPrice(1.5E18);

        (uint newRate, int pTerm, uint rateTimeline) = validator.getNextRedemptionRate(1.5E18, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(newRate, 1);
        assertEq(pTerm, -5E26);
        assertEq(rateTimeline, 6307200);

        rateSetter.updateRate(999990143091845931021814636, address(this)); // approx -99.99999999999999999999 over 73 days

        hevm.warp(now + 6307200 / 2);

        assertEq(oracleRelayer.redemptionRate(), 999990143091845931021814636);
        assertEq(oracleRelayer.redemptionPrice(), 31622776601684);

        hevm.warp(now + 6307200 / 2);

        assertEq(oracleRelayer.redemptionRate(), 999990143091845931021814636);
        assertEq(oracleRelayer.redemptionPrice(), 1);
    }
    function test_proportional_warp_positive_below_negative_hundred_percent_ray_non_divisible() public {
        validator.modifyParameters("nb", uint(0.995E18));
        validator.modifyParameters("sg", uint(10E18));

        hevm.warp(now + validator.ps() * 2);
        orcl.updateTokenPrice(1.52E18);

        (uint newRate, int pTerm, uint rateTimeline) = validator.getNextRedemptionRate(1.52E18, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(newRate, 1);
        assertEq(pTerm, -0.52E27);
        assertEq(rateTimeline, 6064615);

        rateSetter.updateRate(999989748816890551879216604, address(this)); // approx -99.99999999999999999999 over 70.192303241 days

        hevm.warp(now + uint(6064614 / 2));

        assertEq(oracleRelayer.redemptionRate(), 999989748816890551879216604);
        assertEq(oracleRelayer.redemptionPrice(), 31622938688367);

        hevm.warp(now + uint(6064614 / 2));

        assertEq(oracleRelayer.redemptionRate(), 999989748816890551879216604);
        assertEq(oracleRelayer.redemptionPrice(), 1);
    }
    function test_proportional_warp_negative_hundred() public {
        validator.modifyParameters("nb", uint(0.995E18));

        hevm.warp(now + validator.ps() * 2);
        orcl.updateTokenPrice(2E18);

        (uint newRate, int pTerm, uint rateTimeline) = validator.getNextRedemptionRate(2E18, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(newRate, 1);
        assertEq(pTerm, -1E27);
        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(999998028610596449166604443, address(this)); // approx -99.99999999999999999999 over 365 days

        hevm.warp(now + defaultGlobalTimeline / 2);

        assertEq(oracleRelayer.redemptionRate(), 999998028610596449166604443);
        assertEq(oracleRelayer.redemptionPrice(), 31622776601684);

        hevm.warp(now + defaultGlobalTimeline / 2);

        assertEq(oracleRelayer.redemptionRate(), 999998028610596449166604443);
        assertEq(oracleRelayer.redemptionPrice(), 1);
    }
    function test_proportional_warp_twice_positive_deviation() public {
        validator.modifyParameters("nb", uint(0.995E18));

        hevm.warp(now + validator.ps() * 2);
        orcl.updateTokenPrice(1.05E18);

        (uint newRate, int pTerm, uint rateTimeline) = validator.getNextRedemptionRate(1.05E18, TWENTY_SEVEN_DECIMAL_NUMBER);
        assertEq(newRate, 0.95E27);
        assertEq(pTerm, -0.05E27);
        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(999999998373500306131523668, address(this)); // -5% global rate

        hevm.warp(now + validator.ps() * 2);

        (newRate, pTerm, rateTimeline) = validator.getNextRedemptionRate(1.05E18, oracleRelayer.redemptionPrice());
        assertEq(newRate, 949988289270765748110637924);
        assertEq(pTerm, -50011710729234251889362076);
        assertEq(rateTimeline, defaultGlobalTimeline);

        rateSetter.updateRate(999999998373500306131523668, address(this)); // -5% global rate
    }
}
