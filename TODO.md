# HBM4 Model - Remaining Implementation Gaps

This document tracks the known gaps between the current HBM4 simulation model and the official JESD270-4 specification.

## 1. Reliability, Availability, and Serviceability (RAS)
- [x] Command/Address Parity Checking (`AERR` pin)
- [x] Data ECC & Parity Checking (`DERR` pin)
- [x] Error Logging in Mode Registers (Syndrome recording in MR18, failing bank/row capture in MR19)

## 2. Calibration & Initialization
- [x] ZQ Calibration (`CMD_ZQ` Start/Latch with ZQCS and ZQCL modes)
- [x] ZQ Calibration Timing Checks (`tZQCS`, `tZQCL`)

## 3. Environmental Sensing
- [x] Catastrophic Temperature Trip Pin (`CATTRIP`)
- [x] Simulated Temperature Mechanism (backdoor `simulated_temp` variable)
- [x] Dynamic Temperature Readout in Mode Register 4 (MR4) via MRR

## 4. Data Path Features
- [x] Data Masking (DM) functionality on DBI pins (MR0 OP[3] enables DM mode)

## 5. Nuanced Timing Constraints
- [x] Power-Down Exit Time (`tXP`) enforcement
- [x] Per-Bank Refresh rolling window restrictions (`tREFW` tracking and warnings)

## 6. Previously Undocumented Gaps (Now Fixed)
- [x] MRR (Mode Register Read) readback path in model
- [x] Low-power state machine (PDE/PDX/SRE/SRX command handlers with proper state transitions)
