pragma solidity ^0.6.7;

import "ds-test/test.sol";

import "./GebRrfmValidators.sol";

contract GebRrfmValidatorsTest is DSTest {
    GebRrfmValidators validators;

    function setUp() public {
        validators = new GebRrfmValidators();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
