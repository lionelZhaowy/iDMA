// Copyright 2026 ZhaoWenyao
// SPDX-License-Identifier: SHL-0.51
// A finite, independent shared-memory fabric for the real generated rw_axi backend.
`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "idma/typedef.svh"
module tb_shared_axi;
  import idma_pkg::*;
  localparam int DataWidth=64, AddrWidth=32, AxiIdWidth=2, UserWidth=1;
  localparam int BufferDepth=3, NumAxInFlight=3, TFLenWidth=32, StrbWidth=8;
  typedef logic [31:0] addr_t;
  typedef logic [31:0] tf_len_t;
  typedef logic [63:0] data_t;
  typedef logic [7:0] strb_t;
  typedef logic [1:0] id_t;
  typedef logic [0:0] user_t;
  `AXI_TYPEDEF_AW_CHAN_T(aw_t,addr_t,id_t,user_t)
  `AXI_TYPEDEF_W_CHAN_T(w_t,data_t,strb_t,user_t)
  `AXI_TYPEDEF_B_CHAN_T(b_t,id_t,user_t)
  `AXI_TYPEDEF_AR_CHAN_T(ar_t,addr_t,id_t,user_t)
  `AXI_TYPEDEF_R_CHAN_T(r_t,data_t,id_t,user_t)
  `AXI_TYPEDEF_REQ_T(axi_req_t,aw_t,w_t,ar_t)
  `AXI_TYPEDEF_RESP_T(axi_rsp_t,b_t,r_t)
  `IDMA_TYPEDEF_FULL_REQ_T(req_t,id_t,addr_t,tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(rsp_t,addr_t)
  typedef struct packed { ar_t ar_chan; } r_meta_t;
  typedef struct packed { r_meta_t axi; } read_meta_channel_t;
  typedef struct packed { aw_t aw_chan; } w_meta_t;
  typedef struct packed { w_meta_t axi; } write_meta_channel_t;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  req_t req;
  rsp_t rsp;
  logic req_valid=0, req_ready, rsp_valid;
  idma_eh_req_t eh='0;
  logic eh_ready;
  idma_busy_t busy;
  axi_req_t rd, wr;
  axi_rsp_t rd_rsp,wr_rsp;
  idma_backend_rw_axi #(
    .DataWidth(DataWidth),.AddrWidth(AddrWidth),.AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth),.TFLenWidth(TFLenWidth),.BufferDepth(BufferDepth),
    .NumAxInFlight(NumAxInFlight),.MemSysDepth(0),.CombinedShifter(0),
    .RAWCouplingAvail(1),.HardwareLegalizer(1),.RejectZeroTransfers(1),
    .ErrorCap(NO_ERROR_HANDLING),.PrintFifoInfo(0),
    .idma_req_t(req_t),.idma_rsp_t(rsp_t),.idma_eh_req_t(idma_eh_req_t),
    .idma_busy_t(idma_busy_t),.axi_req_t(axi_req_t),.axi_rsp_t(axi_rsp_t),
    .read_meta_channel_t(read_meta_channel_t),
    .write_meta_channel_t(write_meta_channel_t)
  ) dut (
    .clk_i(clk),.rst_ni(rst_n),.req_valid_i(req_valid),.req_ready_o(req_ready),
    .idma_req_i(req),.idma_rsp_o(rsp),.rsp_valid_o(rsp_valid),.rsp_ready_i(1'b1),
    .idma_eh_req_i(eh),.eh_req_valid_i(1'b0),.eh_req_ready_o(eh_ready),
    .axi_read_req_o(rd),.axi_read_rsp_i(rd_rsp),
    .axi_write_req_o(wr),.axi_write_rsp_i(wr_rsp),.busy_o(busy)
  );
  byte unsigned mem[4096], gold[4096];
  logic reading=0, writing=0, b_pending=0;
  logic [1:0] grant=0; // 0=idle, 1=read, 2=write; registered arbitration
  ar_t active_ar;
  aw_t active_aw;
  int r_index=0,w_index=0;
  int shared=1,decouple_aw=1,ar_count=0,aw_count=0,r_count=0,w_count=0,b_count=0;
  int cycle=0, complete_count=0, checks=0,errors=0;
  int r_addr,w_addr;
  always_comb begin
    rd_rsp='0; wr_rsp='0;
    // A legal single memory port can accept only one address while idle.
    // AW has priority, and an accepted burst retains the port until its data finishes.
    // The independent-port control removes only this shared arbitration constraint.
    wr_rsp.aw_ready=!writing && !b_pending && (!shared || grant==2);
    rd_rsp.ar_ready=!reading && (!shared || grant==1);
    rd_rsp.r_valid=reading;
    rd_rsp.r.id=active_ar.id;
    rd_rsp.r.last=(r_index==int'(active_ar.len));
    rd_rsp.r.resp=axi_pkg::RESP_OKAY;
    r_addr=int'(active_ar.addr)+r_index*8;
    for(int lane=0;lane<8;lane++)
      rd_rsp.r.data[lane*8+:8]=mem[(r_addr&32'hfffffff8)+lane];
    wr_rsp.w_ready=writing;
    wr_rsp.b_valid=b_pending;
    wr_rsp.b.id=active_aw.id;
    wr_rsp.b.resp=axi_pkg::RESP_OKAY;
  end
  always @(posedge clk) if(rst_n) begin
    cycle++;
    // Grant selection is registered. No READY output depends combinationally
    // on any AXI request input, including a request on the other DMA port.
    if (shared) begin
      if (grant==0 && !reading && !writing && !b_pending) begin
        if (wr.aw_valid) grant<=2;
        else if (rd.ar_valid) grant<=1;
      end
      if ((rd.ar_valid && rd_rsp.ar_ready) ||
          (wr.aw_valid && wr_rsp.aw_ready)) grant<=0;
    end
    if(rd.ar_valid && rd_rsp.ar_ready) begin
      if($isunknown(rd.ar) || rd.ar.size!==3 || rd.ar.burst!==axi_pkg::BURST_INCR)
        $fatal(1,"FABRIC_BAD_AR");
      active_ar<=rd.ar;reading<=1;r_index<=0;ar_count++;
      $display("FABRIC_AR cycle=%0d address=%h len=%0d",cycle,rd.ar.addr,rd.ar.len);
    end
    if(wr.aw_valid && wr_rsp.aw_ready) begin
      if($isunknown(wr.aw) || wr.aw.size!==3 || wr.aw.burst!==axi_pkg::BURST_INCR)
        $fatal(1,"FABRIC_BAD_AW");
      active_aw<=wr.aw;writing<=1;w_index<=0;aw_count++;
      $display("FABRIC_AW cycle=%0d address=%h len=%0d",cycle,wr.aw.addr,wr.aw.len);
    end
    if(rd_rsp.r_valid && rd.r_ready) begin
      r_count++;
      if(rd_rsp.r.last)reading<=0;
      else r_index<=r_index+1;
    end
    if(wr.w_valid && wr_rsp.w_ready) begin
      w_count++;
      if($isunknown(wr.w))$fatal(1,"FABRIC_UNKNOWN_W");
      w_addr=int'(active_aw.addr)+w_index*8;
      for(int lane=0;lane<8;lane++)
        if(wr.w.strb[lane])mem[(w_addr&32'hfffffff8)+lane]<=wr.w.data[lane*8+:8];
      if(wr.w.last!==(w_index==int'(active_aw.len)))$fatal(1,"FABRIC_BAD_WLAST");
      if(wr.w.last)begin writing<=0;b_pending<=1;end
      else w_index<=w_index+1;
    end
    if(wr_rsp.b_valid && wr.b_ready)begin b_pending<=0;b_count++;end
    if(rsp_valid)begin
      complete_count++;
      if($isunknown(rsp) || rsp.error)$fatal(1,"DMA_ERROR_RESPONSE");
    end
  end
  initial begin
    if($value$plusargs("SHARED=%d",shared))begin end
    if($value$plusargs("DECOUPLE_AW=%d",decouple_aw))begin end
    req='0;active_ar='0;active_aw='0;
    for(int i=0;i<4096;i++)begin mem[i]=8'(i*29+17+7*(i>>3)+11*(i>>8));gold[i]=mem[i];end
    for(int i=0;i<64;i++)gold['h200+i]=mem['h100+i];
    repeat(4)@(negedge clk);
    rst_n=1;
    repeat(2)@(negedge clk);
    req.length=64;req.src_addr='h100;req.dst_addr='h200;
    req.opt.src_protocol=AXI;req.opt.dst_protocol=AXI;
    req.opt.src.burst=axi_pkg::BURST_INCR;req.opt.dst.burst=axi_pkg::BURST_INCR;
    req.opt.axi_id=1;
    req.opt.beo.decouple_aw=1'(decouple_aw);
    req.opt.beo.decouple_rw=0;
`ifdef AUTHOR227
    req.opt.beo.deadlock_free=1;
