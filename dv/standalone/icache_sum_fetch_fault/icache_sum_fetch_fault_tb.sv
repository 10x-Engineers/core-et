// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// L0 micro-cache: S-mode fetch from a U page with sstatus.SUM = 1.
//
// RISC-V privileged spec: SUM permits S-mode loads and stores to pages with
// U = 1. SUM has no effect on instruction fetch. S-mode never executes from
// a page with U = 1, so an S-mode fetch from a U page must give an
// instruction page fault for every value of SUM.
//
// tlb_top computes priv_ok as 1 for a non-U mode when SUM = 1, also for an
// instruction fetch. The fetch then gets no page fault.
//
// DUT: icache_micro_cache (real RTL, TLB in tlb_top). L1 and PTW are TB
// models. Translation is Sv48. The PTW model returns a leaf PTE per page:
//   S page  VA 0x2000  V R X A, U = 0  -> PA 0x0200_C000
//   U page  VA 0x1040  V R X A, U = 1  -> PA 0x0200_C040
// Both are in the SRAM frame, so the PMA gives no access fault. The two
// lines have different PAs, so an L0 hit for one never hides the other.
//
// Sequence (M0/TH0, one fetch at a time):
//   1. S-mode, SUM = 0, S page: no fault, data (TLB walk, L1 fill).
//   2. S-mode, SUM = 0, U page: page fault (TLB walk, then TLB hit).
//   3. S-mode, SUM = 1, U page: TLB hit on the entry from step 2. Correct
//      RTL gives a page fault and no L1 request. The defect gives no fault,
//      an L1 request and the U-page line as data to S-mode.
//   4. U-mode, SUM = 0, U page: no fault, data (the page is user code).
//
// Run with:  make        (make wave opens GTKWave)

