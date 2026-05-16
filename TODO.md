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
- [ ] **tRCDRD / tRCDWR** — Separate ACT-to-Read vs ACT-to-Write delays (§6.3.1). Model uses a single `tRCD` for both.
- [ ] **tRTPL / tRTPS** — Bank-group-dependent read-to-precharge timing. Model uses a single `tRTP`.
- [ ] **tCPDED** — Command-to-power-down entry delay (§Power-Down). Not enforced.
- [ ] **tCKPDE / tCKPDX** — Clock valid window before PDE / after PDX (§7828–7830). Not enforced.
- [ ] **tWRPDE / tWRAPDE** — Write-to-power-down entry delay (§Power-Down). Not enforced.
- [ ] **tDRFM / tDRFM2PRE** — DRFM-related timings (Table 41). N/A until DRFM is implemented.
- [ ] **tRREFD** — Refresh-to-refresh delay between consecutive REF commands (§6.3.2). Not tracked.
- [ ] **tXSMRS / tXSMRSF** — Self-refresh exit to MRS timing (§Self-Refresh). Not enforced.

### 🟡 Medium Priority — Missing Mode Register Behaviors
- [ ] **MR7 OP[0]** — Loopback / DWORD MISR test mode (Table 17/18). Not modeled.
- [ ] **MR8 OP[7:6]** — Bounded Refresh Configuration (BRC) (Table 41). Not modeled.
- [ ] **MR8 OP[5:4]** — RFM level / adaptive RFM configuration (Table 40). Not modeled.
- [ ] **MR9 OP[0]** — Metadata / ECC signaling enable (§8.x). Not modeled.
- [ ] **MR10** — DCA (Duty Cycle Adjuster) control (Table 74). Not modeled.
- [ ] **MR6 OP[7:6]** — DCM (Duty Cycle Monitor) control. Not modeled.

### 🟡 Medium Priority — Missing Protocol / Data Path
- [ ] **PC1 timing checks** — PC1 write handler (line ~920) has no tRCD/tRFC/tMOD/tCCD/tWTR/tRTW checks; PC1 read handler (line ~989) similarly missing. Asymmetric with PC0. **Bug.**
- [ ] **Clock frequency change sequence** (§6.1). Not implemented.
- [ ] **On-die ECC engine** — Only backdoor DERR injection exists. No encode/decode/correct, no ECC test mode, no ECC vector input mode (§8.x, lines 3157–3240).
- [ ] **Interconnect redundancy remapping** — Address remapping tables (§10–§13, Tables 48–54). Not modeled.

### 🟢 Low Priority — Cosmetic / Edge Cases
- [ ] **CNOP / RNOP** — Spec defines explicit no-op command encodings; model treats 4'b0000 as generic NOP.
- [ ] **Rx Offset Calibration training** — Analog-level; less relevant for behavioral model.
- [ ] **Lane repair via IEEE 1500** — Only basic WIR/WBR/WBY implemented; no repair/remap flows.
- [ ] **`test_concurrent_traffic`** — Exists in code but not listed in Makefile test targets.
