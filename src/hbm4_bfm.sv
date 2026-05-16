`ifndef HBM4_BFM_SV
`define HBM4_BFM_SV

import hbm4_pkg::*;

module hbm4_bfm (
  hbm4_if.ctrl vif
);

  // Initialize signals
  initial begin
    vif.CKE = 0;
    vif.AWORD = '0;
    vif.DWORD_PC0 = '0;
    vif.DWORD_PC1 = '0;
    vif.WDQS_t_pc0 = 0; vif.WDQS_c_pc0 = 1;
    vif.WDQS_t_pc1 = 0; vif.WDQS_c_pc1 = 1;
  end

  // BFM Tracking of Latencies
  int wl_pc0 = 8;
  int rl_pc0 = 10;
  int wl_pc1 = 8;
  int rl_pc1 = 10;
  

  // DQ and DBI Drivers
  logic [31:0] dq_pc0_drive = 'z;
  logic [7:0] mode_reg_pc0 [0:15];
  logic [7:0] mode_reg_pc1 [0:15];
  logic dq_pc0_en = 0;
  logic [3:0] dbi_pc0_drive = 'z;
  
  logic [31:0] dq_pc1_drive = 'z;
  logic pde_active_pc0 = 0;
  logic pde_active_pc1 = 0;




  // ------------------------------------------------------------------------'z;
  
  logic dq_pc1_en = 0;
  logic [3:0] dbi_pc1_drive = 'z;
  
  assign vif.DQ_PC0 = dq_pc0_en ? dq_pc0_drive : 'z;
  assign vif.DBI_PC0 = dq_pc0_en ? dbi_pc0_drive : 'z;
  
  assign vif.DQ_PC1 = dq_pc1_en ? dq_pc1_drive : 'z;
  assign vif.DBI_PC1 = dq_pc1_en ? dbi_pc1_drive : 'z;

  // AC DBI State Trackers for Writes
  logic [35:0] last_write_state_pc0 = '0; // {DBI[3:0], DQ[31:0]}
  logic [35:0] last_write_state_pc1 = '0;

  logic inject_aerr = 0;
  task inject_parity_error(input logic en);
    inject_aerr = en;
  endtask

  function automatic logic calc_parity_aword(aword_t a);
    begin
      return ^({a.R_ADDR, a.BA, a.BG, a.CMD});
    end
  endfunction
function automatic logic calc_parity_dword(dword_t d);
  begin
    if (d.CMD == CMD_MRR || d.CMD == CMD_MRS) return d.C;
    return ^({d.C_ADDR, d.BA, d.BG, d.CMD});
  end
