// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// vim: se syn=systemverilog:

// //////////////////////////////////////////////////////////////////////////////
// Simple directed test for the L0 micro-cache with a behavioural minion model.
//
// Minion contract, as implemented by the frontend
// -----------------------------------------------
//   A minion drives one fetch request and receives its response on f4,
//   RESP_LATENCY cycles later. On a hit it is done. On a miss it goes to sleep
//   and wakes up on f5_resp_fill_done, then retries the same line. When several
//   minions wake together the lowest id goes first, so minion 0 retries the
//   cycle after fill done and minion 1 the cycle after that.
//
// Scenario
// --------
//   t0      minion 0 and minion 1 both want line 0 and line 1 respectively;
//           minion 0 wins the port, minion 1 follows one cycle later
//   t0+4    minion 0 miss response, it sleeps; the L1 request for line 0 is out
//   t0+5    minion 1 miss response, it sleeps; the miss handler was busy so this
//           miss is dropped (nomh FSM -> FillDone_Wait)
//   +2 idle esr_prefetch_start for lines 8 to 8+PREFETCH_EXTRA_LINES
//   +L1     fill for line 0 arrives L1_LATENCY cycles after the request,
//           f5_resp_fill_done wakes both minions
//           minion 0 retries first and hits after 4 cycles
//           minion 1 retries next, misses, and this time its L1 request goes out
//   +L1     fill for line 1, fill done, minion 1 retries and hits
//
// Checks
// ------
//   response history   minion 0: miss, hit        minion 1: miss, miss, hit
//   retry order        minion 0 before minion 1 after the first fill done
//   latencies          every response RESP_LATENCY after its request,
//                      every fill L1_LATENCY after the L1 request
//   L1 traffic         first two L1 requests are line 0 then line 1
//   prefetch           esr_prefetch_done falls and rises again (+no_prefetch
//                      skips the start pulse and this check)
//
// Run with:  make TB=icache_micro_cache_simple_tb [PLUSARGS=+no_prefetch]
// //////////////////////////////////////////////////////////////////////////////

`define CLK_HALF_PERIOD 0.5 // timescale units, usually ns

`include "soc.vh"

