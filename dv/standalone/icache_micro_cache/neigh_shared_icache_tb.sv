// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// vim: se syn=systemverilog:

// //////////////////////////////////////////////////////////////////////////////
// Directed test for neigh_shared_icache: two minions miss, sleep, and retry.
//
// neigh_shared_icache owns the per-minion request flops and the LRU arbiter in
// front of icache_top (L1 tags, L1 miss handler, L0 micro-cache). The L1 data
// SRAMs and the L2 live outside it, so this bench supplies both:
//
//   L2 responder    answers every L2 line read L2_LATENCY cycles later with an
//                   address derived payload, destination Icache
//   SRAM model      behavioural copy of icache_data_ram_wrap: a write request
//                   waits until the L2 fill passes by, stores it with ECC, and
//                   echoes the written line back as the fill for the micro-cache;
//                   a read returns the stored line; both answer SRAM_LATENCY
//                   cycles after acceptance
//
// Minion contract, as implemented by the frontend
// -----------------------------------------------
//   A minion pulses f0_req_valid for one cycle; the request is held inside the
//   shared icache until the arbiter grants it, which is reported on
//   f0_req_ready. The response on f4 belongs to the request granted
//   RESP_LATENCY cycles earlier on the same requestor port. On a hit the
//   minion is done. On a miss it sleeps and retries on f5_resp_fill_done. Who
//   retries first is decided by the shared icache, not by the minion.
//
// Scenario
// --------
//   both minions request at once: one is granted first, the other a cycle
//   later; both miss; the miss handler sends the L2 request for the first one
//   fill, fill done: both wake and retry; the first one hits, the second
//   misses again and now its own L2 request goes out
//   fill, fill done: the second one retries and hits
//   two idle cycles after the second grant, esr_prefetch_start asks for
//   lines PREFETCH_FIRST_LINE .. +PREFETCH_EXTRA_LINES (+no_prefetch skips it)
//
// Checks
// ------
//   grant order        minion 0 granted before minion 1, in both rounds
//   response history   first minion: miss, hit     second: miss, miss, hit
//   latencies          every response RESP_LATENCY after its grant,
//                      every L2 fill L2_LATENCY after the L2 request
//   L2 traffic         one line read each for line 0 and line 1, in that order
//   prefetch           esr_prefetch_done falls and rises again, and every
//                      line of the burst was read from L2 exactly once
//
// Run with:  make TB=neigh_shared_icache_tb [PLUSARGS=+no_prefetch]
// //////////////////////////////////////////////////////////////////////////////

`define CLK_HALF_PERIOD 0.5 // timescale units, usually ns

`include "soc.vh"