endfunction

  // =====================================================================
  // IEEE 1500 Test Port Tasks
  // =====================================================================
  
  task write_ieee1500_instruction(input logic [7:0] instr);
    begin
      vif.SelectVR = 1;
      vif.CaptureWR = 0;
      vif.ShiftWR = 1;
      vif.UpdateWR = 0;
      
      for (int i = 0; i < 8; i++) begin
        vif.WSI = instr[i];
        #5ns vif.WRCK = 1;
        #5ns vif.WRCK = 0;
      end
      
      vif.ShiftWR = 0;
      vif.UpdateWR = 1;
      #5ns vif.WRCK = 1;
      #5ns vif.WRCK = 0;
      vif.UpdateWR = 0;
    end
  endtask
  
  task write_ieee1500_data(input logic [31:0] data, output logic [31:0] read_data);
    begin
      vif.SelectVR = 0;
      vif.CaptureWR = 1;
      vif.ShiftWR = 0;
      vif.UpdateWR = 0;
      #5ns vif.WRCK = 1;
      #5ns vif.WRCK = 0;
      vif.CaptureWR = 0;
      
      vif.ShiftWR = 1;
      for (int i = 0; i < 32; i++) begin
        vif.WSI = data[i];
        read_data[i] = vif.WSO;
        #5ns vif.WRCK = 1;
        #5ns vif.WRCK = 0;
      end
      
      vif.ShiftWR = 0;
      vif.UpdateWR = 1;
      #5ns vif.WRCK = 1;
      #5ns vif.WRCK = 0;
      vif.UpdateWR = 0;
    end
  endtask

  // Task for Power-up and Initialization
  task init();
    begin
      aword_t aword;
      dword_t dword;
      
      $display("[%0t] HBM4_BFM: Starting Initialization", $time);
      
      // Setup PDE state for when reset goes high
      aword = '0;
      aword.CMD = CMD_PDE;
      aword.R = calc_parity_aword(aword);
      vif.AWORD <= aword;
      
      dword = '0;
      dword.CMD = CMD_NOP;
      dword.C = calc_parity_dword(dword);
      vif.DWORD_PC0 <= dword;
      vif.DWORD_PC1 <= dword;

      // Initialize WDQS to static 0
      vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
      vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;

      wait (vif.RESET_n == 1);
      
      // Drive CKE high
      @(posedge vif.CK_t);
      vif.CKE <= 1;
      
      // Maintain PDE for a few cycles
      repeat(10) @(posedge vif.CK_t);
      
      // Exit PDE (Drive R[3:0] HIGH -> NOP)
      aword.CMD = CMD_NOP;
      aword.R = calc_parity_aword(aword);
      vif.AWORD <= aword;
      $display("[%0t] HBM4_BFM: Exited PDE. Waiting tINIT5 (200ns)", $time);
      
      // Wait tINIT5 before first MRS
      #(200ns);
      
      // Auto-configure all 20 Mode Registers (MR0-MR19) for simulation
      $display("[%0t] HBM4_BFM: Auto-configuring Mode Registers MR0-MR19...", $time);
      for (int i = 0; i < 20; i++) begin
        automatic logic [7:0] mr_data;
        case (i)
          0: mr_data = 8'h04; // MR0: TCSR Enabled (OP[2]=1), DBI Disabled
          1: mr_data = 8'h06; // MR1: WL=6 nCK (OP[4:0]=6)
          2: mr_data = 8'h0E; // MR2: RL=14 nCK (OP[7:0]=14)
          3: mr_data = 8'h10; // MR3: WR=16 nCK (OP[7:0]=16)
          4: mr_data = 8'h22; // MR4: RAS=34 nCK (OP[7:0]=34)
          5: mr_data = 8'h08; // MR5: RTP=8 nCK (OP[3:0]=8)
          default: mr_data = 8'h00; // Other MRs default to 0
        endcase
        mode_register_set_pc0(i[4:0], mr_data);
        mode_register_set_pc1(i[4:0], mr_data);
        #(10ns);
      end
      
      $display("[%0t] HBM4_BFM: Initialization Complete", $time);
    end
  endtask


  // Task to issue ACTIVATE command
  task activate(input logic [1:0] bg, input logic [3:0] ba, input logic [14:0] row);
    begin
      aword_t aword;
      aword.CMD = CMD_ACT;
      aword.BG = bg;
      aword.BA = ba;
      aword.R_ADDR = row; // Simplified
      aword.R = calc_parity_aword(aword) ^ inject_aerr; inject_aerr = 0;
      
      @(posedge vif.CK_t);
      vif.AWORD <= aword;
      
      @(posedge vif.CK_t);
      vif.AWORD <= '0; // NOP
    end
  endtask


  task enter_power_down();
    begin
      aword_t aword;
      aword.CMD = CMD_PDE;
      aword.BG = '0; aword.BA = '0; aword.R_ADDR = '0;
      aword.R = calc_parity_aword(aword) ^ inject_aerr; inject_aerr = 0;
      @(posedge vif.CK_t); vif.AWORD <= aword;
      @(posedge vif.CK_t); vif.AWORD <= '0;
    end
  endtask

  task exit_power_down();
    begin
      aword_t aword;
      aword.CMD = CMD_PDX;
      aword.BG = '0; aword.BA = '0; aword.R_ADDR = '0;
      aword.R = calc_parity_aword(aword) ^ inject_aerr; inject_aerr = 0;
      @(posedge vif.CK_t); vif.AWORD <= aword;
      @(posedge vif.CK_t); vif.AWORD <= '0;
    end
  endtask

  task enter_self_refresh();
    begin
      aword_t aword;
      aword.CMD = CMD_SRE;
      aword.BG = '0; aword.BA = '0; aword.R_ADDR = '0;
      aword.R = calc_parity_aword(aword) ^ inject_aerr; inject_aerr = 0;
      @(posedge vif.CK_t); vif.AWORD <= aword;
      @(posedge vif.CK_t); vif.AWORD <= '0;
    end
  endtask

  task exit_self_refresh();
    begin
      aword_t aword;
      aword.CMD = CMD_SRX;
      aword.BG = '0; aword.BA = '0; aword.R_ADDR = '0;
      aword.R = calc_parity_aword(aword) ^ inject_aerr; inject_aerr = 0;
      @(posedge vif.CK_t); vif.AWORD <= aword;
      @(posedge vif.CK_t); vif.AWORD <= '0;
    end
  endtask

  // Task to issue PRECHARGE command
  task precharge(input logic [1:0] bg, input logic [3:0] ba);
    begin
      aword_t aword;
      aword.CMD = CMD_PRE;
      aword.BG = bg;
      aword.BA = ba;
      aword.R_ADDR = '0;
      aword.R = calc_parity_aword(aword) ^ inject_aerr; inject_aerr = 0;
      
      @(posedge vif.CK_t);
      vif.AWORD <= aword;
      
      @(posedge vif.CK_t);
      vif.AWORD <= '0; // NOP
    end
  endtask

  // Task to issue PRECHARGE ALL command
  task precharge_all();
    begin
      aword_t aword;
      aword.CMD = CMD_PREA;
      aword.BG = '0;
      aword.BA = '0;
      aword.R_ADDR = '0;
      aword.R = calc_parity_aword(aword) ^ inject_aerr; inject_aerr = 0;
      
      @(posedge vif.CK_t);
      vif.AWORD <= aword;
      
      @(posedge vif.CK_t);
      vif.AWORD <= '0; // NOP
    end
  endtask

  // Task to issue REFpb command
  task refresh_pb(input logic [1:0] bg, input logic [3:0] ba);
    begin
      aword_t aword;
      aword.CMD = CMD_REFpb;
      aword.BG = bg;
      aword.BA = ba;
      aword.R_ADDR = '0;
      aword.R = calc_parity_aword(aword) ^ inject_aerr; inject_aerr = 0;
      
      @(posedge vif.CK_t);
      vif.AWORD <= aword;
      
      @(posedge vif.CK_t);
      vif.AWORD <= '0; // NOP
    end
  endtask

  // Task to write data to PC0
  task automatic write_pc0(input logic [1:0] bg, input logic [3:0] ba, input logic [5:0] col, input logic [255:0] data);
    begin
      dword_t dword;
      dword.CMD = CMD_WR;
    dword.BG = bg;
    dword.BA = ba;
    dword.C_ADDR = col;
    dword.C = calc_parity_dword(dword);
    
    @(posedge vif.CK_t);
    vif.DWORD_PC0 <= dword;
    
    fork
      begin
        @(posedge vif.CK_t); // Wait for command to be on the bus
        repeat(wl_pc0 - 1) @(posedge vif.CK_t);
        
        // Four-pulse Preamble (4 WCK cycles = 2 tCK)
        for (int p = 0; p < 4; p++) begin
          vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
          @(negedge vif.WCK_t);
          vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
          @(posedge vif.WCK_t);
        end
        begin : wdbi_processing_pc0
          logic [31:0] ui0_data;
          logic [31:0] ui1_data;
          logic [35:0] next_st;
          logic wdbi_en;
          
          wdbi_en = (mode_reg_pc0[0][1] == 1'b1);
          
          for (int beat = 0; beat < 4; beat++) begin
            ui0_data = data[(beat*2)*32 +: 32];
            ui1_data = data[(beat*2+1)*32 +: 32];
            
            vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
            dq_pc0_en = 1;
            
            next_st = process_dbi_word(ui0_data, last_write_state_pc0, wdbi_en);
            dq_pc0_drive = next_st[31:0];
            dbi_pc0_drive = next_st[35:32];
            last_write_state_pc0 = next_st;
            
            @(negedge vif.WCK_t);
            vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
            
            next_st = process_dbi_word(ui1_data, last_write_state_pc0, wdbi_en);
            dq_pc0_drive = next_st[31:0];
            dbi_pc0_drive = next_st[35:32];
            last_write_state_pc0 = next_st;
            
            @(posedge vif.WCK_t);
          end
        end
        dq_pc0_en = 0;
        
        // Two-pulse Postamble (2 WCK cycles = 1 tCK)
        for (int p = 0; p < 2; p++) begin
          vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
          @(negedge vif.WCK_t);
          vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
          @(posedge vif.WCK_t);
        end
        vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
      end
    join_none
    
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= '0; // NOP
    end
  endtask

  // Task to read data from PC0
  task automatic read_pc0(input logic [1:0] bg, input logic [3:0] ba, input logic [5:0] col);
    begin
      dword_t dword;
      dword.CMD = CMD_RD;
      dword.BG = bg;
      dword.BA = ba;
      dword.C_ADDR = col;
      dword.C = calc_parity_dword(dword);
      
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= dword;
      last_write_state_pc0 = '0;
      
      fork
        begin
          logic [255:0] read_data;
          @(posedge vif.CK_t); // Wait for command to be on the bus
          
          fork
            begin
              repeat(rl_pc0 - 2) @(posedge vif.CK_t);
              // Four-pulse Preamble (4 WCK cycles = 2 tCK)
              for (int beat = 0; beat < 4; beat++) begin
                vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
                @(posedge vif.WCK_t);
              end
              
              // Toggle for 4 WCK cycles duration (2 tCK)
              for (int beat = 0; beat < 4; beat++) begin
                vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
                @(posedge vif.WCK_t);
              end
              
              // Two-pulse Postamble (2 WCK cycles = 1 tCK)
              for (int p = 0; p < 2; p++) begin
                vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
                @(posedge vif.WCK_t);
              end
            end
          join_none

          // Skip the RDQS 2-pulse preamble (2 WCK cycles = 1 tCK of toggling)
          repeat(2) begin
            @(posedge vif.RDQS_t_pc0);
            @(negedge vif.RDQS_t_pc0);
          end
          
          // We no longer wait for RL using CK, we just wait for RDQS edges!
          for (int beat = 0; beat < 4; beat++) begin
            automatic logic [31:0] dq_sampled;
            automatic logic [3:0]  dbi_sampled;
            
            @(posedge vif.RDQS_t_pc0);
            dq_sampled = vif.DQ_PC0;
            dbi_sampled = vif.DBI_PC0;
            for (int b = 0; b < 4; b++) begin
              read_data[(beat*2)*32 + b*8 +: 8] = dbi_sampled[b] ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
            end
            
            @(negedge vif.RDQS_t_pc0);
            dq_sampled = vif.DQ_PC0;
            dbi_sampled = vif.DBI_PC0;
            for (int b = 0; b < 4; b++) begin
              read_data[(beat*2+1)*32 + b*8 +: 8] = dbi_sampled[b] ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
            end
          end
          $display("[%0t] HBM4_BFM: PC0 Burst Read Data = %0h", $time, read_data);
        end
      join_none
      
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= '0; // NOP
    end
  endtask

  // Task to write data to PC1
  task automatic write_pc1(input logic [1:0] bg, input logic [3:0] ba, input logic [5:0] col, input logic [255:0] data);
    begin
      dword_t dword;
      dword.CMD = CMD_WR;
      dword.BG = bg;
      dword.BA = ba;
      dword.C_ADDR = col;
      dword.C = calc_parity_dword(dword);
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= dword;
      
      fork
        begin
          @(posedge vif.CK_t); // Wait for command to be on the bus
          repeat(wl_pc1 - 1) @(posedge vif.CK_t);
          
          // Four-pulse Preamble (4 WCK cycles = 2 tCK)
          for (int p = 0; p < 4; p++) begin
            vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
            @(negedge vif.WCK_t);
            vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
            @(posedge vif.WCK_t);
          end
          begin : wdbi_processing_pc1
            logic [31:0] ui0_data;
            logic [31:0] ui1_data;
            logic [35:0] next_st;
            logic wdbi_en;
            
            wdbi_en = (mode_reg_pc1[0][1] == 1'b1);
            
            for (int beat = 0; beat < 4; beat++) begin
              ui0_data = data[(beat*2)*32 +: 32];
              ui1_data = data[(beat*2+1)*32 +: 32];
              
              vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
              dq_pc1_en = 1;
              
              next_st = hbm4_pkg::process_dbi_word(ui0_data, last_write_state_pc1, wdbi_en);
              dq_pc1_drive = next_st[31:0];
              dbi_pc1_drive = next_st[35:32];
              last_write_state_pc1 = next_st;
              
              @(negedge vif.WCK_t);
              vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
              
              next_st = hbm4_pkg::process_dbi_word(ui1_data, last_write_state_pc1, wdbi_en);
              dq_pc1_drive = next_st[31:0];
              dbi_pc1_drive = next_st[35:32];
              last_write_state_pc1 = next_st;
              
              @(posedge vif.WCK_t);
            end
          end
          dq_pc1_en = 0;
          
          // Two-pulse Postamble (2 WCK cycles = 1 tCK)
          for (int p = 0; p < 2; p++) begin
            vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
            @(negedge vif.WCK_t);
            vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
            @(posedge vif.WCK_t);
          end
          vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
        end
      join_none
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= '0; // NOP
    end
  endtask

  // Task to read data from PC1
  task automatic read_pc1(input logic [1:0] bg, input logic [3:0] ba, input logic [5:0] col);
    begin
      dword_t dword;
      dword.CMD = CMD_RD;
      dword.BG = bg;
      dword.BA = ba;
      dword.C_ADDR = col;
      dword.C = calc_parity_dword(dword);
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= dword;
      last_write_state_pc1 = '0;
      
      fork
        begin
          logic [255:0] read_data;
          @(posedge vif.CK_t); // Wait for command to be on the bus
          
          fork
            begin
              repeat(rl_pc1 - 2) @(posedge vif.CK_t);
              // Four-pulse Preamble (4 WCK cycles = 2 tCK)
              for (int beat = 0; beat < 4; beat++) begin
                vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
                @(posedge vif.WCK_t);
              end
              
              // Toggle for 4 WCK cycles duration (2 tCK)
              for (int beat = 0; beat < 4; beat++) begin
                vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
                @(posedge vif.WCK_t);
              end
              
              // Two-pulse Postamble (2 WCK cycles = 1 tCK)
              for (int p = 0; p < 2; p++) begin
                vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
                @(posedge vif.WCK_t);
              end
            end
          join_none

          // Skip the RDQS 2-pulse preamble (2 WCK cycles = 1 tCK of toggling)
          repeat(2) begin
            @(posedge vif.RDQS_t_pc1);
            @(negedge vif.RDQS_t_pc1);
          end
          
          // We no longer wait for RL using CK, we just wait for RDQS edges!
          for (int beat = 0; beat < 4; beat++) begin
            automatic logic [31:0] dq_sampled;
            automatic logic [3:0]  dbi_sampled;
            
            @(posedge vif.RDQS_t_pc1);
            dq_sampled = vif.DQ_PC1;
            dbi_sampled = vif.DBI_PC1;
            for (int b = 0; b < 4; b++) begin
              read_data[(beat*2)*32 + b*8 +: 8] = dbi_sampled[b] ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
            end
            
            @(negedge vif.RDQS_t_pc1);
            dq_sampled = vif.DQ_PC1;
            dbi_sampled = vif.DBI_PC1;
            for (int b = 0; b < 4; b++) begin
              read_data[(beat*2+1)*32 + b*8 +: 8] = dbi_sampled[b] ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
            end
          end
          $display("[%0t] HBM4_BFM: PC1 Burst Read Data = %0h", $time, read_data);
        end
      join_none
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= '0; // NOP
    end
  endtask

  // Task to issue REF command
  task refresh();
    begin
      aword_t aword;
      aword.CMD = CMD_REF;
      aword.BG = '0;
      aword.BA = '0;
      aword.R_ADDR = '0;
      aword.R = calc_parity_aword(aword) ^ inject_aerr; inject_aerr = 0;
      
      @(posedge vif.CK_t);
      vif.AWORD <= aword;
      
      @(posedge vif.CK_t);
      vif.AWORD <= '0; // NOP
    end
  endtask

  // Task to issue Refresh Management command
  // rfm_type: 0 = RFMab (all-bank), 1 = RFMpb (per-bank)
  // For RFMpb: bg/ba select the target bank
  task rfm(input logic rfm_type, input logic [1:0] bg = '0, input logic [3:0] ba = '0);
    begin
      aword_t aword;
      aword.CMD = CMD_RFM;
      aword.BG = bg;
      aword.BA = {rfm_type, ba[2:0]};
      aword.R_ADDR = '0;
      aword.R = calc_parity_aword(aword) ^ inject_aerr; inject_aerr = 0;
      
      @(posedge vif.CK_t);
      vif.AWORD <= aword;
      
      @(posedge vif.CK_t);
      vif.AWORD <= '0; // NOP
    end
  endtask

  // Task to issue Directed Refresh Management (DRFM) — ACT with DRFM bit set
  task drfm(input logic [1:0] bg, input logic [3:0] ba, input logic [14:0] row);
    begin
      aword_t aword;
      logic [4:0] r_addr;
      r_addr = row[4:0];
      r_addr[DRFM_BIT] = 1'b1; // Set DRFM indicator
      aword.CMD = CMD_ACT;
      aword.BG = bg;
      aword.BA = ba;
      aword.R_ADDR = r_addr;
      aword.R = calc_parity_aword(aword) ^ inject_aerr; inject_aerr = 0;
      
      @(posedge vif.CK_t);
      vif.AWORD <= aword;
      
      @(posedge vif.CK_t);
      vif.AWORD <= '0; // NOP
    end
  endtask

   // Task to issue ZQ Calibration command
  // zq_long: 0 = ZQCS (short), 1 = ZQCL (long)
  task zq_calibrate(input logic zq_long);
    begin
      aword_t aword;
      aword.CMD = CMD_ZQ;
      aword.BG = '0;
      aword.BA = {3'b0, zq_long};
      aword.R_ADDR = '0;
      aword.R = calc_parity_aword(aword) ^ inject_aerr; inject_aerr = 0;
      
      @(posedge vif.CK_t);
      vif.AWORD <= aword;
      
      @(posedge vif.CK_t);
      vif.AWORD <= '0; // NOP
    end
  endtask

  // Write with Auto-Precharge (WRA) — sets AP_BIT in column address
  task automatic write_ap_pc0(input logic [1:0] bg, input logic [3:0] ba, input logic [4:0] col, input logic [255:0] data);
    logic [5:0] col_ap;
    col_ap = {1'b1, col};  // Set AP_BIT (bit 5)
    write_pc0(bg, ba, col_ap, data);
  endtask

  task automatic write_ap_pc1(input logic [1:0] bg, input logic [3:0] ba, input logic [4:0] col, input logic [255:0] data);
    logic [5:0] col_ap;
    col_ap = {1'b1, col};
    write_pc1(bg, ba, col_ap, data);
  endtask

  // Read with Auto-Precharge (RDA) — sets AP_BIT in column address
  task automatic read_ap_pc0(input logic [1:0] bg, input logic [3:0] ba, input logic [4:0] col);
    logic [5:0] col_ap;
    col_ap = {1'b1, col};
    read_pc0(bg, ba, col_ap);
  endtask

  task automatic read_ap_pc1(input logic [1:0] bg, input logic [3:0] ba, input logic [4:0] col);
    logic [5:0] col_ap;
    col_ap = {1'b1, col};
    read_pc1(bg, ba, col_ap);
  endtask

  // Task to issue MRS command to PC0
  task mode_register_set_pc0(input logic [4:0] mr_idx, input logic [7:0] data);
    begin
      dword_t dword;
      dword.CMD = CMD_MRS;
      dword.BA = mr_idx[3:0];
      dword.BG = data[7:6];
      dword.C_ADDR = data[5:0];
      dword.C = mr_idx[4];
      
      if (mr_idx == 5'h1 && data[4:0] != 0) wl_pc0 = data[4:0];
      if (mr_idx == 5'h2 && data != 0) rl_pc0 = data;
      
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= dword;
      
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= '0; // NOP
    end
  endtask

  // Task to issue MRS command to PC1
  task mode_register_set_pc1(input logic [4:0] mr_idx, input logic [7:0] data);
    begin
      dword_t dword;
      dword.CMD = CMD_MRS;
      dword.BA = mr_idx[3:0];
      dword.BG = data[7:6];
      dword.C_ADDR = data[5:0];
      dword.C = mr_idx[4];
      
      if (mr_idx == 5'h1 && data[4:0] != 0) wl_pc1 = data[4:0];
      if (mr_idx == 5'h2 && data != 0) rl_pc1 = data;
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= dword;
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= '0; // NOP
    end
  endtask

  // Task to issue MRR command to PC0
  task automatic mrr_pc0(input logic [4:0] mr_idx);
    begin
      dword_t dword;
      dword.CMD = CMD_MRR;
      dword.BA = mr_idx[3:0];
      dword.BG = 0;
      dword.C_ADDR = 0;
      dword.C = mr_idx[4];
      
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= dword;
      last_write_state_pc0 = '0;
      
      fork
        begin
          logic [255:0] read_data;
          @(posedge vif.CK_t); // Wait for command to be on the bus
          
          fork
            begin
              repeat(rl_pc0 - 2) @(posedge vif.CK_t);
              // Four-pulse Preamble (4 WCK cycles = 2 tCK)
              for (int beat = 0; beat < 4; beat++) begin
                vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
                @(posedge vif.WCK_t);
              end
              
              // Toggle for 4 WCK cycles duration (2 tCK)
              for (int beat = 0; beat < 4; beat++) begin
                vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
                @(posedge vif.WCK_t);
              end
              
              // Two-pulse Postamble (2 WCK cycles = 1 tCK)
              for (int p = 0; p < 2; p++) begin
                vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
                @(posedge vif.WCK_t);
              end
            end
          join_none

          // Skip the RDQS 2-pulse preamble (2 WCK cycles = 1 tCK of toggling)
          repeat(2) begin
            @(posedge vif.RDQS_t_pc0);
            @(negedge vif.RDQS_t_pc0);
          end
          
          // We no longer wait for RL using CK, we just wait for RDQS edges!
          for (int beat = 0; beat < 4; beat++) begin
            automatic logic [31:0] dq_sampled;
            automatic logic [3:0]  dbi_sampled;
            
            @(posedge vif.RDQS_t_pc0);
            dq_sampled = vif.DQ_PC0;
            dbi_sampled = vif.DBI_PC0;
            for (int b = 0; b < 4; b++) begin
              read_data[(beat*2)*32 + b*8 +: 8] = dbi_sampled[b] ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
            end
            
            @(negedge vif.RDQS_t_pc0);
            dq_sampled = vif.DQ_PC0;
            dbi_sampled = vif.DBI_PC0;
            for (int b = 0; b < 4; b++) begin
              read_data[(beat*2+1)*32 + b*8 +: 8] = dbi_sampled[b] ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
            end
          end
          $display("[%0t] HBM4_BFM: PC0 MRR MR%0d Read Data = %0h", $time, mr_idx, read_data[7:0]);
        end
      join_none
      
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= '0; // NOP
    end
  endtask

  // Task to issue MRR command to PC1
  task automatic mrr_pc1(input logic [4:0] mr_idx);
    begin
      dword_t dword;
      dword.CMD = CMD_MRR;
      dword.BA = mr_idx[3:0];
      dword.BG = 0;
      dword.C_ADDR = 0;
      dword.C = mr_idx[4];
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= dword;
      last_write_state_pc1 = '0;
      
      fork
        begin
          logic [255:0] read_data;
          @(posedge vif.CK_t); // Wait for command to be on the bus
          
          fork
            begin
              repeat(rl_pc1 - 2) @(posedge vif.CK_t);
              // Four-pulse Preamble (4 WCK cycles = 2 tCK)
              for (int beat = 0; beat < 4; beat++) begin
                vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
                @(posedge vif.WCK_t);
              end
              
              // Toggle for 4 WCK cycles duration (2 tCK)
              for (int beat = 0; beat < 4; beat++) begin
                vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
                @(posedge vif.WCK_t);
              end
              
              // Two-pulse Postamble (2 WCK cycles = 1 tCK)
              for (int p = 0; p < 2; p++) begin
                vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
                @(posedge vif.WCK_t);
              end
            end
          join_none

          // Skip the RDQS 2-pulse preamble (2 WCK cycles = 1 tCK of toggling)
          repeat(2) begin
            @(posedge vif.RDQS_t_pc1);
            @(negedge vif.RDQS_t_pc1);
          end
          
          // We no longer wait for RL using CK, we just wait for RDQS edges!
          for (int beat = 0; beat < 4; beat++) begin
            automatic logic [31:0] dq_sampled;
            automatic logic [3:0]  dbi_sampled;
            
            @(posedge vif.RDQS_t_pc1);
            dq_sampled = vif.DQ_PC1;
            dbi_sampled = vif.DBI_PC1;
            for (int b = 0; b < 4; b++) begin
              read_data[(beat*2)*32 + b*8 +: 8] = dbi_sampled[b] ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
            end
            
            @(negedge vif.RDQS_t_pc1);
            dq_sampled = vif.DQ_PC1;
            dbi_sampled = vif.DBI_PC1;
            for (int b = 0; b < 4; b++) begin
              read_data[(beat*2+1)*32 + b*8 +: 8] = dbi_sampled[b] ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
            end
          end
          $display("[%0t] HBM4_BFM: PC1 MRR MR%0d Read Data = %0h", $time, mr_idx, read_data[7:0]);
        end
      join_none
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= '0; // NOP
    end
  endtask

  // -----------------------------------------------------------------------
  // IEEE 1500 WSP: Program Interconnect Remap Entry
  // Shifts 37-bit remap data via WSI: {valid, bg[1:0], ba[3:0], faulty_row[14:0], spare_row[14:0]}
  // -----------------------------------------------------------------------
  task automatic program_remap(
    input logic [1:0] bg, input logic [3:0] ba,
    input logic [14:0] faulty_row, input logic [14:0] spare_row
  );
    localparam int REMAP_REG_WIDTH = 37;
    logic [REMAP_REG_WIDTH-1:0] remap_data;
    logic [7:0] wir_data;
    int i;

    remap_data = {1'b1, bg, ba, faulty_row, spare_row};
    wir_data = 8'h02; // Remap instruction

    $display("[%0t] BFM: Programming remap BG%0d BA%0d Row 0x%04h -> Spare 0x%04h",
             $time, bg, ba, faulty_row, spare_row);

    // Phase 1: Load WIR = 0x02 (remap opcode)
    @(posedge vif.WRCK);
    vif.SelectVR <= 1'b1;
    @(posedge vif.WRCK);
    vif.CaptureWR <= 1'b1;
    @(posedge vif.WRCK);
    vif.CaptureWR <= 1'b0;
    vif.ShiftWR <= 1'b1;
    for (i = 0; i < 8; i++) begin
      vif.WSI <= wir_data[i];
      @(posedge vif.WRCK);
    end
    vif.ShiftWR <= 1'b0;
    vif.UpdateWR <= 1'b1;
    @(posedge vif.WRCK);
    vif.UpdateWR <= 1'b0;
    vif.SelectVR <= 1'b0;

    // Phase 2: Shift in remap data (37 bits, LSB first)
    @(posedge vif.WRCK);
    vif.CaptureWR <= 1'b1;
    @(posedge vif.WRCK);
    vif.CaptureWR <= 1'b0;
    vif.ShiftWR <= 1'b1;
    for (i = 0; i < REMAP_REG_WIDTH; i++) begin
      vif.WSI <= remap_data[i];
      @(posedge vif.WRCK);
    end
    vif.ShiftWR <= 1'b0;
    vif.UpdateWR <= 1'b1;
    @(posedge vif.WRCK);
    vif.UpdateWR <= 1'b0;
    
    repeat(2) @(posedge vif.WRCK);
  endtask

endmodule
`endif