module icache_micro_cache_simple_tb ();

  timeunit      1ns;
  timeprecision 1ps;

  // //////////////////////////////////////////////////////////////////////////////
  // Parameters
  // //////////////////////////////////////////////////////////////////////////////
  localparam int unsigned NR_MINIONS   = 8;
  localparam int unsigned NR_MINIONS_L = $clog2(NR_MINIONS);

  // Minions taking part in the test, ids 0 .. NR_ACTIVE-1, minion m fetches line m
  localparam int unsigned NR_ACTIVE    = 2;

  // Cycles from a fetch request on f0 to its response on f4
  localparam int unsigned RESP_LATENCY = 4;

  // Cycles from an accepted L1 miss request to the fill response delivered
  // back to the micro-cache
  localparam int unsigned L1_LATENCY   = 10;
  localparam int unsigned PTW_LATENCY  = 8;

  // Idle cycles between the second minion request and the prefetch start
  localparam int unsigned IDLE_BEFORE_PREFETCH = 2;

  // First line of the prefetch burst and the number of lines after it.
  // esr_prefetch_conf.num_lines counts the extra lines: the FSM loads it, and
  // in Fill_Wait it finishes when the count is zero or decrements and steps to
  // the next line. A burst therefore fetches num_lines + 1 lines.
  localparam int unsigned PREFETCH_FIRST_LINE  = 8;
  localparam int unsigned PREFETCH_EXTRA_LINES = 3; // lines 8, 9, 10, 11

  // Bounds
  localparam int unsigned MAX_RESPS      = 16;    // responses recorded per minion
  localparam int unsigned MAX_WAKEUPS    = 8;     // a minion sleeping more often than this is stuck
  localparam int unsigned MINION_TIMEOUT = 1_000; // cycles for both minions to reach Done
  localparam int unsigned DONE_TIMEOUT   = 2_000; // cycles for the prefetch burst to finish
  localparam int unsigned TIMEOUT_CYCLES = 100_000;

  // SRAM region, from AD_SRAM_REGION in shire_defines.vh: paddr[39:12] == 0x0200C.
  // The PMA unit reports SRAM as cacheable and never faults on it, so no
  // esr_mprot or privilege setup is needed.
  localparam logic [`PA_SIZE-1:0] SRAM_BASE = `PA_SIZE'h0200_C000;

  int unsigned errors = 0;

  // //////////////////////////////////////////////////////////////////////////////
  // Clock and reset. Reset is synchronous and active high, matching RST_FF.
  // //////////////////////////////////////////////////////////////////////////////
  logic clock = 1'b1;
  always #(`CLK_HALF_PERIOD) clock = ~clock;

  logic reset = 1'b1;

  // Elapsed cycles between two time stamps
  function automatic int unsigned cycles_between (input time t0, input time t1);
    cycles_between = int'((t1 - t0) / (2 * `CLK_HALF_PERIOD));
  endfunction

  // //////////////////////////////////////////////////////////////////////////////
  // DUT connections
  // //////////////////////////////////////////////////////////////////////////////
  icache_prefetch_conf_t                    esr_prefetch_conf;
  logic                                     esr_prefetch_start;
  logic                                     esr_prefetch_done;
  esr_mprot_t                               esr_mprot;
  tlb_entry_type                            esr_vmspagesize;
  logic                                     esr_bypass_icache;
  logic                                     esr_shire_coop_mode;
  logic                                     f0_req_ready;
  logic                                     f0_req_valid;
  frontend_icache_req                       f0_req;
  logic [NR_MINIONS_L-1:0]                  f0_req_min_id;
  logic                                     f4_resp_valid;
  logic                                     f4_resp_miss;
  icache_frontend_resp                      f4_resp;
  logic                                     f5_resp_fill_done;
  logic                                     f0_flush_data;
  logic                                     f0_l1_miss_req_ready;
  logic                                     f0_l1_miss_req_valid;
  logic [`PA_RANGE]                         f0_l1_miss_req_addr;
  logic                                     f0_l1_miss_resp_early_valid;
  logic                                     f0_l1_miss_resp_valid;
  logic [`ICACHE_BLOCK_BITS-1:0]            f0_l1_miss_resp_data;
  logic                                     f0_l1_miss_resp_ecc_err;
  logic                                     f0_l1_miss_resp_l2_err;
  minion_satp_info [NR_MINIONS-1:0]         satp_info;
  minion_satp_info [NR_MINIONS-1:0]         matp_info;
  logic [NR_MINIONS-1:0]                    tlb_invalidate;
  minion_ptw_req                            ptw_req_data;
  logic                                     ptw_req_valid;
  logic                                     ptw_req_ready;
  logic                                     ptw_invalidate;
  logic                                     ptw_resp_valid;
  minion_ptw_pte                            ptw_resp_data;
  logic [`ICACHE_DBG_UCACHE_ADDR_WIDTH-1:0] apb_paddr;
  logic                                     apb_pwrite;
  logic                                     apb_psel;
  logic                                     apb_penable;
  logic [`bpam_shire_apb_data_width-1:0]    apb_pwdata;
  logic                                     apb_pready;
  logic [`bpam_shire_apb_data_width-1:0]    apb_prdata;
  logic                                     apb_pslverr;
  icache_dbg_sm_t                           dbg_sm_signals;

  // //////////////////////////////////////////////////////////////////////////////
  // DUT
  // //////////////////////////////////////////////////////////////////////////////
  icache_micro_cache #(
    .ID         ( 0          ),
    .NR_MINIONS ( NR_MINIONS )
  ) dut (
    .clock                       ( clock                       ),
    .reset                       ( reset                       ),
    .esr_prefetch_conf           ( esr_prefetch_conf           ),
    .esr_prefetch_start          ( esr_prefetch_start          ),
    .esr_prefetch_done           ( esr_prefetch_done           ),
    .esr_mprot                   ( esr_mprot                   ),
    .esr_vmspagesize             ( esr_vmspagesize             ),
    .esr_bypass_icache           ( esr_bypass_icache           ),
    .esr_shire_coop_mode         ( esr_shire_coop_mode         ),
    .f0_req_ready                ( f0_req_ready                ),
    .f0_req_valid                ( f0_req_valid                ),
    .f0_req                      ( f0_req                      ),
    .f0_req_min_id               ( f0_req_min_id               ),
    .f4_resp_valid               ( f4_resp_valid               ),
    .f4_resp_miss                ( f4_resp_miss                ),
    .f4_resp                     ( f4_resp                     ),
    .f5_resp_fill_done           ( f5_resp_fill_done           ),
    .f0_flush_data               ( f0_flush_data               ),
    .f0_l1_miss_req_ready        ( f0_l1_miss_req_ready        ),
    .f0_l1_miss_req_valid        ( f0_l1_miss_req_valid        ),
    .f0_l1_miss_req_addr         ( f0_l1_miss_req_addr         ),
    .f0_l1_miss_resp_early_valid ( f0_l1_miss_resp_early_valid ),
    .f0_l1_miss_resp_valid       ( f0_l1_miss_resp_valid       ),
    .f0_l1_miss_resp_data        ( f0_l1_miss_resp_data        ),
    .f0_l1_miss_resp_ecc_err     ( f0_l1_miss_resp_ecc_err     ),
    .f0_l1_miss_resp_l2_err      ( f0_l1_miss_resp_l2_err      ),
    .satp_info                   ( satp_info                   ),
    .matp_info                   ( matp_info                   ),
    .tlb_invalidate              ( tlb_invalidate              ),
    .ptw_req_data                ( ptw_req_data                ),
    .ptw_req_valid               ( ptw_req_valid               ),
    .ptw_req_ready               ( ptw_req_ready               ),
    .ptw_invalidate              ( ptw_invalidate              ),
    .ptw_resp_valid              ( ptw_resp_valid              ),
    .ptw_resp_data               ( ptw_resp_data               ),
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
  // Address helpers
  // Bare translation makes the physical address identical to the virtual one,
  // so every test address lands inside the SRAM region.
  // //////////////////////////////////////////////////////////////////////////////
  function automatic logic [`VA_SIZE_EXT-1:0] line_addr (input int unsigned n);
    line_addr = `VA_SIZE_EXT'(SRAM_BASE) + (`VA_SIZE_EXT'(n) << 6);
  endfunction

  function automatic logic [`PA_RANGE] line_paddr (input int unsigned n);
    line_paddr = ($bits(f0_l1_miss_req_addr))'(line_addr(n));
  endfunction

  // //////////////////////////////////////////////////////////////////////////////
  // L1 responder
  // early_valid runs exactly one cycle ahead of valid, which is how icache_top
  // drives the pair. The miss handler is single entry, so at most one request
  // is outstanding. A request sampled on edge n raises resp_valid for the cycle
  // sampled on edge n + L1_LATENCY.
  // //////////////////////////////////////////////////////////////////////////////
  logic [L1_LATENCY-1:0] l1_pipe;
  logic [`PA_RANGE]      l1_addr_q;

  assign f0_l1_miss_req_ready = 1'b1;

  always_ff @(posedge clock) begin
    if (reset) begin
      l1_pipe   <= '0;
      l1_addr_q <= '0;
    end else begin
      l1_pipe <= l1_pipe >> 1;
      if (f0_l1_miss_req_valid && f0_l1_miss_req_ready) begin
        l1_pipe[L1_LATENCY-1] <= 1'b1;
        l1_addr_q             <= f0_l1_miss_req_addr;
      end
    end
  end

  assign f0_l1_miss_resp_valid       = l1_pipe[0];
  assign f0_l1_miss_resp_early_valid = l1_pipe[1];
  assign f0_l1_miss_resp_ecc_err     = 1'b0;
  assign f0_l1_miss_resp_l2_err      = 1'b0;

  // Address derived payload, so a fill can be told apart from stale array state
  always_comb begin
    for (int unsigned w = 0; w < (`ICACHE_BLOCK_BITS/64); w++)
      f0_l1_miss_resp_data[w*64 +: 64] = {l1_addr_q[31:0], w[15:0], 16'hFACE};
  end

  // L1 bookkeeping: every request address in order, and the latency of every
  // fill measured against the request it answers.
  logic [`PA_RANGE] l1_req_addr_hist [0:MAX_RESPS-1];
  int unsigned      l1_req_count    = 0;
  int unsigned      fill_count      = 0;
  int unsigned      fill_done_count = 0;
  time              l1_req_time     = 0;

  always_ff @(posedge clock) begin
    if (!reset) begin
      if (f0_l1_miss_req_valid && f0_l1_miss_req_ready) begin
        l1_req_time <= $time;
        if (l1_req_count < MAX_RESPS) l1_req_addr_hist[l1_req_count] <= f0_l1_miss_req_addr;
        l1_req_count <= l1_req_count + 1;
        $display("INFO  %0t L1 miss request #%0d for PA 0x%0h", $time, l1_req_count, f0_l1_miss_req_addr);
      end
      if (f0_l1_miss_resp_valid) begin
        fill_count <= fill_count + 1;
        if (cycles_between(l1_req_time, $time) == L1_LATENCY)
          $display("PASS  %0t L1 fill for PA 0x%0h delivered %0d cycles after the request",
                   $time, l1_addr_q, L1_LATENCY);
        else begin
          errors++;
          $display("ERROR %0t L1 fill for PA 0x%0h delivered after %0d cycles, expected %0d",
                   $time, l1_addr_q, cycles_between(l1_req_time, $time), L1_LATENCY);
        end
      end
      if (f5_resp_fill_done) begin
        fill_done_count <= fill_done_count + 1;
        $display("INFO  %0t f5_resp_fill_done #%0d, sleeping minions wake up", $time, fill_done_count);
      end
    end
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Page table walker responder
  // Bare mode should never raise a walk. The model keeps a walk from hanging
  // the test and reports any walk it sees.
  // //////////////////////////////////////////////////////////////////////////////
  logic [PTW_LATENCY:0] ptw_pipe;
  minion_ptw_req        ptw_req_q;

  assign ptw_req_ready = 1'b1;

  always_ff @(posedge clock) begin
    if (reset) begin
      ptw_pipe  <= '0;
      ptw_req_q <= '0;
    end else begin
      ptw_pipe <= ptw_pipe >> 1;
      if (ptw_req_valid && ptw_req_ready) begin
        ptw_pipe[PTW_LATENCY] <= 1'b1;
        ptw_req_q             <= ptw_req_data;
        $display("NOTE  %0t PTW walk requested for VA 0x%0h", $time, ptw_req_data.addr);
      end
    end
  end

  assign ptw_resp_valid = ptw_pipe[0];

  always_comb begin
    ptw_resp_data              = '0;
    ptw_resp_data.ppn          = ($bits(ptw_resp_data.ppn))'(ptw_req_q.addr); // identity mapping
    ptw_resp_data.v            = 1'b1;
    ptw_resp_data.r            = 1'b1;
    ptw_resp_data.x            = 1'b1;
    ptw_resp_data.a            = 1'b1;
    ptw_resp_data.u            = 1'b1;
    ptw_resp_data.access_fault = 1'b0;
    ptw_resp_data.canceled_req = 1'b0;
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Static configuration
  // //////////////////////////////////////////////////////////////////////////////
  initial begin
    esr_mprot           = '0;
    esr_vmspagesize     = tlb_entry_type_4K;
    esr_bypass_icache   = 1'b0;
    esr_shire_coop_mode = 1'b0;
    f0_flush_data       = 1'b0;
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

    esr_prefetch_conf  = '0;
    esr_prefetch_start = 1'b0;

    $timeformat(-9, 0, " ns", 12);
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Minion model
  // One state machine per active minion. The request port is shared, so a
  // fixed priority arbiter grants the lowest id among the minions that want to
  // request in a cycle. That is what makes minion 0 retry before minion 1 when
  // both wake on the same fill done.
  // //////////////////////////////////////////////////////////////////////////////
  typedef enum logic [2:0] {
    Minion_Idle,      // waiting for the test to kick it
    Minion_Request,   // wants the port, requests when granted
    Minion_Wait_Resp, // request in the pipeline, response due RESP_LATENCY later
    Minion_Sleep,     // got a miss, wakes on f5_resp_fill_done
    Minion_Done       // got a hit
  } minion_state_t;

  minion_state_t         m_state      [0:NR_ACTIVE-1];
  logic                  m_kick       [0:NR_ACTIVE-1]; // set by the main sequence
  int unsigned           m_line       [0:NR_ACTIVE-1];
  time                   m_req_time   [0:NR_ACTIVE-1];
  int unsigned           m_resp_count [0:NR_ACTIVE-1];
  bit                    m_resp_miss  [0:NR_ACTIVE-1][0:MAX_RESPS-1];
  int unsigned           m_wakeups    [0:NR_ACTIVE-1];

  logic [NR_ACTIVE-1:0]  m_wants, m_grant;

  // Requests in flight, oldest first. The response port carries no minion id,
  // but the pipeline is in order and prefetch responses are suppressed in f3,
  // so the oldest outstanding minion request owns the next f4 response.
  int unsigned inflight_id [0:MAX_RESPS-1];
  int unsigned inflight_head = 0;
  int unsigned inflight_tail = 0;

  // Order in which minions re-requested after a wake-up
  int unsigned retry_order [0:MAX_RESPS-1];
  int unsigned retry_count = 0;
  int unsigned issued_count = 0;

  // Fixed priority arbiter, lowest id wins
  always_comb begin
    for (int unsigned m = 0; m < NR_ACTIVE; m++)
      m_wants[m] = (m_state[m] == Minion_Request);
    m_grant = '0;
    for (int unsigned m = 0; m < NR_ACTIVE; m++)
      if (m_wants[m] && (m_grant == '0)) m_grant[m] = 1'b1;
  end

  // Request port driven by the granted minion
  always_comb begin
    f0_req_valid  = |m_grant;
    f0_req        = '0;
    f0_req_min_id = '0;
    for (int unsigned m = 0; m < NR_ACTIVE; m++) begin
      if (m_grant[m]) begin
        f0_req.thread_id     = '0;
        f0_req.vm_status.prv = 2'b11; // machine mode
        f0_req.addr          = ($bits(f0_req.addr))'(line_addr(m_line[m]));
        f0_req_min_id        = m[NR_MINIONS_L-1:0];
      end
    end
  end

  always_ff @(posedge clock) begin
    int unsigned id;
    string       retry_tag;
    if (reset) begin
      for (int unsigned m = 0; m < NR_ACTIVE; m++) begin
        m_state[m]      <= Minion_Idle;
        m_line[m]       <= m;
        m_resp_count[m] <= 0;
        m_wakeups[m]    <= 0;
        m_req_time[m]   <= 0;
      end
      inflight_head <= 0;
      inflight_tail <= 0;
      retry_count   <= 0;
      issued_count  <= 0;
    end else begin
      // Response delivery, attributed to the oldest request in flight
      if (f4_resp_valid) begin
        id = inflight_id[inflight_head % MAX_RESPS];
        inflight_head <= inflight_head + 1;
        if (m_resp_count[id] < MAX_RESPS) m_resp_miss[id][m_resp_count[id]] <= f4_resp_miss;
        m_resp_count[id] <= m_resp_count[id] + 1;
        if (cycles_between(m_req_time[id], $time) != RESP_LATENCY) begin
          errors++;
          $display("ERROR %0t minion %0d response arrived %0d cycles after the request, expected %0d",
                   $time, id, cycles_between(m_req_time[id], $time), RESP_LATENCY);
        end
        if (f4_resp_miss) begin
          m_state[id] <= Minion_Sleep;
          $display("INFO  %0t minion %0d response #%0d: MISS after %0d cycles, going to sleep",
                   $time, id, m_resp_count[id], cycles_between(m_req_time[id], $time));
        end else begin
          m_state[id] <= Minion_Done;
          $display("INFO  %0t minion %0d response #%0d: HIT after %0d cycles, done",
                   $time, id, m_resp_count[id], cycles_between(m_req_time[id], $time));
        end
      end

      for (int unsigned m = 0; m < NR_ACTIVE; m++) begin
        case (m_state[m])
          Minion_Idle:
            if (m_kick[m]) m_state[m] <= Minion_Request;

          Minion_Request:
            if (m_grant[m]) begin
              inflight_id[inflight_tail % MAX_RESPS] <= m;
              inflight_tail <= inflight_tail + 1;
              issued_count  <= issued_count + 1;
              m_req_time[m] <= $time;
              m_state[m]    <= Minion_Wait_Resp;
              if (m_wakeups[m] > 0) begin
                if (retry_count < MAX_RESPS) retry_order[retry_count] <= m;
                retry_count <= retry_count + 1;
              end
              retry_tag = (m_wakeups[m] > 0) ? ", retry" : "";
              $display("INFO  %0t minion %0d requests line %0d (VA 0x%0h)%s",
                       $time, m, m_line[m], f0_req.addr, retry_tag);
            end

          Minion_Wait_Resp: ; // handled by the response block above

          Minion_Sleep:
            if (f5_resp_fill_done) begin
              m_wakeups[m] <= m_wakeups[m] + 1;
              m_state[m]   <= Minion_Request;
              $display("INFO  %0t minion %0d wakes up on fill done", $time, m);
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
  // reached Request) and high again afterwards. Both edges are latched here so
  // the check does not depend on when it is called.
  bit prefetch_done_fell = 1'b0;
  bit prefetch_done_rose = 1'b0;

  always_ff @(posedge clock) begin
    if (!reset) begin
      if (!esr_prefetch_done) prefetch_done_fell <= 1'b1;
      if (prefetch_done_fell && esr_prefetch_done) prefetch_done_rose <= 1'b1;
      if (dut.f0_prefetch_miss_nomh_state != dut.f0_prefetch_miss_nomh_state_next)
        $display("INFO  %0t nomh FSM %s -> %s", $time,
                 dut.f0_prefetch_miss_nomh_state.name(), dut.f0_prefetch_miss_nomh_state_next.name());
      if (dut.f0_prefetch_state != dut.f0_prefetch_state_next)
        $display("INFO  %0t prefetch FSM %s -> %s", $time,
                 dut.f0_prefetch_state.name(), dut.f0_prefetch_state_next.name());
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

  // Expected response history per minion, as a miss/hit pattern
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

  task automatic check_minion_flow ();
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

      // Response histories
      check_history(0, '{1'b1, 1'b0},       "miss, hit");
      check_history(1, '{1'b1, 1'b1, 1'b0}, "miss, miss, hit");

      // Retry order after the first fill done: minion 0, then minion 1
      if ((retry_count >= 2) && (retry_order[0] == 0) && (retry_order[1] == 1))
        $display("PASS  %0t minion 0 retried before minion 1 after the first fill done", $time);
      else begin
        errors++;
        $display("ERROR %0t retry order wrong, %0d retries, first two: %0d, %0d",
                 $time, retry_count, retry_order[0], retry_order[1]);
      end

      // L1 traffic: line 0 on behalf of minion 0, then line 1 for minion 1
      if ((l1_req_count >= 2) && (l1_req_addr_hist[0] == line_paddr(0)) && (l1_req_addr_hist[1] == line_paddr(1)))
        $display("PASS  %0t L1 requests went out for line 0 then line 1", $time);
      else begin
        errors++;
        $display("ERROR %0t L1 requests: %0d seen, first two PA 0x%0h, 0x%0h, expected 0x%0h, 0x%0h",
                 $time, l1_req_count, l1_req_addr_hist[0], l1_req_addr_hist[1], line_paddr(0), line_paddr(1));
      end
      if (fill_count != l1_req_count) begin
        errors++;
        $display("ERROR %0t %0d L1 requests but %0d fills", $time, l1_req_count, fill_count);
      end
    end
  endtask

  task automatic check_prefetch_done ();
    int unsigned guard;
    begin
      guard = 0;
      while (!prefetch_done_rose && (guard < DONE_TIMEOUT)) begin
        @(posedge clock);
        guard++;
      end
      if (prefetch_done_rose)
        $display("PASS  %0t prefetch burst completed, esr_prefetch_done rose again", $time);
      else if (!prefetch_done_fell) begin
        errors++;
        $display("ERROR %0t esr_prefetch_done never fell, the FSM never reached Request (state %s)",
                 $time, dut.f0_prefetch_state.name());
      end else begin
        errors++;
        $display("ERROR %0t esr_prefetch_done still low %0d cycles after start, prefetch FSM is parked in %s",
                 $time, DONE_TIMEOUT, dut.f0_prefetch_state.name());
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
      $display("\nstarting icache_micro_cache simple test: two minion misses then a prefetch");
    else
      $display("\nstarting icache_micro_cache simple test: two minion misses, no prefetch");

    reset = 1'b1;
    repeat (8) @(posedge clock);
    reset = 1'b0;
    repeat (8) @(posedge clock);

    // Both minions want the port at once; the arbiter serialises them
    for (int unsigned m = 0; m < NR_ACTIVE; m++) m_kick[m] = 1'b1;
    while (issued_count < NR_ACTIVE) @(posedge clock);

    if (use_prefetch) begin
      repeat (IDLE_BEFORE_PREFETCH) @(posedge clock);
      prefetch_start(PREFETCH_FIRST_LINE, PREFETCH_EXTRA_LINES);
    end

    check_minion_flow();
    if (use_prefetch) check_prefetch_done();

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