module neigh_shared_icache_tb ();

  timeunit      1ns;
  timeprecision 1ps;

  // //////////////////////////////////////////////////////////////////////////////
  // Parameters
  // //////////////////////////////////////////////////////////////////////////////
  localparam int unsigned NR_MINIONS     = 8;
  localparam int unsigned NR_REQUESTORS  = 2;
  localparam int unsigned NR_MIN_PER_REQ = NR_MINIONS / NR_REQUESTORS;

  // Minions taking part, ids 0 .. NR_ACTIVE-1, all on requestor 0; minion m
  // fetches line m
  localparam int unsigned NR_ACTIVE      = 2;

  // Cycles from the grant on f0_req_ready to the response on f4
  localparam int unsigned RESP_LATENCY   = 4;
  // Cycles from an accepted L2 line read to the fill response
  localparam int unsigned L2_LATENCY     = 10;
  // Cycles from an accepted SRAM request to its response, as in icache_data_ram_wrap
  localparam int unsigned SRAM_LATENCY   = 4;

  // Prefetch burst: idle cycles after the second grant before the start
  // pulse, first line, and extra lines after it (num_lines + 1 lines in all)
  localparam int unsigned IDLE_BEFORE_PREFETCH = 2;
  localparam int unsigned PREFETCH_FIRST_LINE  = 8;
  localparam int unsigned PREFETCH_EXTRA_LINES = 3; // lines 8, 9, 10, 11
  localparam int unsigned DONE_TIMEOUT         = 2_000;

  // Bounds
  localparam int unsigned MAX_RESPS      = 16;
  localparam int unsigned MAX_WAKEUPS    = 8;
  localparam int unsigned MINION_TIMEOUT = 2_000;
  localparam int unsigned TIMEOUT_CYCLES = 100_000;

  // SRAM region, from AD_SRAM_REGION in shire_defines.vh: paddr[39:12] == 0x0200C.
  // The PMA unit reports SRAM as cacheable and never faults on it.
  localparam logic [`PA_SIZE-1:0] SRAM_BASE = `PA_SIZE'h0200_C000;

  int unsigned errors = 0;

  // //////////////////////////////////////////////////////////////////////////////
  // Clock and reset. Reset is synchronous and active high, matching RST_FF.
  // //////////////////////////////////////////////////////////////////////////////
  logic clock = 1'b1;
  always #(`CLK_HALF_PERIOD) clock = ~clock;

  logic reset = 1'b1;

  function automatic int unsigned cycles_between (input time t0, input time t1);
    cycles_between = int'((t1 - t0) / (2 * `CLK_HALF_PERIOD));
  endfunction

  // //////////////////////////////////////////////////////////////////////////////
  // DUT connections
  // //////////////////////////////////////////////////////////////////////////////
  icache_prefetch_conf_t                          esr_prefetch_conf;
  logic                                           esr_prefetch_start;
  logic                                           esr_prefetch_done;
  esr_icache_err_log_ctl_t                        esr_err_log_ctl;
  logic                                           esr_err_log_sbe;
  logic                                           esr_err_log_dbe;
  icache_err_log_info_t                           esr_err_log_info;
  esr_mprot_t                                     esr_mprot;
  tlb_entry_type                                  esr_vmspagesize;
  logic                                           esr_bypass_icache;
  logic                                           esr_shire_coop_mode;
  logic [NR_MINIONS-1:0]                          f0_req_ready;
  logic [NR_MINIONS-1:0]                          f0_req_valid;
  frontend_icache_req [NR_MINIONS-1:0]            f0_req;
  logic [NR_REQUESTORS-1:0]                       f4_resp_valid;
  logic [NR_REQUESTORS-1:0]                       f4_resp_miss;
  icache_frontend_resp [NR_REQUESTORS-1:0]        f4_resp;
  logic [NR_REQUESTORS-1:0]                       f5_resp_fill_done;
  logic [NR_MINIONS-1:0]                          f0_flush_data;
  logic                                           f0_l2_miss_req_disable_next;
  logic                                           f0_l2_miss_req_ready;
  logic                                           f0_l2_miss_req_valid;
  et_link_nodata_req_info_t                       f0_l2_miss_req;
  logic                                           f0_l2_miss_resp_ready;
  logic                                           f0_l2_miss_resp_valid;
  et_link_rsp_info_t                              f0_l2_miss_resp;
  minion_satp_info [NR_MINIONS-1:0]               satp_info;
  minion_satp_info [NR_MINIONS-1:0]               matp_info;
  logic [NR_MINIONS-1:0]                          tlb_invalidate;
  minion_ptw_req [NR_REQUESTORS-1:0]              ptw_req_data;
  logic [NR_REQUESTORS-1:0]                       ptw_req_valid;
  logic [NR_REQUESTORS-1:0]                       ptw_req_ready;
  logic [NR_REQUESTORS-1:0]                       ptw_invalidate;
  logic [NR_REQUESTORS-1:0]                       ptw_resp_valid;
  minion_ptw_pte [NR_REQUESTORS-1:0]              ptw_resp_data;
  logic                                           icache_f2_sram_req_write;
  logic [`ICACHE_SRAM_ADD_WIDTH-1:0]              icache_f2_sram_req_addr;
  logic                                           icache_f2_sram_req_valid;
  logic                                           icache_f2_sram_req_ready;
  logic [`ICACHE_SRAM_DATA_WIDTH-1:0]             icache_f0_sram_resp_dout;
  logic                                           icache_f0_sram_resp_valid;
  logic                                           icache_f0_sram_resp_ready;
  logic [`ICACHE_NEIGH_APB_ADDR_WIDTH-1:0]        apb_paddr;
  logic                                           apb_pwrite;
  logic                                           apb_psel;
  logic                                           apb_penable;
  logic [`bpam_shire_apb_data_width-1:0]          apb_pwdata;
  logic                                           apb_pready;
  logic [`bpam_shire_apb_data_width-1:0]          apb_prdata;
  logic                                           apb_pslverr;
  icache_dbg_sm_t                                 dbg_sm_signals;

  // //////////////////////////////////////////////////////////////////////////////
  // DUT
  // //////////////////////////////////////////////////////////////////////////////
  neigh_shared_icache #(
    .NR_MINIONS    ( NR_MINIONS    ),
    .NR_REQUESTORS ( NR_REQUESTORS )
  ) dut (
    .clock                       ( clock                       ),
    .reset                       ( reset                       ),
    .esr_prefetch_conf           ( esr_prefetch_conf           ),
    .esr_prefetch_start          ( esr_prefetch_start          ),
    .esr_prefetch_done           ( esr_prefetch_done           ),
    .esr_err_log_ctl             ( esr_err_log_ctl             ),
    .esr_err_log_sbe             ( esr_err_log_sbe             ),
    .esr_err_log_dbe             ( esr_err_log_dbe             ),
    .esr_err_log_info            ( esr_err_log_info            ),
    .esr_mprot                   ( esr_mprot                   ),
    .esr_vmspagesize             ( esr_vmspagesize             ),
    .esr_bypass_icache           ( esr_bypass_icache           ),
    .esr_shire_coop_mode         ( esr_shire_coop_mode         ),
    .f0_req_ready                ( f0_req_ready                ),
    .f0_req_valid                ( f0_req_valid                ),
    .f0_req                      ( f0_req                      ),
    .f4_resp_valid               ( f4_resp_valid               ),
    .f4_resp_miss                ( f4_resp_miss                ),
    .f4_resp                     ( f4_resp                     ),
    .f5_resp_fill_done           ( f5_resp_fill_done           ),
    .f0_flush_data               ( f0_flush_data               ),
    .f0_l2_miss_req_disable_next ( f0_l2_miss_req_disable_next ),
    .f0_l2_miss_req_ready        ( f0_l2_miss_req_ready        ),
    .f0_l2_miss_req_valid        ( f0_l2_miss_req_valid        ),
    .f0_l2_miss_req              ( f0_l2_miss_req              ),
    .f0_l2_miss_resp_ready       ( f0_l2_miss_resp_ready       ),
    .f0_l2_miss_resp_valid       ( f0_l2_miss_resp_valid       ),
    .f0_l2_miss_resp             ( f0_l2_miss_resp             ),
    .satp_info                   ( satp_info                   ),
    .matp_info                   ( matp_info                   ),
    .tlb_invalidate              ( tlb_invalidate              ),
    .ptw_req_data                ( ptw_req_data                ),
    .ptw_req_valid               ( ptw_req_valid               ),
    .ptw_req_ready               ( ptw_req_ready               ),
    .ptw_invalidate              ( ptw_invalidate              ),
    .ptw_resp_valid              ( ptw_resp_valid              ),
    .ptw_resp_data               ( ptw_resp_data               ),
    .icache_f2_sram_req_write    ( icache_f2_sram_req_write    ),
    .icache_f2_sram_req_addr     ( icache_f2_sram_req_addr     ),
    .icache_f2_sram_req_valid    ( icache_f2_sram_req_valid    ),
    .icache_f2_sram_req_ready    ( icache_f2_sram_req_ready    ),
    .icache_f0_sram_resp_dout    ( icache_f0_sram_resp_dout    ),
    .icache_f0_sram_resp_valid   ( icache_f0_sram_resp_valid   ),
    .icache_f0_sram_resp_ready   ( icache_f0_sram_resp_ready   ),
    .apb_paddr                   ( apb_paddr                   ),
    .apb_pwrite                  ( apb_pwrite                  ),
    .apb_psel                    ( apb_psel                    ),
    .apb_penable                 ( apb_penable                 ),
    .apb_pwdata                  ( apb_pwdata                  ),
    .apb_pready                  ( apb_pready                  ),
    .apb_prdata                  ( apb_prdata                  ),
    .apb_pslverr                 ( apb_pslverr                 ),
    .dbg_sm_signals              ( dbg_sm_signals              )
  );

  // //////////////////////////////////////////////////////////////////////////////
  // Address helpers. Bare translation makes PA equal to VA.
  // //////////////////////////////////////////////////////////////////////////////
  function automatic logic [`VA_SIZE_EXT-1:0] line_addr (input int unsigned n);
    line_addr = `VA_SIZE_EXT'(SRAM_BASE) + (`VA_SIZE_EXT'(n) << 6);
  endfunction

  function automatic logic [`PA_SIZE-1:0] line_paddr (input int unsigned n);
    line_paddr = `PA_SIZE'(line_addr(n));
  endfunction

  // //////////////////////////////////////////////////////////////////////////////
  // L2 responder
  // The L1 miss handler holds one request, so at most one read is in flight.
  // The payload is derived from the address so a line is recognisable in the
  // waveform. Destination Icache is what the SRAM wrapper filters on.
  // //////////////////////////////////////////////////////////////////////////////
  logic [L2_LATENCY-1:0]   l2_pipe;
  logic [`PA_SIZE-1:0]     l2_addr_q;
  logic [`PA_SIZE-1:0]     l2_req_addr_hist [0:MAX_RESPS-1];
  int unsigned             l2_req_count  = 0;
  int unsigned             l2_resp_count = 0;
  time                     l2_req_time   = 0;

  assign f0_l2_miss_req_ready        = 1'b1;
  assign f0_l2_miss_req_disable_next = 1'b0;

  always_ff @(posedge clock) begin
    if (reset) begin
      l2_pipe   <= '0;
      l2_addr_q <= '0;
    end else begin
      l2_pipe <= l2_pipe >> 1;
      if (f0_l2_miss_req_valid && f0_l2_miss_req_ready) begin
        l2_pipe[L2_LATENCY-1] <= 1'b1;
        l2_addr_q             <= f0_l2_miss_req.address;
        l2_req_time           <= $time;
        if (l2_req_count < MAX_RESPS) l2_req_addr_hist[l2_req_count] <= f0_l2_miss_req.address;
        l2_req_count          <= l2_req_count + 1;
        $display("INFO  %0t L2 line read #%0d for PA 0x%0h (opcode %s)", $time, l2_req_count,
                 f0_l2_miss_req.address, f0_l2_miss_req.opcode.name());
      end
      if (f0_l2_miss_resp_valid) begin
        l2_resp_count <= l2_resp_count + 1;
        if (cycles_between(l2_req_time, $time) == L2_LATENCY)
          $display("PASS  %0t L2 fill for PA 0x%0h delivered %0d cycles after the request",
                   $time, l2_addr_q, L2_LATENCY);
        else begin
          errors++;
          $display("ERROR %0t L2 fill for PA 0x%0h delivered after %0d cycles, expected %0d",
                   $time, l2_addr_q, cycles_between(l2_req_time, $time), L2_LATENCY);
        end
      end
    end
  end

  assign f0_l2_miss_resp_valid = l2_pipe[0];

  always_comb begin
    f0_l2_miss_resp        = '0;
    f0_l2_miss_resp.dest   = ($bits(f0_l2_miss_resp.dest))'(ET_LINK_NEIGH_SRC_Icache);
    f0_l2_miss_resp.wdata  = 1'b1;
    f0_l2_miss_resp.opcode = ET_LINK_RSP_AckData;
    f0_l2_miss_resp.size   = ET_LINK_Line;
    for (int unsigned w = 0; w < (`ET_LINE_DATA_SIZE/64); w++)
      f0_l2_miss_resp.data[w*64 +: 64] = {l2_addr_q[31:0], w[15:0], 16'hFACE};
  end

  // //////////////////////////////////////////////////////////////////////////////
  // L1 data SRAM model, after icache_data_ram_wrap
  // Stage s1 holds the accepted request. A write stays there until the L2 fill
  // has been seen, then the line is stored with ECC and echoed back. The
  // remaining stages only add the pipeline depth of the real wrapper.
  // //////////////////////////////////////////////////////////////////////////////
  localparam int unsigned SRAM_DEPTH = 1 << `ICACHE_SRAM_ADD_WIDTH;
  localparam int unsigned ECC_BLOCKS = `ICACHE_ECC_BLOCKS;

  logic [`ICACHE_SRAM_DATA_WIDTH-1:0] sram_mem [0:SRAM_DEPTH-1];

  // Fill line captured from the L2 response, and its ECC
  logic [`ET_LINE_DATA_SIZE-1:0]  fill_line_q;
  logic [ECC_BLOCKS-1:0][7:0]     fill_ecc;
  logic [`ICACHE_SRAM_DATA_WIDTH-1:0] fill_word;
  logic                           fill_seen;

  for (genvar b = 0; b < ECC_BLOCKS; b++) begin : FILL_ECC
    logic [71:0] data_and_ecc;
    ecc_gen #(.DATA_SIZE(64)) gen (
      .data         ( fill_line_q[b*64 +: 64] ),
      .data_and_ecc ( data_and_ecc            )
    );
    assign fill_ecc[b] = data_and_ecc[71:64];
  end

  // Memory word layout per panel i: {ecc of its two 64-bit blocks, 128 data bits}
  always_comb begin
    for (int unsigned i = 0; i < `ICACHE_NR_MEMS_PER_ROW; i++)
      fill_word[i*`ICACHE_MEM_WIDTH +: `ICACHE_MEM_WIDTH] =
        {fill_ecc[2*i+1], fill_ecc[2*i], fill_line_q[i*`ICACHE_MEM_USED_BITS +: `ICACHE_MEM_USED_BITS]};
  end

  logic                                s1_valid, s1_write;
  logic [`ICACHE_SRAM_ADD_WIDTH-1:0]   s1_addr;
  logic                                s1_waiting, s1_leave;
  logic [SRAM_LATENCY-2:0]             sp_valid;
  logic [`ICACHE_SRAM_DATA_WIDTH-1:0]  sp_data [0:SRAM_LATENCY-2];

  assign s1_waiting = s1_valid && s1_write && !fill_seen;
  assign s1_leave   = s1_valid && !s1_waiting;
  assign icache_f2_sram_req_ready = !s1_valid || s1_leave;

  always_ff @(posedge clock) begin
    if (reset) begin
      s1_valid    <= 1'b0;
      s1_write    <= 1'b0;
      s1_addr     <= '0;
      fill_seen   <= 1'b0;
      fill_line_q <= '0;
      sp_valid    <= '0;
    end else begin
      // Accept into s1
      if (icache_f2_sram_req_valid && icache_f2_sram_req_ready) begin
        s1_valid <= 1'b1;
        s1_write <= icache_f2_sram_req_write;
        s1_addr  <= icache_f2_sram_req_addr;
        $display("INFO  %0t SRAM %s request accepted, addr 0x%0h", $time,
                 icache_f2_sram_req_write ? "write" : "read", icache_f2_sram_req_addr);
      end else if (s1_leave)
        s1_valid <= 1'b0;

      // Spy on the L2 fill, as the wrapper does one cycle after the response
      if (f0_l2_miss_resp_valid) begin
        fill_seen   <= 1'b1;
        fill_line_q <= f0_l2_miss_resp.data;
      end else if (s1_leave && s1_write)
        fill_seen <= 1'b0;

      // Access
      sp_valid <= {sp_valid[SRAM_LATENCY-3:0], s1_leave};
      if (s1_leave) begin
        if (s1_write) begin
          sram_mem[s1_addr] <= fill_word;
          sp_data[0]        <= fill_word;
          $display("INFO  %0t SRAM write of the L2 fill at addr 0x%0h, line 0x%0h...", $time,
                   s1_addr, fill_line_q[63:0]);
        end else
          sp_data[0] <= sram_mem[s1_addr];
      end
      for (int unsigned k = 1; k < SRAM_LATENCY-1; k++) sp_data[k] <= sp_data[k-1];
    end
  end

  assign icache_f0_sram_resp_valid = sp_valid[SRAM_LATENCY-2];
  assign icache_f0_sram_resp_dout  = sp_data[SRAM_LATENCY-2];

  // //////////////////////////////////////////////////////////////////////////////
  // Page table walker: bare mode never walks. Report any request, never answer.
  // //////////////////////////////////////////////////////////////////////////////
  assign ptw_req_ready  = '1;
  assign ptw_resp_valid = '0;
  assign ptw_resp_data  = '0;

  always_ff @(posedge clock)
    for (int unsigned r = 0; r < NR_REQUESTORS; r++)
      if (!reset && ptw_req_valid[r]) begin
        errors++;
        $display("ERROR %0t unexpected PTW walk on requestor %0d for VA 0x%0h", $time, r, ptw_req_data[r].addr);
      end

  // //////////////////////////////////////////////////////////////////////////////
  // Static configuration
  // //////////////////////////////////////////////////////////////////////////////
  initial begin
    esr_prefetch_conf   = '0;
    esr_prefetch_start  = 1'b0;
    esr_err_log_ctl     = '0;
    esr_mprot           = '0;
    esr_vmspagesize     = tlb_entry_type_4K;
    esr_bypass_icache   = 1'b0;
    esr_shire_coop_mode = 1'b0;
    f0_flush_data       = '0;
    tlb_invalidate      = '0;
    apb_paddr           = '0;
    apb_pwrite          = 1'b0;
    apb_psel            = 1'b0;
    apb_penable         = 1'b0;
    apb_pwdata          = '0;

    for (int unsigned m = 0; m < NR_MINIONS; m++) begin
      satp_info[m].mode = `CSR_SATP_MODE_BARE;
      satp_info[m].ppn  = '0;
      matp_info[m].mode = `CSR_SATP_MODE_BARE;
      matp_info[m].ppn  = '0;
    end

    $timeformat(-9, 0, " ns", 12);
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Minion model
  // //////////////////////////////////////////////////////////////////////////////
  typedef enum logic [2:0] {
    Minion_Idle,       // waiting for the test to kick it
    Minion_Request,    // pulses f0_req_valid for one cycle
    Minion_Wait_Grant, // request held in the shared icache, waiting for f0_req_ready
    Minion_Wait_Resp,  // granted, response due RESP_LATENCY later
    Minion_Sleep,      // got a miss, wakes on f5_resp_fill_done
    Minion_Done        // got a hit
  } minion_state_t;

  minion_state_t m_state      [0:NR_ACTIVE-1];
  logic          m_kick       [0:NR_ACTIVE-1];
  int unsigned   m_line       [0:NR_ACTIVE-1];
  time           m_grant_time [0:NR_ACTIVE-1];
  int unsigned   m_resp_count [0:NR_ACTIVE-1];
  bit            m_resp_miss  [0:NR_ACTIVE-1][0:MAX_RESPS-1];
  int unsigned   m_wakeups    [0:NR_ACTIVE-1];

  // Requestor port a minion belongs to
  function automatic int unsigned req_of (input int unsigned m);
    req_of = m / NR_MIN_PER_REQ;
  endfunction

  // Granted requests in flight per requestor, oldest first. The pipeline is in
  // order and prefetch responses never reach f4, so the oldest granted minion
  // owns the next response on its port.
  int unsigned inflight_id   [0:NR_REQUESTORS-1][0:MAX_RESPS-1];
  int unsigned inflight_head [0:NR_REQUESTORS-1];
  int unsigned inflight_tail [0:NR_REQUESTORS-1];

  // Grant order, overall and after wake-ups
  int unsigned grant_order [0:MAX_RESPS-1];
  int unsigned grant_count = 0;
  int unsigned retry_order [0:MAX_RESPS-1];
  int unsigned retry_count = 0;
  int unsigned fill_done_count = 0;

  // Request port: one cycle pulse per request
  always_comb begin
    f0_req_valid = '0;
    f0_req       = '0;
    for (int unsigned m = 0; m < NR_ACTIVE; m++) begin
      if (m_state[m] == Minion_Request) begin
        f0_req_valid[m]         = 1'b1;
        f0_req[m].thread_id     = '0;
        f0_req[m].vm_status.prv = 2'b11; // machine mode
        f0_req[m].addr          = ($bits(f0_req[m].addr))'(line_addr(m_line[m]));
      end
    end
  end

  always_ff @(posedge clock) begin
    int unsigned id;
    int unsigned r;
    string       tag;
    if (reset) begin
      for (int unsigned m = 0; m < NR_ACTIVE; m++) begin
        m_state[m]      <= Minion_Idle;
        m_line[m]       <= m;
        m_resp_count[m] <= 0;
        m_wakeups[m]    <= 0;
        m_grant_time[m] <= 0;
      end
      for (int unsigned q = 0; q < NR_REQUESTORS; q++) begin
        inflight_head[q] <= 0;
        inflight_tail[q] <= 0;
      end
      grant_count     <= 0;
      retry_count     <= 0;
      fill_done_count <= 0;
    end else begin
      // Responses, per requestor port
      for (int unsigned q = 0; q < NR_REQUESTORS; q++) begin
        if (f4_resp_valid[q]) begin
          if (inflight_head[q] == inflight_tail[q]) begin
            errors++;
            $display("ERROR %0t response on requestor %0d with nothing granted", $time, q);
          end else begin
            id = inflight_id[q][inflight_head[q] % MAX_RESPS];
            inflight_head[q] <= inflight_head[q] + 1;
            if (m_resp_count[id] < MAX_RESPS) m_resp_miss[id][m_resp_count[id]] <= f4_resp_miss[q];
            m_resp_count[id] <= m_resp_count[id] + 1;
            if (cycles_between(m_grant_time[id], $time) != RESP_LATENCY) begin
              errors++;
              $display("ERROR %0t minion %0d response %0d cycles after its grant, expected %0d",
                       $time, id, cycles_between(m_grant_time[id], $time), RESP_LATENCY);
            end
            if (f4_resp_miss[q]) begin
              m_state[id] <= Minion_Sleep;
              $display("INFO  %0t minion %0d response #%0d: MISS, %0d cycles after grant, going to sleep",
                       $time, id, m_resp_count[id], cycles_between(m_grant_time[id], $time));
            end else begin
              m_state[id] <= Minion_Done;
              $display("INFO  %0t minion %0d response #%0d: HIT, %0d cycles after grant, done",
                       $time, id, m_resp_count[id], cycles_between(m_grant_time[id], $time));
            end
          end
        end
        if (f5_resp_fill_done[q]) begin
          fill_done_count <= fill_done_count + 1;
          $display("INFO  %0t f5_resp_fill_done on requestor %0d, sleeping minions wake up", $time, q);
        end
      end

      for (int unsigned m = 0; m < NR_ACTIVE; m++) begin
        r = req_of(m);
        case (m_state[m])
          Minion_Idle:
            if (m_kick[m]) m_state[m] <= Minion_Request;

          Minion_Request: begin
            tag = (m_wakeups[m] > 0) ? ", retry" : "";
            $display("INFO  %0t minion %0d requests line %0d (VA 0x%0h)%s", $time, m, m_line[m], f0_req[m].addr, tag);
            m_state[m] <= Minion_Wait_Grant;
          end

          Minion_Wait_Grant:
            if (f0_req_ready[m]) begin
              inflight_id[r][inflight_tail[r] % MAX_RESPS] <= m;
              inflight_tail[r] <= inflight_tail[r] + 1;
              m_grant_time[m]  <= $time;
              m_state[m]       <= Minion_Wait_Resp;
              if (grant_count < MAX_RESPS) grant_order[grant_count] <= m;
              grant_count <= grant_count + 1;
              if (m_wakeups[m] > 0) begin
                if (retry_count < MAX_RESPS) retry_order[retry_count] <= m;
                retry_count <= retry_count + 1;
              end
              $display("INFO  %0t minion %0d granted (grant #%0d)", $time, m, grant_count);
            end

          Minion_Wait_Resp: ; // handled by the response block

          Minion_Sleep:
            if (f5_resp_fill_done[r]) begin
              m_wakeups[m] <= m_wakeups[m] + 1;
              m_state[m]   <= Minion_Request;
              $display("INFO  %0t minion %0d wakes up", $time, m);
              if (m_wakeups[m] + 1 > MAX_WAKEUPS) begin
                errors++;
                $display("ERROR %0t minion %0d woke up %0d times without a hit", $time, m, m_wakeups[m] + 1);
                m_state[m] <= Minion_Done;
              end
            end

          default: ;
        endcase
      end
    end
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Prefetch stimulus and monitor
  // //////////////////////////////////////////////////////////////////////////////
  task automatic prefetch_start (input int unsigned line_n, input int unsigned num_lines);
    begin
      esr_prefetch_conf            = '0;
      esr_prefetch_conf.prv        = `CSR_PRV_M;
      esr_prefetch_conf.start_addr = ($bits(esr_prefetch_conf.start_addr))'(line_addr(line_n) >> 6);
      esr_prefetch_conf.num_lines  = num_lines[5:0];
      esr_prefetch_start           = 1'b1;
      $display("INFO  %0t esr_prefetch_start for lines %0d to %0d (%0d line(s))",
               $time, line_n, line_n + num_lines, num_lines + 1);
      @(posedge clock);
      esr_prefetch_start           = 1'b0;
    end
  endtask

  // esr_prefetch_done resets to 1 and a start pulse holds it at 1 for one more
  // cycle, so a burst is only complete once done has been seen low (the FSM
  // reached Request) and high again afterwards.
  bit prefetch_done_fell = 1'b0;
  bit prefetch_done_rose = 1'b0;

  always_ff @(posedge clock) begin
    if (!reset) begin
      if (!esr_prefetch_done) prefetch_done_fell <= 1'b1;
      if (prefetch_done_fell && esr_prefetch_done) prefetch_done_rose <= 1'b1;
    end
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Internal state monitor, L1 miss FSM and L0 micro-cache FSMs
  // //////////////////////////////////////////////////////////////////////////////
  always_ff @(posedge clock) begin
    if (!reset) begin
      if (dut.icache.UCACHE[0].micro_cache.f0_prefetch_state != dut.icache.UCACHE[0].micro_cache.f0_prefetch_state_next)
        $display("INFO  %0t L0 prefetch FSM %s -> %s", $time,
                 dut.icache.UCACHE[0].micro_cache.f0_prefetch_state.name(),
                 dut.icache.UCACHE[0].micro_cache.f0_prefetch_state_next.name());
      if (dut.icache.f0_miss_state != dut.icache.f0_miss_state_next)
        $display("INFO  %0t L1 miss FSM %s -> %s", $time,
                 dut.icache.f0_miss_state.name(), dut.icache.f0_miss_state_next.name());
      if (dut.icache.UCACHE[0].micro_cache.f0_miss_state != dut.icache.UCACHE[0].micro_cache.f0_miss_state_next)
        $display("INFO  %0t L0 miss FSM %s -> %s", $time,
                 dut.icache.UCACHE[0].micro_cache.f0_miss_state.name(), dut.icache.UCACHE[0].micro_cache.f0_miss_state_next.name());
      if (dut.icache.UCACHE[0].micro_cache.f0_prefetch_miss_nomh_state != dut.icache.UCACHE[0].micro_cache.f0_prefetch_miss_nomh_state_next)
        $display("INFO  %0t L0 nomh FSM %s -> %s", $time,
                 dut.icache.UCACHE[0].micro_cache.f0_prefetch_miss_nomh_state.name(),
                 dut.icache.UCACHE[0].micro_cache.f0_prefetch_miss_nomh_state_next.name());
    end
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Checks
  // //////////////////////////////////////////////////////////////////////////////
  function automatic string hist_str (input int unsigned m);
    hist_str = "";
    for (int unsigned k = 0; (k < m_resp_count[m]) && (k < MAX_RESPS); k++)
      hist_str = {hist_str, (k > 0) ? ", " : "", m_resp_miss[m][k] ? "miss" : "hit"};
  endfunction

  task automatic check_history (input int unsigned m, input bit expected [], input string expected_str);
    bit ok;
    begin
      ok = (m_resp_count[m] == expected.size());
      for (int unsigned k = 0; ok && (k < expected.size()); k++)
        ok = (m_resp_miss[m][k] == expected[k]);
      if (ok)
        $display("PASS  %0t minion %0d responses: %s", $time, m, hist_str(m));
      else begin
        errors++;
        $display("ERROR %0t minion %0d responses: %s, expected %s", $time, m, hist_str(m), expected_str);
      end
    end
  endtask

  task automatic check_flow ();
    int unsigned guard;
    bit all_done;
    begin
      guard = 0;
      all_done = 1'b0;
      while (!all_done && (guard < MINION_TIMEOUT)) begin
        @(posedge clock);
        guard++;
        all_done = 1'b1;
        for (int unsigned m = 0; m < NR_ACTIVE; m++)
          all_done &= (m_state[m] == Minion_Done);
      end
      if (!all_done) begin
        errors++;
        for (int unsigned m = 0; m < NR_ACTIVE; m++)
          $display("ERROR %0t minion %0d is in %s after %0d cycles, responses: %s",
                   $time, m, m_state[m].name(), MINION_TIMEOUT, hist_str(m));
        return;
      end

      // Grant order: minion 0 first in the initial round and after the first fill done
      if ((grant_count >= 2) && (grant_order[0] == 0) && (grant_order[1] == 1))
        $display("PASS  %0t initial grants: minion 0 then minion 1", $time);
      else begin
        errors++;
        $display("ERROR %0t initial grants: %0d then %0d, expected 0 then 1", $time, grant_order[0], grant_order[1]);
      end
      if ((retry_count >= 2) && (retry_order[0] == 0) && (retry_order[1] == 1))
        $display("PASS  %0t retry grants after the first fill done: minion 0 then minion 1", $time);
      else begin
        errors++;
        $display("ERROR %0t retry grants: %0d retries, first two %0d then %0d, expected 0 then 1",
                 $time, retry_count, retry_order[0], retry_order[1]);
      end

      check_history(0, '{1'b1, 1'b0},       "miss, hit");
      check_history(1, '{1'b1, 1'b1, 1'b0}, "miss, miss, hit");

      // L2 traffic: one line read per minion, line 0 before line 1. Prefetch
      // reads may be interleaved, so only order and multiplicity are checked.
      if ((l2_reads_of(line_paddr(0)) == 1) && (l2_reads_of(line_paddr(1)) == 1)
          && (l2_first_read_of(line_paddr(0)) < l2_first_read_of(line_paddr(1))))
        $display("PASS  %0t one L2 line read each for line 0 and line 1, in that order", $time);
      else begin
        errors++;
        $display("ERROR %0t L2 reads: line 0 read %0d time(s), line 1 read %0d time(s), %0d reads in all",
                 $time, l2_reads_of(line_paddr(0)), l2_reads_of(line_paddr(1)), l2_req_count);
      end
      if (fill_done_count < 2) begin
        errors++;
        $display("ERROR %0t only %0d fill done pulses, expected at least 2", $time, fill_done_count);
      end
    end
  endtask

  // Number of L2 reads of a line, and the index of its first read
  function automatic int unsigned l2_reads_of (input logic [`PA_SIZE-1:0] pa);
    l2_reads_of = 0;
    for (int unsigned k = 0; (k < l2_req_count) && (k < MAX_RESPS); k++)
      if (l2_req_addr_hist[k] == pa) l2_reads_of++;
  endfunction

  function automatic int unsigned l2_first_read_of (input logic [`PA_SIZE-1:0] pa);
    l2_first_read_of = MAX_RESPS;
    for (int unsigned k = 0; (k < l2_req_count) && (k < MAX_RESPS); k++)
      if ((l2_req_addr_hist[k] == pa) && (l2_first_read_of == MAX_RESPS)) l2_first_read_of = k;
  endfunction

  // The burst is complete when done rose again and every line was read from
  // L2 exactly once. Lines already fetched report how far the FSM got.
  task automatic check_prefetch ();
    int unsigned guard;
    int unsigned fetched;
    begin
      guard = 0;
      while (!prefetch_done_rose && (guard < DONE_TIMEOUT)) begin
        @(posedge clock);
        guard++;
      end
      fetched = 0;
      for (int unsigned n = 0; n <= PREFETCH_EXTRA_LINES; n++)
        if (l2_reads_of(line_paddr(PREFETCH_FIRST_LINE + n)) == 1) fetched++;

      if (!prefetch_done_fell) begin
        errors++;
        $display("ERROR %0t esr_prefetch_done never fell, the prefetch FSM never reached Request (state %s)",
                 $time, dut.icache.UCACHE[0].micro_cache.f0_prefetch_state.name());
      end else if (!prefetch_done_rose) begin
        errors++;
        $display("ERROR %0t prefetch not completed: esr_prefetch_done still low %0d cycles after start, FSM parked in %s, %0d of %0d lines read from L2",
                 $time, DONE_TIMEOUT, dut.icache.UCACHE[0].micro_cache.f0_prefetch_state.name(),
                 fetched, PREFETCH_EXTRA_LINES + 1);
      end else if (fetched != PREFETCH_EXTRA_LINES + 1) begin
        errors++;
        $display("ERROR %0t esr_prefetch_done rose but only %0d of %0d prefetch lines were read from L2",
                 $time, fetched, PREFETCH_EXTRA_LINES + 1);
      end else
        $display("PASS  %0t prefetch completed: esr_prefetch_done rose again, all %0d lines read from L2",
                 $time, PREFETCH_EXTRA_LINES + 1);

      if (l2_resp_count != l2_req_count) begin
        errors++;
        $display("ERROR %0t %0d L2 reads but %0d fills", $time, l2_req_count, l2_resp_count);
      end
    end
  endtask

  // //////////////////////////////////////////////////////////////////////////////
  // Main
  // //////////////////////////////////////////////////////////////////////////////
  bit use_prefetch;

  initial begin
    use_prefetch = !$test$plusargs("no_prefetch");
    for (int unsigned m = 0; m < NR_ACTIVE; m++) m_kick[m] = 1'b0;

    if (use_prefetch)
      $display("\nstarting neigh_shared_icache test: two minions miss, sleep and retry, then a prefetch");
    else
      $display("\nstarting neigh_shared_icache test: two minions miss, sleep and retry, no prefetch");

    reset = 1'b1;
    repeat (8) @(posedge clock);
    reset = 1'b0;
    repeat (8) @(posedge clock);

    // Both minions request in the same cycle; the shared icache serialises them
    for (int unsigned m = 0; m < NR_ACTIVE; m++) m_kick[m] = 1'b1;

    if (use_prefetch) begin
      // Start pulse two idle cycles after the second grant
      while (grant_count < NR_ACTIVE) @(posedge clock);
      repeat (IDLE_BEFORE_PREFETCH) @(posedge clock);
      prefetch_start(PREFETCH_FIRST_LINE, PREFETCH_EXTRA_LINES);
    end

    check_flow();
    if (use_prefetch) check_prefetch();

    repeat (50) @(posedge clock);

    $display("\n================================================");
    if (errors == 0)
      $display("TEST PASSED");
    else
      $display("TEST FAILED, %0d error(s)", errors);
    $display("================================================\n");
    $finish;
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Watchdog
  // //////////////////////////////////////////////////////////////////////////////
  int cycle_count;

  initial begin
    cycle_count = 0;
    @(negedge reset);
    forever begin
      @(posedge clock);
      cycle_count++;
      if (cycle_count == TIMEOUT_CYCLES) begin
        $display("ERROR %0t watchdog: %0d cycles elapsed without finishing", $time, TIMEOUT_CYCLES);
        $display("TEST FAILED, watchdog");
        $finish;
      end
    end
  end

endmodule
