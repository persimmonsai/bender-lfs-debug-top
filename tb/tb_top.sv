`ifndef TB_TOP_SV
`define TB_TOP_SV

import hbm4_pkg::*;

module tb_top;

  // Clock and Reset
  logic CK_t;
  logic CK_c;
  logic WCK_t;
  logic WCK_c;
  logic RESET_n;

  // Reset Generation and Clock Enable
  logic clock_en = 0;
  
  initial begin
    RESET_n = 0;
    CK_t = 0;
    CK_c = 1;
    WCK_t = 1;
    WCK_c = 0;
    
    // Hold reset low for at least tPW_RESET (1000ns)
    #1050ns;
    
    // Deassert reset
    RESET_n = 1;
    
    // Wait some time before starting clocks
    #10ns;
    clock_en = 1;
  end

  // Clock Generation (e.g., 1GHz -> 1ns period)
  always begin
    if (clock_en) begin
      #0.5ns;
      CK_t = ~CK_t;
      CK_c = ~CK_c;
    end else begin
      #0.5ns;
    end
  end

  // WCK Generation (2GHz -> 0.5ns period)
  always begin
    if (clock_en) begin
      #0.25ns;
      WCK_t = ~WCK_t;
      WCK_c = ~WCK_c;
    end else begin
      #0.25ns;
    end
  end

  // Array of interfaces for all 32 channels
  hbm4_if channel_if [NUM_CHANNELS] (
    .CK_t(CK_t),
    .CK_c(CK_c),
    .WCK_t(WCK_t),
    .WCK_c(WCK_c),
    .RESET_n(RESET_n)
  );

  // Instantiate the 32-channel HBM4 stack
  hbm4_stack u_hbm4_stack (
    .channel_if(channel_if)
  );

  // Instantiate BFM for each channel
  hbm4_bfm u_hbm4_bfm [NUM_CHANNELS] (
    .vif(channel_if)
  );

  // Generate block for per-channel initialization
  generate
    genvar i;
    for (i = 0; i < NUM_CHANNELS; i++) begin : gen_init
      initial begin
        // Wait for reset to complete
        @(posedge channel_if[i].RESET_n);
        u_hbm4_bfm[i].init();
      end

      hbm4_trace_decoder #(
        .CHANNEL_ID(i)
      ) u_trace_decoder (
        .vif(channel_if[i])
      );
    end
  endgenerate

  // ------------------------------------------------------------------------
  // Test Tasks
  // ------------------------------------------------------------------------

  task test_mrs_config();
    begin
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: MRS Configuration", $time);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      // MRS is now automatically configured by the BFM init() task for all 32 channels.
      $display("[%0t] TB_TOP: Skipping manual MRS configuration as BFM auto-configures.", $time);
      #0;
    end
  endtask

  task test_basic_rw_bursts();
    begin
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: Basic Read/Write Bursts", $time);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      $display("[%0t] TB_TOP: Issuing ACTIVATE to PC0 and PC1 Bank 0 Row 0x100", $time);
      fork
        u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100);
        u_hbm4_bfm[31].activate(2'b00, 4'b0000, 15'h0100);
      join
      
      #(tRCD + 10ns);
      
      $display("[%0t] TB_TOP: Issuing WRITE to PC0 and PC1 Bank 0 Col 0x10", $time);
      fork
        u_hbm4_bfm[0].write_pc0(2'b00, 4'b0000, 6'h10, 256'hA5A5A5A5_5A5A5A5A_11223344_FFEEDDCC_00112233_44556677_8899AABB_CCDDEEFF);
        u_hbm4_bfm[31].write_pc1(2'b00, 4'b0000, 6'h10, 256'h01234567_89ABCDEF_FEDCBA98_76543210_01234567_89ABCDEF_FEDCBA98_76543210);
      join
      
      #(tWL + tCL + tWR + 20ns);
      
      $display("[%0t] TB_TOP: Issuing READ to PC0 and PC1 Bank 0 Col 0x10", $time);
      fork
        u_hbm4_bfm[0].read_pc0(2'b00, 4'b0000, 6'h10);
        u_hbm4_bfm[31].read_pc1(2'b00, 4'b0000, 6'h10);
      join
      
      #(tCL + 10ns); // Wait for read
    end
  endtask

    task test_parity_error();
    begin
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: Command Parity Error (AERR)", $time);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      u_hbm4_bfm[0].precharge_all();
      #(tRP);
      
      $display("[%0t] TB_TOP: Injecting Parity Error on next AWORD", $time);
      u_hbm4_bfm[0].inject_parity_error(1);
      
      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100);
      
      #(4ns);
      if (channel_if[0].ctrl.AERR === 1'b1) begin
         $display("[%0t] TB_TOP: PASS - AERR successfully asserted", $time);
      end else begin
         $error("[%0t] TB_TOP: FAIL - AERR did not assert", $time);
      end
      
      #(10ns);
      
      $display("[%0t] TB_TOP: Issuing valid ACTIVATE to Bank 0", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100);
      #(tRAS + 1ns);
      
      u_hbm4_bfm[0].precharge_all();
      #(tRP);
    end
  endtask

  task test_timing_faw_rrd();
    begin
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: tFAW, tRRD_L, tRRD_S Restrictions", $time);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      u_hbm4_bfm[0].precharge_all();
      #(tRP);
      
      $display("[%0t] TB_TOP: Testing tRRD_S (Diff BG)", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100);
      #(tRRD_S - 1ns);
      $display("[%0t] TB_TOP: Expecting tRRD_S violation...", $time);
      u_hbm4_bfm[0].activate(2'b01, 4'b0001, 15'h0200);
      
      u_hbm4_bfm[0].precharge_all();
      #(tRP);
      
      $display("[%0t] TB_TOP: Testing tRRD_L (Same BG)", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100);
      #(tRRD_S);
      $display("[%0t] TB_TOP: Expecting tRRD_L violation...", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0001, 15'h0200);

      u_hbm4_bfm[0].precharge_all();
      #(tRP);
      
      $display("[%0t] TB_TOP: Testing tFAW (Four Activate Window)", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100);
      #(tRRD_S);
      u_hbm4_bfm[0].activate(2'b01, 4'b0001, 15'h0200);
      #(tRRD_S);
      u_hbm4_bfm[0].activate(2'b10, 4'b0010, 15'h0300);
      #(tRRD_S);
      u_hbm4_bfm[0].activate(2'b11, 4'b0011, 15'h0400);
      
      #(tRRD_S - 1ns); 
      $display("[%0t] TB_TOP: Expecting tFAW violation...", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0100, 15'h0500);
      
      u_hbm4_bfm[0].precharge_all();
      #(tRP);
    end
  endtask


  task test_timing_ccd();
    begin
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: tCCD_L and tCCD_S Timing Restrictions", $time);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      $display("[%0t] TB_TOP: Issuing ACTIVATE to Bank 1 and Bank 2", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0001, 15'h0200); // Bank 1
      #(tRRD_S);
      u_hbm4_bfm[0].activate(2'b01, 4'b0010, 15'h0300); // Bank 2 (Diff BG)
      
      #(tRCD);
      
      $display("[%0t] TB_TOP: Two READs to same BG (requires tCCD_L)", $time);
      u_hbm4_bfm[0].read_pc0(2'b00, 4'b0001, 6'h00);
      #(tCCD_L);
      u_hbm4_bfm[0].read_pc0(2'b00, 4'b0001, 6'h08);
      
      #(tCL + 10ns);
      
      $display("[%0t] TB_TOP: Two READs to diff BG (requires tCCD_S)", $time);
      u_hbm4_bfm[0].read_pc0(2'b00, 4'b0001, 6'h10);
      #(tCCD_S);
      u_hbm4_bfm[0].read_pc0(2'b01, 4'b0010, 6'h00);
      
      #(tCL + 10ns);
    end
  endtask

  task test_timing_rtp();
    begin
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: tRTP (Read to Precharge) Timing", $time);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      u_hbm4_bfm[0].read_pc0(2'b00, 4'b0001, 6'h20);
      
      $display("[%0t] TB_TOP: Waiting tRTP before Precharge", $time);
      #(tRTP);
      u_hbm4_bfm[0].precharge(2'b00, 4'b0001);
      
      #(tRP);
    end
  endtask

  task test_timing_wtr();
    begin
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: tWTR_L/S (Write-to-Read) Timing", $time);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      // Use Bank 0 BA 0 (Already precharged but let's re-activate if needed, wait, it was precharged in previous test?
      // Let's just precharge all to be safe before starting)
      u_hbm4_bfm[0].precharge_all();
      #(tRP);

      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100); // BG0, BA0
      #(tRRD_L);
      u_hbm4_bfm[0].activate(2'b00, 4'b0001, 15'h0100); // BG0, BA1 (Same BG)
      #(tRCD);
      
      u_hbm4_bfm[0].write_pc0(2'b00, 4'b0000, 6'h10, 256'h0);
      // Write finishes after WL + burst
      #(10ns); 
      
      // Wait slightly less than tWTR_L
      #(tWTR_L - 1ns);
      $display("[%0t] TB_TOP: Expecting tWTR_L violation...", $time);
      u_hbm4_bfm[0].read_pc0(2'b00, 4'b0001, 6'h20); // Same BG
      
      #(tCL + 10ns);
    end
  endtask

  task test_refresh_mechanics();
    begin
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: All-Bank Refresh", $time);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      // Close all banks first
      u_hbm4_bfm[0].precharge_all();
      
      #(tRP);
      
      $display("[%0t] TB_TOP: Issuing All-Bank REF Command", $time);
      u_hbm4_bfm[0].refresh();
      
      $display("[%0t] TB_TOP: Waiting tRFC (260ns)", $time);
      #(tRFC);
      
      $display("[%0t] TB_TOP: Refresh Complete. Issuing subsequent ACT.", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h1000);
      #(tRCD);
    end
  endtask

  task test_random_traffic();
    begin
      int num_transactions;
      logic [1:0] bg;
      logic [3:0] ba;
      logic [5:0] col;
      logic [14:0] row;
      logic is_write;
      logic [255:0] data;
      int channel;
      
      num_transactions = 20;
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: Random Pseudo-Traffic Generation (%0d transactions)", $time, num_transactions);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      u_hbm4_bfm[0].precharge_all();
      #(tRP);
      
      for (int i=0; i<num_transactions; i++) begin
        channel = $urandom_range(0, 31);
        bg = $urandom_range(0, 3);
        ba = $urandom_range(0, 15);
        col = $urandom_range(0, 63);
        row = $urandom_range(0, 32767);
        is_write = $urandom_range(0, 1);
        
        data[63:0]   = {$urandom(), $urandom()};
        data[127:64] = {$urandom(), $urandom()};
        data[191:128]= {$urandom(), $urandom()};
        data[255:192]= {$urandom(), $urandom()};
        
        u_hbm4_bfm[0].activate(bg, ba, row);
        #(tRCD);
        
        if (is_write) begin
          if ($urandom_range(0, 1))
            u_hbm4_bfm[0].write_pc0(bg, ba, col, data);
          else
            u_hbm4_bfm[0].write_pc1(bg, ba, col, data);
          #(tWL + tCL + tWR + 20ns);
        end else begin
          if ($urandom_range(0, 1))
            u_hbm4_bfm[0].read_pc0(bg, ba, col);
          else
            u_hbm4_bfm[0].read_pc1(bg, ba, col);
          #(tCL + 20ns);
        end
        
        u_hbm4_bfm[0].precharge(bg, ba);
        #(tRP);
      end
    end
  endtask

  task test_concurrent_traffic();
    begin
      int num_transactions;
      logic [1:0] bg_pc0, bg_pc1;
      logic [3:0] ba_pc0, ba_pc1;
      logic [5:0] col_pc0, col_pc1;
      logic is_write_pc0, is_write_pc1;
      logic last_is_write_pc0, last_is_write_pc1;
      logic [255:0] data_pc0, data_pc1;
      
      int written_pc0[$];
      int written_pc1[$];
      
      num_transactions = 500;
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: Concurrent Pseudo-Traffic Generation (%0d transactions)", $time, num_transactions);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      u_hbm4_bfm[0].precharge_all();
      #(tRP);
      
      $display("[%0t] TB_TOP: Pre-activating independent banks...", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100); #(tRCD);
      u_hbm4_bfm[0].activate(2'b01, 4'b0001, 15'h0200); #(tRCD);
      u_hbm4_bfm[0].activate(2'b10, 4'b0010, 15'h0300); #(tRCD);
      u_hbm4_bfm[0].activate(2'b11, 4'b0011, 15'h0400); #(tRCD);
      
      $display("[%0t] TB_TOP: Starting highly concurrent command injection...", $time);
      for (int i=0; i<num_transactions; i++) begin
        int b_idx_pc0, b_idx_pc1;
        int r_idx_pc0, r_idx_pc1;
        logic [11:0] tmp_addr;
        
        is_write_pc0 = $urandom_range(0, 1);
        is_write_pc1 = $urandom_range(0, 1);
        
        if (written_pc0.size() == 0) is_write_pc0 = 1;
        if (written_pc1.size() == 0) is_write_pc1 = 1;
        
        if (is_write_pc0) begin
           b_idx_pc0 = $urandom_range(0, 3);
           bg_pc0 = b_idx_pc0[1:0]; ba_pc0 = b_idx_pc0[1:0];
           col_pc0 = $urandom_range(0, 63);
           written_pc0.push_back({20'd0, bg_pc0, ba_pc0, col_pc0});
        end else begin
           r_idx_pc0 = $urandom_range(0, written_pc0.size()-1);
           tmp_addr = written_pc0[r_idx_pc0][11:0];
           {bg_pc0, ba_pc0, col_pc0} = tmp_addr;
        end
        
        if (is_write_pc1) begin
           b_idx_pc1 = $urandom_range(0, 3);
           bg_pc1 = b_idx_pc1[1:0]; ba_pc1 = b_idx_pc1[1:0];
           col_pc1 = $urandom_range(0, 63);
           written_pc1.push_back({20'd0, bg_pc1, ba_pc1, col_pc1});
        end else begin
           r_idx_pc1 = $urandom_range(0, written_pc1.size()-1);
           tmp_addr = written_pc1[r_idx_pc1][11:0];
           {bg_pc1, ba_pc1, col_pc1} = tmp_addr;
        end
        
        data_pc0 = {$urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom()};
        data_pc1 = {$urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom()};
        
        // Calculate dynamic turnaround delay BEFORE issuing current command
        if (i > 0) begin
          time delay_pc0, delay_pc1, required_delay;
          delay_pc0 = tCCD_L;
          delay_pc1 = tCCD_L;
          
          if (last_is_write_pc0 && !is_write_pc0) delay_pc0 = tWTR_L;
          else if (!last_is_write_pc0 && is_write_pc0) delay_pc0 = tRTW;
          
          if (last_is_write_pc1 && !is_write_pc1) delay_pc1 = tWTR_L;
          else if (!last_is_write_pc1 && is_write_pc1) delay_pc1 = tRTW;
          
          required_delay = (delay_pc0 > delay_pc1) ? delay_pc0 : delay_pc1;
          #(required_delay);
        end
        
        fork
          begin
            if (is_write_pc0) u_hbm4_bfm[0].write_pc0(bg_pc0, ba_pc0, col_pc0, data_pc0);
            else              u_hbm4_bfm[0].read_pc0(bg_pc0, ba_pc0, col_pc0);
          end
          begin
            if (is_write_pc1) u_hbm4_bfm[0].write_pc1(bg_pc1, ba_pc1, col_pc1, data_pc1);
            else              u_hbm4_bfm[0].read_pc1(bg_pc1, ba_pc1, col_pc1);
          end
        join
        
        last_is_write_pc0 = is_write_pc0;
        last_is_write_pc1 = is_write_pc1;
      end
      
      #(tWL + tCL + tWR + 20ns);
      
      $display("[%0t] TB_TOP: Precharging all active banks...", $time);
      u_hbm4_bfm[0].precharge(2'b00, 4'b0000); #(tRP);
      u_hbm4_bfm[0].precharge(2'b01, 4'b0001); #(tRP);
      u_hbm4_bfm[0].precharge(2'b10, 4'b0010); #(tRP);
      u_hbm4_bfm[0].precharge(2'b11, 4'b0011); #(tRP);
    end
  endtask

  task test_prea_refpb();
    begin
      $display("\n[%0t] TB_TOP: ========================================", $time);
      u_hbm4_bfm[0].precharge_all();
      #(tRP);
      $display("[%0t] TB_TOP: TEST: Precharge All (PREA) and Per-Bank Refresh (REFpb)", $time);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      $display("[%0t] TB_TOP: Activating Bank 0 and Bank 1", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100);
      #(tRRD_L);
      u_hbm4_bfm[0].activate(2'b00, 4'b0001, 15'h0200);
      #(tRCD + tRAS); // Wait until banks are active and meet tRAS
      
      $display("[%0t] TB_TOP: Issuing Precharge All (PREA)", $time);
      u_hbm4_bfm[0].precharge_all();
      #(tRP);
      
      $display("[%0t] TB_TOP: Issuing Per-Bank Refresh to Bank 0", $time);
      u_hbm4_bfm[0].refresh_pb(2'b00, 4'b0000);
      #(tRFCpb);
      
      $display("[%0t] TB_TOP: Activating Bank 0 again", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100);
      #(tRAS + 1ns);
      u_hbm4_bfm[0].precharge(2'b00, 4'b0000);
      #(tRP);
    end
  endtask



  task test_ieee1500();
    begin
      logic [31:0] read_data;
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: IEEE 1500 Test Port", $time);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      // Write Instruction (e.g. 0x01 for Boundary Register)
      u_hbm4_bfm[0].write_ieee1500_instruction(8'h01);
      
      // Write and Read Data
      u_hbm4_bfm[0].write_ieee1500_data(32'hDEADBEEF, read_data);
      $display("[%0t] TB_TOP: IEEE 1500 Wrote DEADBEEF, Initial Read: %08h", $time, read_data);
      
      // Read Data again to see the previously written data
      u_hbm4_bfm[0].write_ieee1500_data(32'hCAFEBABE, read_data);
      $display("[%0t] TB_TOP: IEEE 1500 Read back: %08h", $time, read_data);
      
      if (read_data == 32'hDEADBEEF) begin
         $display("[%0t] TB_TOP: PASS - IEEE 1500 WBR successfully shifted through.", $time);
      end else begin
         $error("[%0t] TB_TOP: FAIL - IEEE 1500 WBR data mismatch.", $time);
      end
    end
  endtask

  task test_low_power_states();
    begin
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: Low Power States (PD and SRE)", $time);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      u_hbm4_bfm[0].precharge_all();
      #(tRP);
      
      $display("[%0t] TB_TOP: Entering Power-Down", $time);
      u_hbm4_bfm[0].enter_power_down();
      #(tPD + 5ns);
      $display("[%0t] TB_TOP: Exiting Power-Down", $time);
      u_hbm4_bfm[0].exit_power_down();
      #(10ns);
      
      $display("[%0t] TB_TOP: Entering Self-Refresh", $time);
      u_hbm4_bfm[0].enter_self_refresh();
      #(20ns);
      
      $display("[%0t] TB_TOP: Expecting Command Error (ACT while in SRE)", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100);
      
      $display("[%0t] TB_TOP: Exiting Self-Refresh", $time);
      u_hbm4_bfm[0].exit_self_refresh();
      
      // Attempt immediate ACT (tXS violation)
      #(10ns);
      $display("[%0t] TB_TOP: Expecting tXS Timing Error", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100);
      
      #(tXS); // Wait full tXS
      $display("[%0t] TB_TOP: Issuing valid ACT after tXS", $time);
      u_hbm4_bfm[0].activate(2'b00, 4'b0000, 15'h0100);
      #(tRCD);
      
      u_hbm4_bfm[0].precharge_all();
      #(tRP);
    end
  endtask

  task test_mrr();
    begin
      $display("\n[%0t] TB_TOP: ========================================", $time);
      $display("[%0t] TB_TOP: TEST: Mode Register Read (MRR)", $time);
      $display("[%0t] TB_TOP: ========================================\n", $time);
      
      $display("[%0t] TB_TOP: Issuing MRR for MR0 (should be 8'h04)", $time);
      u_hbm4_bfm[0].mrr_pc0(5'h00);
      u_hbm4_bfm[0].mrr_pc1(5'h00);
      #(tCL + 20ns);
      
      $display("[%0t] TB_TOP: Issuing MRR for MR1 (should be 8'h06)", $time);
      u_hbm4_bfm[0].mrr_pc0(5'h01);
      u_hbm4_bfm[0].mrr_pc1(5'h01);
      #(tCL + 20ns);
    end
  endtask

  // ------------------------------------------------------------------------
  // Timeout Block
  // ------------------------------------------------------------------------
  initial begin
    #(50ms);
    $display("[%0t] TB_TOP: FATAL ERROR - Simulation Timeout!", $time);
    $finish(2);
  end

  // ------------------------------------------------------------------------
  // Timeout Block
  // ------------------------------------------------------------------------
  initial begin
    #(10ms);
    $display("[%0t] TB_TOP: FATAL ERROR - Simulation Timeout!", $time);
    $finish(2);
  end

  // ------------------------------------------------------------------------
  // Master Test Sequence
  // ------------------------------------------------------------------------
  initial begin
    string test_name;
    
    $display("\n[%0t] TB_TOP: Simulation Started", $time);
    
    // Dump waves if explicitly enabled
    if ($test$plusargs("DUMP_WAVES")) begin
      $display("[%0t] TB_TOP: Waveform dumping enabled (Full Access)", $time);
      $shm_open("waves.shm");
      $shm_probe("AMMC"); // All, memories, MDA, Cells
    end
    
    // Wait for initializations to finish (1050ns reset + 10ns PDE + 200ns tINIT5 = ~1260ns minimum)
    #(2000ns);
    
    if ($value$plusargs("TEST=%s", test_name)) begin
      $display("[%0t] TB_TOP: Running explicit test: %s", $time, test_name);
      if (test_name == "test_mrs_config") test_mrs_config();
      else if (test_name == "test_mrr") test_mrr();
      else if (test_name == "test_basic_rw_bursts") test_basic_rw_bursts();
      else if (test_name == "test_parity_error") test_parity_error();
      else if (test_name == "test_timing_ccd") test_timing_ccd();
      else if (test_name == "test_timing_rtp") test_timing_rtp();
      else if (test_name == "test_timing_wtr") test_timing_wtr();
      else if (test_name == "test_random_traffic") test_random_traffic();
      else if (test_name == "test_concurrent_traffic") test_concurrent_traffic();
      else if (test_name == "test_refresh_mechanics") test_refresh_mechanics();
      else if (test_name == "test_prea_refpb") test_prea_refpb();
      else if (test_name == "test_low_power_states") test_low_power_states();
      else if (test_name == "test_ieee1500") test_ieee1500();
      else begin
        $display("UNKNOWN TEST: %s", test_name);
      end
    end else begin
      $display("[%0t] TB_TOP: Running full regression suite", $time);
      test_ieee1500();
      test_mrs_config();
      test_mrr();
      test_basic_rw_bursts();
      test_parity_error();
      test_low_power_states();
      test_prea_refpb();
      test_timing_faw_rrd();
      test_timing_ccd();
      test_timing_rtp();
      test_timing_wtr();
      test_random_traffic();
      test_refresh_mechanics();
    end
    
    $display("\n[%0t] TB_TOP: All Tests Completed Successfully", $time);
    $finish;
  end

endmodule

`endif
