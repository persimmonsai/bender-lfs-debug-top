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

---

## Spec Audit Findings (JESD270-4)

### 🔴 High Priority — Missing Commands
- [x] **RDA / WRA** — Read/Write with Auto-Precharge (§6.3.3, Table 34). Uses C_ADDR[5] (AP_BIT) to signal auto-precharge. Bank auto-closes after tWR (write) or tRTP (read).
- [x] **RFMab / RFMpb** — Refresh Management commands (Table 40, §6.3.4). CMD_RFM (4'b1111) with BA[3] selecting mode. RAA counter per bank with MR8 OP[5:4] threshold.
- [x] **DRFM** — Directed Refresh Management via ACT variant (Table 33). R_ADDR[4] (DRFM_BIT) on ACT signals directed refresh. Resets RAA counter without opening bank.

### 🟡 Medium Priority — Missing Timing Parameters
- [x] **tRCDRD / tRCDWR** — Separate ACT-to-Read (17ns) vs ACT-to-Write (15ns) delays. All handlers updated.
- [x] **tRTPL / tRTPS** — Bank-group-dependent read-to-precharge (tRTP_L=5ns, tRTP_S=4ns). PRE/PREA/AP use tRTP_L.
- [x] **tCPDED** — Command-to-power-down entry delay (4ns). Enforced on PDE.
- [ ] **tCKPDE / tCKPDX** — Clock valid window before PDE / after PDX. Analog-level, not behaviorally modeled.
- [x] **tWRPDE** — Write-to-power-down entry delay (28ns). Enforced on PDE for both PCs.
- [x] **tDRFM** — DRFM cycle time (260ns). Enforced on consecutive DRFM to same bank.
- [x] **tRREFD** — Refresh-to-refresh delay (8ns). Enforced between consecutive REFpb commands.
- [x] **tXSMRS** — Self-refresh exit to MRS timing (210ns). Enforced on MRS after SRX.

### 🟡 Medium Priority — Missing Mode Register Behaviors
- [x] **MR7 OP[0]** — Loopback mode. Write data captured; reads return loopback data instead of memory.
- [x] **MR8 OP[5:4]** — RFM level / adaptive RFM threshold (32/48/64/80). Integrated with RAA counter warning.
- [ ] **MR8 OP[7:6]** — Bounded Refresh Configuration (BRC). Not yet modeled.
- [x] **MR9 OP[0]** — ECC metadata signaling enable. DERR events include syndrome/bank metadata when set.
- [ ] **MR10** — DCA (Duty Cycle Adjuster) control. Analog feature, not behaviorally relevant.
- [ ] **MR6 OP[7:6]** — DCM (Duty Cycle Monitor) control. Analog feature, not behaviorally relevant.

### 🟡 Medium Priority — Missing Protocol / Data Path
- [x] **PC1 timing checks** — Added tRCD, tRFC, tMOD, tCCD_L/S, tWTR_L/S, tRTW checks to PC1 WR/RD. **Bug fixed.**
- [ ] **Clock frequency change sequence** (§6.1). Protocol-level, not yet implemented.
- [ ] **On-die ECC engine** — Only backdoor DERR injection. Full encode/decode/correct not modeled.
- [ ] **Interconnect redundancy remapping** — Address remapping tables not modeled.

### 🟢 Low Priority — Cosmetic / Edge Cases
- [ ] **CNOP / RNOP** — Spec defines explicit no-op command encodings; model treats 4'b0000 as generic NOP.
- [ ] **Rx Offset Calibration training** — Analog-level; less relevant for behavioral model.
- [ ] **Lane repair via IEEE 1500** — Only basic WIR/WBR/WBY implemented; no repair/remap flows.
- [ ] **`test_concurrent_traffic`** — Exists in code but not listed in Makefile test targets.
