`ifndef HBM4_TRACE_DECODER_SV
`define HBM4_TRACE_DECODER_SV

import hbm4_pkg::*;

module hbm4_trace_decoder #(
  parameter int CHANNEL_ID = 0
)(
  hbm4_if.mem vif
);

  always @(posedge vif.CK_t) begin
    if (vif.RESET_n) begin
      aword_t aword;
      dword_t dword_pc0;
      dword_t dword_pc1;
      
      aword = aword_t'(vif.AWORD);
      dword_pc0 = dword_t'(vif.DWORD_PC0);
      dword_pc1 = dword_t'(vif.DWORD_PC1);
      
      // Decode AWORD (Row Commands)
      if (aword.CMD != CMD_NOP) begin
        case (aword.CMD)
          CMD_ACT: $display("[%10t] TRACE [CH %2d]       AWORD : ACT  | BG=%-2d | BA=%-2d | ROW=0x%04h", $time, CHANNEL_ID, aword.BG, aword.BA, 15'(vif.AWORD));
          CMD_PRE: $display("[%10t] TRACE [CH %2d]       AWORD : PRE  | BG=%-2d | BA=%-2d |", $time, CHANNEL_ID, aword.BG, aword.BA);
          CMD_PDE: $display("[%10t] TRACE [CH %2d]       AWORD : PDE  |", $time, CHANNEL_ID);
          CMD_MRS: $display("[%10t] TRACE [CH %2d]       AWORD : MRS  |", $time, CHANNEL_ID);
          CMD_REF: $display("[%10t] TRACE [CH %2d]       AWORD : REF  |", $time, CHANNEL_ID);
          CMD_SRE: $display("[%10t] TRACE [CH %2d]       AWORD : SRE  |", $time, CHANNEL_ID);
          default: $display("[%10t] TRACE [CH %2d]       AWORD : UNK  | CMD=%0h", $time, CHANNEL_ID, aword.CMD);
        endcase
      end
      
      // Decode DWORD_PC0 (Column Commands)
      if (dword_pc0.CMD != CMD_NOP) begin
        case (dword_pc0.CMD)
          CMD_RD:  $display("[%10t] TRACE [CH %2d] [PC0] DWORD : RD   | BG=%-2d | BA=%-2d | COL=0x%04h", $time, CHANNEL_ID, dword_pc0.BG, dword_pc0.BA, dword_pc0.C_ADDR);
          CMD_WR:  $display("[%10t] TRACE [CH %2d] [PC0] DWORD : WR   | BG=%-2d | BA=%-2d | COL=0x%04h", $time, CHANNEL_ID, dword_pc0.BG, dword_pc0.BA, dword_pc0.C_ADDR);
          CMD_MRS: $display("[%10t] TRACE [CH %2d] [PC0] DWORD : MRS  | BG=%-2d | BA=%-2d | OP=0x%04h", $time, CHANNEL_ID, dword_pc0.BG, dword_pc0.BA, dword_pc0.C_ADDR);
          default: $display("[%10t] TRACE [CH %2d] [PC0] DWORD : UNK  | CMD=%0h", $time, CHANNEL_ID, dword_pc0.CMD);
        endcase
      end

      // Decode DWORD_PC1 (Column Commands)
      if (dword_pc1.CMD != CMD_NOP) begin
        case (dword_pc1.CMD)
          CMD_RD:  $display("[%10t] TRACE [CH %2d] [PC1] DWORD : RD   | BG=%-2d | BA=%-2d | COL=0x%04h", $time, CHANNEL_ID, dword_pc1.BG, dword_pc1.BA, dword_pc1.C_ADDR);
          CMD_WR:  $display("[%10t] TRACE [CH %2d] [PC1] DWORD : WR   | BG=%-2d | BA=%-2d | COL=0x%04h", $time, CHANNEL_ID, dword_pc1.BG, dword_pc1.BA, dword_pc1.C_ADDR);
          CMD_MRS: $display("[%10t] TRACE [CH %2d] [PC1] DWORD : MRS  | BG=%-2d | BA=%-2d | OP=0x%04h", $time, CHANNEL_ID, dword_pc1.BG, dword_pc1.BA, dword_pc1.C_ADDR);
          default: $display("[%10t] TRACE [CH %2d] [PC1] DWORD : UNK  | CMD=%0h", $time, CHANNEL_ID, dword_pc1.CMD);
        endcase
      end
    end
  end

endmodule : hbm4_trace_decoder

`endif