`endif
    req_valid=1;
    do @(posedge clk);while(!req_ready);
    @(negedge clk);req_valid=0;
    wait(complete_count==1);
    repeat(10)@(negedge clk);
    if ($test$plusargs("CORRUPT_COPY")) mem['h200] ^= 8'h01;
    for(int i=0;i<4096;i++)begin
      checks++;
      if(mem[i]!==gold[i])begin
        errors++;if(errors<5)$display("DATA_MISMATCH address=%h got=%h expected=%h",i,mem[i],gold[i]);
      end
    end
    if(complete_count!=1 || $isunknown({reading,writing,b_pending,busy}) ||
       reading || writing || b_pending || (|busy) || r_count!=8 || w_count!=8 || ar_count!=aw_count || b_count!=aw_count)
      $fatal(1,"COMPLETION_STATE_MISMATCH");
    $display("SHARED_AXI_DONE shared=%0d decouple_aw=%0d checks=%0d errors=%0d complete=%0d AR=%0d AW=%0d R=%0d W=%0d B=%0d",
       shared,decouple_aw,checks,errors,complete_count,ar_count,aw_count,r_count,w_count,b_count);
    if(errors)$fatal(1,"DATA_FAILURE");
    $finish;
  end
  initial begin
    #90000;
    $display("SHARED_AXI_PROGRESS complete=%0d AR=%0d AW=%0d R=%0d W=%0d B=%0d",complete_count,ar_count,aw_count,r_count,w_count,b_count);
    #10000;
    $display("SHARED_AXI_DEADLINE shared=%0d decouple_aw=%0d complete=%0d AR=%0d AW=%0d R=%0d W=%0d B=%0d reading=%b writing=%b r_ready=%b w_valid=%b ar_valid=%b ar_ready=%b aw_valid=%b aw_ready=%b",
      shared,decouple_aw,complete_count,ar_count,aw_count,r_count,w_count,b_count,
      reading,writing,rd.r_ready,wr.w_valid,rd.ar_valid,rd_rsp.ar_ready,wr.aw_valid,wr_rsp.aw_ready);
    $finish;
  end
endmodule
