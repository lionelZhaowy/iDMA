// Copyright 2026 ZhaoWenyao
// SPDX-License-Identifier: SHL-0.51
// A finite, independent shared-memory fabric for the real generated rw_axi backend.
`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "idma/typedef.svh"
`ifndef TEST_NUM_AX
`define TEST_NUM_AX 3
`endif
`ifndef TEST_BUFFER_DEPTH
`define TEST_BUFFER_DEPTH 3
`endif
module tb_coupled_axi_order;
  import idma_pkg::*;
  localparam int DataWidth=64, AddrWidth=32, AxiIdWidth=2, UserWidth=1;
  localparam int BufferDepth=`TEST_BUFFER_DEPTH, NumAxInFlight=`TEST_NUM_AX, TFLenWidth=32, StrbWidth=8;
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
  int scenario=0, deadlock_free=1, backpressure=0, job_count=1;
  int lengths[8], sources[8], destinations[8], rw_decoupled[8], aw_decoupled[8], job_df[8];
  int job_ar[8],job_aw[8],prior_job_ar[8],prior_job_aw[8];
  int total_bytes=0,write_bytes=0,order_errors=0,stable_errors=0;
  int protected_ar=0,protected_aw=0,permit_peak=0,same_cycle=0,queued_before_aw=0,tag_checks=0,tag_diff_current=0;
  int ar_stalls=0,aw_stalls=0,w_stalls=0,read_limit_stalls=0;
  int prior_permits,ar_job,aw_job;
  axi_req_t previous_rd,previous_wr;
  bit previous_ar_ready,previous_aw_ready,previous_w_ready,previous_valid=0;
  function automatic int source_job(longint unsigned address);
    for(int j=0;j<job_count;j++)
      if(address>=(sources[j]&32'hfffffff8) && address<sources[j]+lengths[j])return j;
    return -1;
  endfunction
  function automatic int destination_job(longint unsigned address);
    for(int j=0;j<job_count;j++)
      if(address>=(destinations[j]&32'hfffffff8) && address<destinations[j]+lengths[j])return j;
    return -1;
  endfunction
  function automatic bit protected_job(int j);
    return j>=0 && job_df[j] && !rw_decoupled[j];
  endfunction
  task automatic send_job(int j);
    req='0;req.length=lengths[j];req.src_addr=sources[j];req.dst_addr=destinations[j];
    req.opt.src_protocol=AXI;req.opt.dst_protocol=AXI;
    req.opt.src.burst=axi_pkg::BURST_INCR;req.opt.dst.burst=axi_pkg::BURST_INCR;
    req.opt.axi_id=id_t'(j);req.opt.beo.decouple_aw=1'(aw_decoupled[j]);
    req.opt.beo.decouple_rw=1'(rw_decoupled[j]);req.opt.beo.deadlock_free=1'(job_df[j]);
    req_valid=1;
    do @(posedge clk);while(!req_ready);
    if(aw_count==0)queued_before_aw++;
    $display("ORDER_JOB cycle=%0d job=%0d rw=%0d aw=%0d df=%0d before_first_aw=%0d",cycle,j,rw_decoupled[j],aw_decoupled[j],job_df[j],aw_count==0);
    @(negedge clk);req_valid=0;
  endtask
  always_comb begin
    rd_rsp='0; wr_rsp='0;
    // A legal single memory port can accept only one address while idle.
    // AW has priority, and an accepted burst retains the port until its data finishes.
    // The independent-port control removes only this shared arbitration constraint.
    wr_rsp.aw_ready=!writing && !b_pending && (!shared || grant==2) &&
      (!backpressure || (backpressure==3 ? cycle>=30 : (cycle>=80 && cycle%7!=1 && cycle%7!=2)));
    rd_rsp.ar_ready=!reading && (!shared || grant==1) &&
      (!backpressure || (backpressure==3 ? cycle>=30 : (cycle>=30 && cycle%5!=1)));
    rd_rsp.r_valid=reading;
    rd_rsp.r.id=active_ar.id;
    rd_rsp.r.last=(r_index==int'(active_ar.len));
    rd_rsp.r.resp=axi_pkg::RESP_OKAY;
    r_addr=int'(active_ar.addr)+r_index*8;
    for(int lane=0;lane<8;lane++)
      rd_rsp.r.data[lane*8+:8]=mem[(r_addr&32'hfffffff8)+lane];
    wr_rsp.w_ready=writing && (!backpressure || cycle%4!=1);
    wr_rsp.b_valid=b_pending;
    wr_rsp.b.id=active_aw.id;
    wr_rsp.b.resp=axi_pkg::RESP_OKAY;
  end
  always @(posedge clk) if(rst_n) begin
    cycle++;
    if($isunknown({req_valid,req_ready,rd.ar_valid,rd.r_ready,wr.aw_valid,
                   wr.w_valid,wr.b_ready,rd_rsp.ar_ready,rd_rsp.r_valid,
                   wr_rsp.aw_ready,wr_rsp.w_ready,wr_rsp.b_valid,rsp_valid}))
      $fatal(1,"UNKNOWN_CHANNEL_CONTROL");
    // Snapshot prior-cycle permits before either same-edge handshake is counted.
    prior_permits=protected_ar-protected_aw;
`ifdef CANDIDATE_PERMIT
    if(dut.read_permits_q !== $bits(dut.read_permits_q)'(prior_permits))$fatal(1,"REGISTERED_PERMIT_MISMATCH");
`endif
    foreach(job_ar[j])begin prior_job_ar[j]=job_ar[j];prior_job_aw[j]=job_aw[j];end
    if(previous_valid)begin
      if(previous_rd.ar_valid && !previous_ar_ready &&
         (!rd.ar_valid || rd.ar!==previous_rd.ar))stable_errors++;
      if(previous_wr.aw_valid && !previous_aw_ready &&
         (!wr.aw_valid || wr.aw!==previous_wr.aw))stable_errors++;
      if(previous_wr.w_valid && !previous_w_ready &&
         (!wr.w_valid || wr.w!==previous_wr.w))stable_errors++;
    end
    previous_rd=rd;previous_wr=wr;previous_ar_ready=rd_rsp.ar_ready;
    previous_aw_ready=wr_rsp.aw_ready;previous_w_ready=wr_rsp.w_ready;previous_valid=1;
    if(rd.ar_valid && !rd_rsp.ar_ready)ar_stalls++;
    if(wr.aw_valid && !wr_rsp.aw_ready)aw_stalls++;
    if(wr.w_valid && !wr_rsp.w_ready)w_stalls++;
    if(prior_permits==NumAxInFlight && cycle<80)read_limit_stalls++;
    if(rd.ar_valid && rd_rsp.ar_ready && wr.aw_valid && wr_rsp.aw_ready)same_cycle++;
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
      ar_job=source_job(rd.ar.addr);if(ar_job<0)$fatal(1,"UNKNOWN_READ_JOB");
`ifdef CANDIDATE_PERMIT
      tag_checks++;
      if(dut.ar_req_dp.coupled !== protected_job(ar_job))$fatal(1,"READ_MODE_TAG_MISMATCH");
`endif
      if(protected_job(ar_job))begin
        if(prior_permits>=NumAxInFlight)order_errors++;
        protected_ar++;
      end
      job_ar[ar_job]++;
      active_ar<=rd.ar;reading<=1;r_index<=0;ar_count++;
      $display("FABRIC_AR cycle=%0d address=%h len=%0d",cycle,rd.ar.addr,rd.ar.len);
    end
    if(wr.aw_valid && wr_rsp.aw_ready) begin
      if($isunknown(wr.aw) || wr.aw.size!==3 || wr.aw.burst!==axi_pkg::BURST_INCR)
        $fatal(1,"FABRIC_BAD_AW");
      aw_job=destination_job(wr.aw.addr);if(aw_job<0)$fatal(1,"UNKNOWN_WRITE_JOB");
`ifdef CANDIDATE_PERMIT
      tag_checks++;
      if(dut.aw_order_req.coupled !== protected_job(aw_job))$fatal(1,"WRITE_MODE_TAG_MISMATCH");
      if(dut.aw_order_req.coupled !== (req.opt.beo.deadlock_free && !req.opt.beo.decouple_rw))tag_diff_current++;
`endif
      if(protected_job(aw_job))begin
        if(prior_permits<=0 || prior_job_aw[aw_job]>=prior_job_ar[aw_job])begin
          order_errors++;
          $display("ORDER_EARLY_AW cycle=%0d job=%0d prior_global=%0d prior_job=%0d",cycle,aw_job,prior_permits,prior_job_ar[aw_job]-prior_job_aw[aw_job]);
        end
        protected_aw++;
      end
      job_aw[aw_job]++;
      active_aw<=wr.aw;writing<=1;w_index<=0;aw_count++;
      $display("FABRIC_AW cycle=%0d address=%h len=%0d",cycle,wr.aw.addr,wr.aw.len);
    end
    if(rd_rsp.r_valid && rd.r_ready) begin
      r_count++;
      if(rd_rsp.r.last)reading<=0;
      else r_index<=r_index+1;
    end
    if(wr.w_valid && wr_rsp.w_ready) begin
      w_count++;write_bytes+=$countones(wr.w.strb);
      if($isunknown(wr.w))$fatal(1,"FABRIC_UNKNOWN_W");
      w_addr=int'(active_aw.addr)+w_index*8;
      for(int lane=0;lane<8;lane++)
        if(wr.w.strb[lane])mem[(w_addr&32'hfffffff8)+lane]<=wr.w.data[lane*8+:8];
      if(wr.w.last!==(w_index==int'(active_aw.len)))$fatal(1,"FABRIC_BAD_WLAST");
      if(wr.w.last)begin writing<=0;b_pending<=1;end
      else w_index<=w_index+1;
    end
    if(wr_rsp.b_valid && wr.b_ready)begin b_pending<=0;b_count++;end
    if(protected_ar-protected_aw>permit_peak)permit_peak=protected_ar-protected_aw;
    if(rsp_valid)begin
      complete_count++;
      if($isunknown(rsp) || rsp.error)$fatal(1,"DMA_ERROR_RESPONSE");
    end
  end
  initial begin
    if($value$plusargs("SHARED=%d",shared))begin end
    if($value$plusargs("SCENARIO=%d",scenario))begin end
    if($value$plusargs("DEADLOCK_FREE=%d",deadlock_free))begin end
    if($value$plusargs("BACKPRESSURE=%d",backpressure))begin end
    if($value$plusargs("DECOUPLE_AW=%d",decouple_aw))begin end
    req='0;active_ar='0;active_aw='0;previous_rd='0;previous_wr='0;
    foreach(lengths[j])begin
      job_ar[j]=0;job_aw[j]=0;prior_job_ar[j]=0;prior_job_aw[j]=0;
      lengths[j]=16;sources[j]='h100+j*'h100;destinations[j]='h900+j*'h80;
      rw_decoupled[j]=0;aw_decoupled[j]=decouple_aw;job_df[j]=deadlock_free;
    end
    case(scenario)
      0: begin job_count=1;lengths[0]=64;end
      1: begin
        job_count=6;
        for(int j=0;j<job_count;j++)begin rw_decoupled[j]=j%2;aw_decoupled[j]=(j%3!=2);end
      end
      2: begin job_count=6;end
      3: begin
        job_count=8;
        lengths[0]=1;lengths[1]=7;lengths[2]=8;lengths[3]=9;
        lengths[4]=15;lengths[5]=16;lengths[6]=17;lengths[7]=33;
        for(int j=0;j<job_count;j++)begin sources[j]+=j%8;destinations[j]+=(j+3)%8;end
      end
      4: begin
        job_count=3;
        for(int j=0;j<job_count;j++)begin rw_decoupled[j]=1;lengths[j]=33+j*8;end
      end
      5: begin
        job_count=6;
        for(int j=0;j<job_count;j++)begin
          job_df[j]=(j%2==0);rw_decoupled[j]=(j%3==2);aw_decoupled[j]=(j%3!=2);
        end
      end
      default:$fatal(1,"INVALID_SCENARIO");
    endcase
    for(int i=0;i<4096;i++)begin mem[i]=8'(i*29+17+7*(i>>3)+11*(i>>8));gold[i]=mem[i];end
    for(int j=0;j<job_count;j++)begin
      total_bytes+=lengths[j];
      for(int i=0;i<lengths[j];i++)gold[destinations[j]+i]=mem[sources[j]+i];
    end
    repeat(4)@(negedge clk);rst_n=1;repeat(2)@(negedge clk);
    $display("ORDER_CONFIG num_ax=%0d buffer=%0d scenario=%0d shared=%0d df=%0d backpressure=%0d",NumAxInFlight,BufferDepth,scenario,shared,deadlock_free,backpressure);
    for(int j=0;j<job_count;j++)send_job(j);
    wait(complete_count==job_count);repeat(10)@(negedge clk);
    if ($test$plusargs("CORRUPT_COPY")) mem[destinations[0]] ^= 8'h01;
    for(int i=0;i<4096;i++)begin
      checks++;
      if(mem[i]!==gold[i])begin errors++;if(errors<5)$display("DATA_MISMATCH address=%h got=%h expected=%h",i,mem[i],gold[i]);end
    end
    if(complete_count!=job_count || $isunknown({reading,writing,b_pending,busy}) ||
       reading || writing || b_pending || (|busy) || write_bytes!=total_bytes || b_count!=aw_count)
      $fatal(1,"COMPLETION_STATE_MISMATCH");
    if(protected_ar!=protected_aw)order_errors++;
    for(int j=0;j<job_count;j++)if(protected_job(j) && job_ar[j]!=job_aw[j])order_errors++;
    if((scenario==1 || scenario==2 || scenario==5) && backpressure && queued_before_aw<2)$fatal(1,"QUEUE_TRANSITION_NOT_REACHED");
    if(backpressure && (ar_stalls==0 || w_stalls==0 || (backpressure==1 && aw_stalls==0)))$fatal(1,"BACKPRESSURE_NOT_REACHED");
`ifdef CANDIDATE_PERMIT
    if((scenario==1 || scenario==5) && deadlock_free && tag_diff_current==0)$fatal(1,"QUEUED_MODE_DIFFERENCE_NOT_REACHED");
`endif
    $display("ORDER_TAGS checks=%0d differs_from_current_job=%0d",tag_checks,tag_diff_current);
    $display("ORDER_DONE scenario=%0d df=%0d num_ax=%0d buffer=%0d jobs=%0d checks=%0d data_errors=%0d order_errors=%0d stable_errors=%0d bytes=%0d AR=%0d AW=%0d R=%0d W=%0d B=%0d protected_ar=%0d protected_aw=%0d peak=%0d simultaneous=%0d queued=%0d ar_stalls=%0d aw_stalls=%0d w_stalls=%0d limit_stalls=%0d",scenario,deadlock_free,NumAxInFlight,BufferDepth,job_count,checks,errors,order_errors,stable_errors,write_bytes,ar_count,aw_count,r_count,w_count,b_count,protected_ar,protected_aw,permit_peak,same_cycle,queued_before_aw,ar_stalls,aw_stalls,w_stalls,read_limit_stalls);
    if(errors)$fatal(1,"DATA_FAILURE");
    if(order_errors || stable_errors)$fatal(1,"ORDER_FAILURE");
    $finish;
  end
  initial begin
    #90000;
    $display("ORDER_PROGRESS complete=%0d AR=%0d AW=%0d R=%0d W=%0d B=%0d",complete_count,ar_count,aw_count,r_count,w_count,b_count);
    #10000;
    $display("ORDER_DEADLINE shared=%0d decouple_aw=%0d complete=%0d AR=%0d AW=%0d R=%0d W=%0d B=%0d reading=%b writing=%b r_ready=%b w_valid=%b ar_valid=%b ar_ready=%b aw_valid=%b aw_ready=%b",
      shared,decouple_aw,complete_count,ar_count,aw_count,r_count,w_count,b_count,
      reading,writing,rd.r_ready,wr.w_valid,rd.ar_valid,rd_rsp.ar_ready,wr.aw_valid,wr_rsp.aw_ready);
    $finish;
  end
endmodule
