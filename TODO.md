# HBM4 Model - Remaining Implementation Gaps

This document tracks the known gaps between the current HBM4 simulation model and the official JESD270-4 specification.

## 1. Reliability, Availability, and Serviceability (RAS)
- [x] Command/Address Parity Checking (`AERR` pin)
- [x] Data ECC & Parity Checking (`DERR` pin)
- [ ] Error Logging in Mode Registers (Syndrome recording, failing bank/row capture)

## 2. Calibration & Initialization
- [ ] ZQ Calibration (`CMD_ZQ` Start/Latch)
- [ ] ZQ Calibration Timing Checks (`tZQCS`, `tZQCL`)

## 3. Environmental Sensing
- [ ] Catastrophic Temperature Trip Pin (`CATTRIP`)
- [ ] Simulated Temperature Mechanism
- [ ] Dynamic Temperature Readout in Mode Register 4 (MR4)

## 4. Data Path Features
- [ ] Data Masking (DM) functionality on DBI pins (Requires MR configuration)

## 5. Nuanced Timing Constraints
- [ ] Power-Down Exit Time (`tXP`) enforcement
- [ ] Per-Bank Refresh rolling window restrictions