`include "soc.vh"

module icache_sum_fetch_fault_tb;

  localparam int NR_MINIONS   = 8;
  localparam int NR_MINIONS_L = $clog2(NR_MINIONS);
  localparam int L1_LATENCY   = 10;  // L1 request accept -> fill
  localparam int PTW_LATENCY  = 8;   // PTW request accept -> response
  localparam int MAX_RESPS    = 4;   // responses per fetch before a timeout

  localparam logic [`PA_RANGE] SRAM_BASE = `PA_SIZE'h0200_C000;

  localparam logic [47:0] VA_S = 48'h0000_0000_2000; // S page, U = 0
  localparam logic [47:0] VA_U = 48'h0000_0000_1040; // U page, U = 1
  localparam logic [35:0] VPN_U = 36'h1;

  // ------------------------------------------------------------------------
  // Clock, reset, cycle counter
  // ------------------------------------------------------------------------
  logic clock = 1'b0;
  logic reset = 1'b1;
  int   cyc   = 0;

  always #1 clock = ~clock;
  always @(posedge clock) cyc <= cyc + 1;

  // ------------------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------------------
  logic                                     f0_req_valid;
  frontend_icache_req                       f0_req;
  logic                                     f4_resp_valid;
  logic                                     f4_resp_miss;
  icache_frontend_resp                      f4_resp;
  logic                                     f5_resp_fill_done;
  logic                                     l1_req_ready;
  logic                                     l1_req_valid;
  logic [`PA_RANGE]                         l1_req_addr;
  logic                                     l1_resp_early_valid;
  logic                                     l1_resp_valid;
  logic [`ICACHE_BLOCK_BITS-1:0]            l1_resp_data;
  minion_satp_info [NR_MINIONS-1:0]         satp_info;
  minion_ptw_req                            ptw_req_data;
  logic                                     ptw_req_valid;
  logic                                     ptw_req_ready;
  logic                                     ptw_resp_valid;
  minion_ptw_pte                            ptw_resp_data;

  icache_micro_cache #(
    .ID         ( 0          ),
    .NR_MINIONS ( NR_MINIONS )
  ) dut (
    .clock                       ( clock               ),
    .reset                       ( reset               ),
    .esr_prefetch_conf           ( '0                  ),
    .esr_prefetch_start          ( 1'b0                ),
    .esr_prefetch_done           (                     ),
    .esr_mprot                   ( '0                  ),
    .esr_vmspagesize             ( tlb_entry_type_4K   ),
    .esr_bypass_icache           ( 1'b0                ),
    .esr_shire_coop_mode         ( 1'b0                ),
    .f0_req_ready                (                     ),
    .f0_req_valid                ( f0_req_valid        ),
    .f0_req                      ( f0_req              ),
    .f0_req_min_id               ( '0                  ),
    .f4_resp_valid               ( f4_resp_valid       ),
    .f4_resp_miss                ( f4_resp_miss        ),
    .f4_resp                     ( f4_resp             ),
    .f5_resp_fill_done           ( f5_resp_fill_done   ),
    .f0_flush_data               ( 1'b0                ),
    .f0_l1_miss_req_ready        ( l1_req_ready        ),
    .f0_l1_miss_req_valid        ( l1_req_valid        ),
    .f0_l1_miss_req_addr         ( l1_req_addr         ),
    .f0_l1_miss_resp_early_valid ( l1_resp_early_valid ),
    .f0_l1_miss_resp_valid       ( l1_resp_valid       ),
    .f0_l1_miss_resp_data        ( l1_resp_data        ),
    .f0_l1_miss_resp_ecc_err     ( 1'b0                ),
    .f0_l1_miss_resp_l2_err      ( 1'b0                ),
    .satp_info                   ( satp_info           ),
    .matp_info                   ( '0                  ),
    .tlb_invalidate              ( '0                  ),
    .ptw_req_data                ( ptw_req_data        ),
    .ptw_req_valid               ( ptw_req_valid       ),
    .ptw_req_ready               ( ptw_req_ready       ),
    .ptw_invalidate              (                     ),
    .ptw_resp_valid              ( ptw_resp_valid      ),
    .ptw_resp_data               ( ptw_resp_data       ),
    .apb_paddr                   ( '0                  ),
    .apb_pwrite                  ( 1'b0                ),
    .apb_psel                    ( 1'b0                ),
    .apb_penable                 ( 1'b0                ),
    .apb_pwdata                  ( '0                  ),
    .apb_pready                  (                     ),
    .apb_prdata                  (                     ),
    .apb_pslverr                 (                     ),
    .dbg_sm_signals              (                     )
  );

  // ------------------------------------------------------------------------
  // L1 model: one request at a time, fill L1_LATENCY cycles after accept.
  // early_valid is one cycle ahead of valid, as icache_top drives it.
  // Payload: every 64-bit word is {line PA[31:0], word index, 0xFACE}.
  // ------------------------------------------------------------------------
  logic [L1_LATENCY-1:0] l1_pipe;
  logic [`PA_RANGE]      l1_addr_q;

  assign l1_req_ready        = 1'b1;
  assign l1_resp_valid       = l1_pipe[0];
  assign l1_resp_early_valid = l1_pipe[1];

  always_comb
    for (int w = 0; w < `ICACHE_BLOCK_BITS/64; w++)
      l1_resp_data[w*64 +: 64] = {l1_addr_q[31:0], 16'(w), 16'hFACE};

  always @(posedge clock) begin
    if (reset) begin
      l1_pipe   <= '0;
      l1_addr_q <= '0;
    end else begin
      l1_pipe <= l1_pipe >> 1;
      if (l1_req_valid && l1_req_ready) begin
        l1_pipe[L1_LATENCY-1] <= 1'b1;
        l1_addr_q             <= l1_req_addr;
      end
    end
  end

  // ------------------------------------------------------------------------
  // PTW model: returns the leaf PTE for the VPN PTW_LATENCY cycles after
  // accept. rsvd_for_hw[0] marks an M-mode walk, as ptw_top sets it.
  // ------------------------------------------------------------------------
  logic [PTW_LATENCY:0] ptw_pipe;
  minion_ptw_req        ptw_req_q;
  logic [35:0]          ptw_vpn_log [$];

  assign ptw_req_ready  = 1'b1;
  assign ptw_resp_valid = ptw_pipe[0];

  always_comb begin
    ptw_resp_data                = '0;
    ptw_resp_data.ppn            = ($bits(ptw_resp_data.ppn))'(SRAM_BASE >> 12);
    ptw_resp_data.v              = 1'b1;
    ptw_resp_data.r              = 1'b1;
    ptw_resp_data.x              = 1'b1;
    ptw_resp_data.a              = 1'b1;
    ptw_resp_data.u              = (36'(ptw_req_q.addr) == VPN_U);
    ptw_resp_data.rsvd_for_hw[0] = (ptw_req_q.prv == `CSR_PRV_M);
  end

  always @(posedge clock) begin
    if (reset) begin
      ptw_pipe  <= '0;
      ptw_req_q <= '0;
    end else begin
      ptw_pipe <= ptw_pipe >> 1;
      if (ptw_req_valid && ptw_req_ready) begin
        ptw_pipe[PTW_LATENCY] <= 1'b1;
        ptw_req_q             <= ptw_req_data;
        ptw_vpn_log.push_back(36'(ptw_req_data.addr));
        $display("  cyc %4d: PTW walk for VPN 0x%0h", cyc, ptw_req_data.addr);
      end
      if (ptw_resp_valid)
        $display("  cyc %4d: PTW response, PPN 0x%0h, U = %0d, X = %0d",
                 cyc, ptw_resp_data.ppn, ptw_resp_data.u, ptw_resp_data.x);
    end
  end

  // ------------------------------------------------------------------------
  // Monitors. One fetch is in flight at a time.
  // ------------------------------------------------------------------------
  typedef struct {
    int               step;
    string            mode;
    bit               sum;
    logic [47:0]      va;
    int               lookups;        // F2 lookups for this fetch
    int               tlb_misses;
    int               first_hit_idx;  // first lookup with a TLB hit, -1 if none
    bit               hit_page_fault; // page fault on the first TLB-hit lookup
    int               l1_reqs;
    int               resps;
    bit               page_fault;     // any F4 response with page_fault
    bit               got_data;       // F4 hit without fault
    logic [`PA_RANGE] data_pa;        // line PA decoded from the returned data
  } fetch_t;

  fetch_t fetches [$];
  int     cur = -1;
  int     fill_done_cnt = 0;

  // Waveform helpers
  int     tb_step = 0;
  bit     tb_expect_fault = 0;

  always @(posedge clock) begin
    if (!reset) begin
      if (f5_resp_fill_done) fill_done_cnt++;

      if (cur >= 0) begin
        if (dut.f2_valid && !dut.f2_is_prefetch) begin
          if (!dut.f2_tlb_resp_data.miss && fetches[cur].first_hit_idx < 0) begin
            fetches[cur].first_hit_idx  = fetches[cur].lookups;
            fetches[cur].hit_page_fault = dut.f2_page_fault;
          end
          if (dut.f2_tlb_resp_data.miss) fetches[cur].tlb_misses++;
          fetches[cur].lookups++;
          $display("  cyc %4d: F2 VA 0x%012h PA 0x%010h, TLB %s, %s", cyc,
                   dut.f2_req.addr[47:0], dut.f2_paddr,
                   dut.f2_tlb_resp_data.miss ? "miss" : "hit",
                   dut.f2_page_fault   ? "PAGE FAULT" :
                   dut.f2_access_fault ? "ACCESS FAULT" :
                   dut.f2_hit          ? "L0 hit" :
                   dut.f2_miss         ? "L0 miss -> L1" :
                   dut.f2_tlb_resp_data.miss ? "wait for TLB fill" : "no L1 request");
        end
        if (l1_req_valid && l1_req_ready) begin
          fetches[cur].l1_reqs++;
          $display("  cyc %4d: L1 request PA 0x%010h", cyc, l1_req_addr);
        end
        if (f4_resp_valid) begin
          fetches[cur].resps++;
          if (f4_resp.page_fault) fetches[cur].page_fault = 1;
          if (!f4_resp_miss && !f4_resp.page_fault && !f4_resp.access_fault) begin
            fetches[cur].got_data = 1;
            fetches[cur].data_pa  = `PA_SIZE'(f4_resp.data[63:32]);
          end
        end
      end
    end
  end

  // ------------------------------------------------------------------------
  // Stimulus. tick() returns half a cycle after a posedge.
  // ------------------------------------------------------------------------
  task automatic tick();
    @(posedge clock);
    #0.5;
  endtask

  // M0/TH0 fetches va in mode prv with sstatus.SUM = sum, as the frontend
  // does: a fault ends the fetch (exception), a miss without fault sleeps
  // until f5_resp_fill_done and retries, a hit returns the data.
  task automatic fetch(int step, logic [1:0] prv, bit sum, logic [47:0] va, bit expect_fault);
    fetch_t f;
    bit     done = 0;
    f.step = step; f.sum = sum; f.va = va;
    f.mode = (prv == `CSR_PRV_U) ? "U" : (prv == `CSR_PRV_S) ? "S" : "M";
    f.lookups = 0; f.tlb_misses = 0; f.first_hit_idx = -1; f.hit_page_fault = 0;
    f.l1_reqs = 0; f.resps = 0; f.page_fault = 0; f.got_data = 0; f.data_pa = '0;
    fetches.push_back(f);
    cur             = fetches.size() - 1;
    tb_step         = step;
    tb_expect_fault = expect_fault;

    while (!done) begin
      int n;
      f0_req_valid             = 1'b1;
      f0_req                   = '0;
      f0_req.thread_id         = '0;
      f0_req.vm_status.prv     = prv;
      f0_req.vm_status.sum     = sum;
      f0_req.addr              = (`VA_EXT_MSB+1)'(va);
      tick();
      f0_req_valid = 1'b0;
      while (!f4_resp_valid) tick();
      $display("  cyc %4d: F4 miss %0d, page_fault %0d, access_fault %0d%s", cyc,
               f4_resp_miss, f4_resp.page_fault, f4_resp.access_fault,
               (!f4_resp_miss && !f4_resp.page_fault) ?
                 $sformatf(", data line PA 0x%010h", `PA_SIZE'(f4_resp.data[63:32])) : "");
      if (f4_resp.page_fault || f4_resp.access_fault || !f4_resp_miss)
        done = 1;
      else begin
        n = fill_done_cnt;
        while (fill_done_cnt == n) tick();
      end
      if (fetches[cur].resps >= MAX_RESPS) begin
        $display("ERROR step %0d: no final response after %0d tries", step, MAX_RESPS);
        done = 1;
      end
    end
    repeat (3) tick();
    cur = -1;
  endtask

  // ------------------------------------------------------------------------
  // Checks
  // ------------------------------------------------------------------------
  int errors  = 0;
  int defects = 0;

  task automatic check(string what, longint got, longint exp, bit is_defect = 0);
    if (got == exp) $display("PASS  %-56s = 0x%0h", what, got);
    else begin
      $display("FAIL  %-56s = 0x%0h (expected 0x%0h)", what, got, exp);
      if (is_defect) defects++; else errors++;
    end
  endtask

  function automatic logic [`PA_RANGE] pa_of(logic [47:0] va);
    return {SRAM_BASE[`PA_MSB:12], va[11:6], 6'b0};
  endfunction

  // ------------------------------------------------------------------------
  // Test
  // ------------------------------------------------------------------------
  initial begin
    f0_req_valid = 1'b0;
    f0_req       = '0;
    satp_info    = '0;
    for (int m = 0; m < NR_MINIONS; m++) satp_info[m].mode = `CSR_SATP_MODE_SV48;

    $display("\nS-mode fetch from a U page with SUM = 1: Sv48, M0/TH0, L0 micro-cache 0");
    $display("  S page VA 0x%012h (U = 0) -> PA 0x%010h", VA_S, pa_of(VA_S));
    $display("  U page VA 0x%012h (U = 1) -> PA 0x%010h", VA_U, pa_of(VA_U));

    repeat (8) tick();
    reset = 1'b0;
    repeat (8) tick();

    $display("\n=== Step 1: S-mode, SUM = 0, S page (expect data) ===");
    fetch(1, `CSR_PRV_S, 1'b0, VA_S, 1'b0);

    $display("\n=== Step 2: S-mode, SUM = 0, U page (expect page fault) ===");
    fetch(2, `CSR_PRV_S, 1'b0, VA_U, 1'b1);

    $display("\n=== Step 3: S-mode, SUM = 1, U page (expect page fault) ===");
    fetch(3, `CSR_PRV_S, 1'b1, VA_U, 1'b1);

    $display("\n=== Step 4: U-mode, SUM = 0, U page (expect data) ===");
    fetch(4, `CSR_PRV_U, 1'b0, VA_U, 1'b0);

    repeat (10) tick();

    // ---- Report ----------------------------------------------------------
    $display("\n  %-4s %-4s %-3s %-14s %-7s %-9s %-10s %-3s %-10s %-12s",
             "step", "mode", "SUM", "VA", "lookups", "TLB miss", "page fault", "L1", "result", "data line PA");
    foreach (fetches[k])
      $display("  %-4d %-4s %-3d 0x%012h %-7d %-9d %-10d %-3d %-10s %-12s",
               fetches[k].step, fetches[k].mode, fetches[k].sum, fetches[k].va,
               fetches[k].lookups, fetches[k].tlb_misses, fetches[k].page_fault,
               fetches[k].l1_reqs,
               fetches[k].page_fault ? "fault" : fetches[k].got_data ? "data" : "none",
               fetches[k].got_data ? $sformatf("0x%010h", fetches[k].data_pa) : "-");
    $display("");

    // Sanity: steps 1, 2 and 4 behave as the spec and the header describe
    check("PTW walks (S page, then U page)",                       ptw_vpn_log.size(), 2);
    check("step 1: S-mode S page, page fault",                     fetches[0].page_fault, 0);
    check("step 1: S-mode S page, data line PA",                   fetches[0].data_pa, pa_of(VA_S));
    check("step 2: S-mode SUM=0 U page, page fault",               fetches[1].page_fault, 1);
    check("step 2: S-mode SUM=0 U page, L1 requests",              fetches[1].l1_reqs, 0);
    check("step 3: first lookup is a TLB hit (entry from step 2)", fetches[2].first_hit_idx, 0);
    check("step 4: U-mode U page, page fault",                     fetches[3].page_fault, 0);
    check("step 4: U-mode U page, data line PA",                   fetches[3].data_pa, pa_of(VA_U));

    // The defect checks: SUM must not apply to instruction fetch
    $display("");
    check("step 3: S-mode SUM=1 U page, page fault in F2",         fetches[2].hit_page_fault, 1, 1);
    check("step 3: S-mode SUM=1 U page, page fault in F4",         fetches[2].page_fault, 1, 1);
    check("step 3: S-mode SUM=1 U page, L1 requests",              fetches[2].l1_reqs, 0, 1);
    check("step 3: S-mode SUM=1 U page, data returned",            fetches[2].got_data, 0, 1);

    $display("\n================================================");
    if (errors != 0)
      $display("TEST INVALID, %0d sanity error(s)", errors);
    else if (defects != 0)
      $display("TEST FAILED: S-mode with SUM = 1 fetches from a U page without a page fault%s",
               fetches[2].got_data ? $sformatf(" (got line PA 0x%010h)", fetches[2].data_pa) : "");
    else
      $display("TEST PASSED");
    $display("================================================");
    $finish;
  end

  // Watchdog
  initial begin
    #20000;
    $display("ERROR watchdog");
    $finish;
  end

endmodule
