# GEB Redemption Rate Feedback Mechanism Calculators

This repository hosts calculators that can compute redemption rates for a GEB deployment.

The repository hosts the following core calculator implementations:

- **PIRawPerSecondCalculator**: proportional integral calculator using the raw **abs(mark - index)** deviation to compute a rate
- **BasicPIRawPerSecondCalculator**: a simpler version of [PIRawPerSecondCalculator](https://github.com/reflexer-labs/geb-rrfm-calculators/blob/master/src/calculator/PIRawPerSecondCalculator.sol) with less restrictions on how the redemption rate is calculated
