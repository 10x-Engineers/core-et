// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// L0 micro-cache 2 MB superpage alias testbench.
//
// Checks that two fetch addresses in the same 2 MB page, with the same
// VA[11:0] but different VA[20:12], get different physical addresses.
//
// DUT path (all real RTL, same wiring as neigh_channel):
//   neigh_shared_icache (request flops, arbiters, icache_top)
//     -> neigh_lo_voltage_cross -> icache_data_ram_wrap -> neigh_hi_voltage_cross
//   neigh_shared_ptw (PTW 0, serves requestor 0 = Minions 0-3)
// Memory (code lines and page table) is a fixed-latency TB model.
// esr_vmspagesize is driven to 2 MB here; neigh_channel ties it to 4 KB.
//
// Sequence (Minion 0, requestor 0):
//   0. Invalidate the TLBs and flush the I-cache once. No flush after this.
//   1. TH0 fetches VA_A: TLB miss, PTW walk, f5_resp_fill_done.
//   2. TH0 fetches VA_A: TLB hit, L0 tag miss, L1/L2 fill, f5_resp_fill_done.
//   3. TH0 fetches VA_A: TLB hit, L0 tag hit, data.
//   4. TH1 fetches VA_B a few cycles later: TLB hit. Correct RTL gives an L0
//      tag miss and the line at PA_B; the defect gives the line at PA_A.

`include "soc.vh"

module icache_l0_superpage_alias_tb;

  localparam int NR_REQ  = 2;
  localparam int NR_MIN  = `MIN_PER_N;
  localparam int NR_PREQ = `MIN_PER_PTW + 1;  // PTW 0 requestors: {icache, dcache x4}
  localparam int L2_LAT  = 10;                // request accept -> fill
  localparam int GAP     = 7;                 // idle cycles before step 4

  // Physical placement, all in the DDR region PA[39:24] = 0x40
  localparam logic [`PA_RANGE] PT_L3   = 40'h00_4080_0000;  // root table (satp)
  localparam logic [`PA_RANGE] PT_L2   = 40'h00_4080_1000;
  localparam logic [`PA_RANGE] PT_L1   = 40'h00_4080_2000;
  localparam logic [`PA_RANGE] PAGE_PA = 40'h00_4000_0000;  // 2 MB page frame

  // Same 2 MB page (VA[47:21] = 0), same VA[11:0], VA[20:12] = 0x000 / 0x1FF
  localparam logic [47:0] VA_A = 48'h0000_0000_0040;
  localparam logic [47:0] VA_B = 48'h0000_001F_F040;

  // ------------------------------------------------------------------------
  // Clock, reset, cycle counter
  // ------------------------------------------------------------------------
  logic clock = 1'b0;
  logic reset = 1'b1;
  int   cyc   = 0;

  always #1 clock = ~clock;
  always @(posedge clock) cyc <= cyc + 1;

  // ------------------------------------------------------------------------
  // neigh_shared_icache ports
  // ------------------------------------------------------------------------
  logic [NR_MIN-1:0]                  f0_req_ready;
  logic [NR_MIN-1:0]                  f0_req_valid;
  frontend_icache_req [NR_MIN-1:0]    f0_req;
  logic [NR_REQ-1:0]                  f4_resp_valid;
  logic [NR_REQ-1:0]                  f4_resp_miss;
  icache_frontend_resp [NR_REQ-1:0]   f4_resp;
  logic [NR_REQ-1:0]                  f5_resp_fill_done;
  logic [NR_MIN-1:0]                  f0_flush_data;
  logic [NR_MIN-1:0]                  tlb_invalidate;
  minion_satp_info [NR_MIN-1:0]       satp_info;

  logic                               l2_req_valid;
  et_link_nodata_req_info_t           l2_req;
  logic                               l2_rsp_valid;
  et_link_rsp_info_t                  l2_rsp;

  minion_ptw_req [NR_REQ-1:0]         ptw_req_data;
  logic [NR_REQ-1:0]                  ptw_req_valid;
  logic [NR_REQ-1:0]                  ptw_req_ready;
  logic [NR_REQ-1:0]                  ptw_invalidate;
  logic [NR_REQ-1:0]                  ptw_resp_valid;
  minion_ptw_pte [NR_REQ-1:0]         ptw_resp_data;

  // SRAM interface, icache side
  logic                               top_sram_req_write;
  logic [`ICACHE_SRAM_ADD_WIDTH-1:0]  top_sram_req_addr;
  logic                               top_sram_req_valid;
  logic                               top_sram_req_ready;
  logic [`ICACHE_SRAM_DATA_WIDTH-1:0] top_sram_resp_dout;
  logic                               top_sram_resp_valid;
  logic                               top_sram_resp_ready;

  // SRAM interface, icache_data_ram_wrap side
  logic                               ram_req_write;
  logic [`ICACHE_SRAM_ADD_WIDTH-1:0]  ram_req_addr;
  logic                               ram_req_valid;
  logic                               ram_req_ready;
  logic [`ICACHE_SRAM_DATA_WIDTH-1:0] ram_resp_dout;
  logic                               ram_resp_valid;
  logic                               ram_resp_ready;

  neigh_shared_icache #(
    .NR_MINIONS    ( NR_MIN ),
    .NR_REQUESTORS ( NR_REQ )
  ) dut (
    .clock                       ( clock               ),
    .reset                       ( reset               ),
    .esr_prefetch_conf           ( '0                  ),
    .esr_prefetch_start          ( 1'b0                ),
    .esr_prefetch_done           (                     ),
    .esr_err_log_ctl             ( '0                  ),
    .esr_err_log_sbe             (                     ),
    .esr_err_log_dbe             (                     ),
    .esr_err_log_info            (                     ),
    .esr_mprot                   ( '0                  ),
    .esr_vmspagesize             ( tlb_entry_type_2M   ),
    .esr_bypass_icache           ( 1'b0                ),
    .esr_shire_coop_mode         ( 1'b0                ),
    .f0_req_ready                ( f0_req_ready        ),
    .f0_req_valid                ( f0_req_valid        ),
    .f0_req                      ( f0_req              ),
    .f4_resp_valid               ( f4_resp_valid       ),
    .f4_resp_miss                ( f4_resp_miss        ),
    .f4_resp                     ( f4_resp             ),
    .f5_resp_fill_done           ( f5_resp_fill_done   ),
    .f0_flush_data               ( f0_flush_data       ),
    .f0_l2_miss_req_disable_next ( 1'b0                ),
    .f0_l2_miss_req_ready        ( 1'b1                ),
    .f0_l2_miss_req_valid        ( l2_req_valid        ),
    .f0_l2_miss_req              ( l2_req              ),
    .f0_l2_miss_resp_ready       (                     ),
    .f0_l2_miss_resp_valid       ( l2_rsp_valid        ),
    .f0_l2_miss_resp             ( l2_rsp              ),
    .satp_info                   ( satp_info           ),
    .matp_info                   ( '0                  ),
    .tlb_invalidate              ( tlb_invalidate      ),
    .ptw_req_data                ( ptw_req_data        ),
    .ptw_req_valid               ( ptw_req_valid       ),
    .ptw_req_ready               ( ptw_req_ready       ),
    .ptw_invalidate              ( ptw_invalidate      ),
    .ptw_resp_valid              ( ptw_resp_valid      ),
    .ptw_resp_data               ( ptw_resp_data       ),
    .icache_f2_sram_req_write    ( top_sram_req_write  ),
    .icache_f2_sram_req_addr     ( top_sram_req_addr   ),
    .icache_f2_sram_req_valid    ( top_sram_req_valid  ),
    .icache_f2_sram_req_ready    ( top_sram_req_ready  ),
    .icache_f0_sram_resp_dout    ( top_sram_resp_dout  ),
    .icache_f0_sram_resp_valid   ( top_sram_resp_valid ),
    .icache_f0_sram_resp_ready   ( top_sram_resp_ready ),
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

  // Request register slice, connected as in neigh_channel.v
  neigh_lo_voltage_cross #(
    .NUM_ELEMS ( `SHIRE_LO_VOLTAGE_FIFO_SIZE )
  ) lo_voltage_cross (
    .reset_w                       ( reset              ),
    .reset_d                       ( reset              ),
    .clock                         ( clock              ),
    .icache_f2_sram_req_write      ( top_sram_req_write ),
    .icache_f2_sram_req_write_sync ( ram_req_write      ),
    .icache_f2_sram_req_addr       ( top_sram_req_addr  ),
    .icache_f2_sram_req_addr_sync  ( ram_req_addr       ),
    .icache_f2_sram_req_valid      ( top_sram_req_valid ),
    .icache_f2_sram_req_valid_sync ( ram_req_valid      ),
    .icache_f2_sram_req_ready      ( ram_req_ready      ),
    .icache_f2_sram_req_ready_sync ( top_sram_req_ready )
  );

  // Response FIFO, connected as in neigh_channel.v
  neigh_hi_voltage_cross #(
    .NUM_ELEMS ( `SHIRE_HI_VOLTAGE_FIFO_SIZE )
  ) hi_voltage_cross (
    .reset_c                        ( reset               ),
    .reset_w                        ( reset               ),
    .clock                          ( clock               ),
    .icache_f0_sram_resp_dout       ( ram_resp_dout       ),
    .icache_f0_sram_resp_dout_sync  ( top_sram_resp_dout  ),
    .icache_f0_sram_resp_valid      ( ram_resp_valid      ),
    .icache_f0_sram_resp_valid_sync ( top_sram_resp_valid ),
    .icache_f0_sram_resp_ready      ( top_sram_resp_ready ),
    .icache_f0_sram_resp_ready_sync ( ram_resp_ready      )
  );

  icache_data_ram_wrap #(
    .ID ( 0 )
  ) ram (
    .clock                   ( clock          ),
    .reset                   ( reset          ),
    .dft__sram_clock         ( 1'b0           ),
    .dft__clk_override       ( 1'b0           ),
    .icache_req_write        ( ram_req_write  ),
    .icache_req_addr         ( ram_req_addr   ),
    .icache_req_valid        ( ram_req_valid  ),
    .icache_req_ready        ( ram_req_ready  ),
    .icache_resp_dout        ( ram_resp_dout  ),
    .icache_resp_valid       ( ram_resp_valid ),
    .icache_resp_ready       ( ram_resp_ready ),
    .neigh_sc_rsp_info       ( l2_rsp         ),
    .neigh_sc_rsp_valid      ( l2_rsp_valid   ),
    .neigh_sc_rsp_ready      ( 1'b1           ),
    .esr_shire_cache_ram_cfg ( '0             ),
    .bist_req_info           ( '0             ),
    .bist_rsp_info           (                ),
    .apb_paddr               ( '0             ),
    .apb_pwrite              ( 1'b0           ),
    .apb_psel                ( 1'b0           ),
    .apb_penable             ( 1'b0           ),
    .apb_pwdata              ( '0             ),
    .apb_pready              (                ),
    .apb_prdata              (                ),
    .apb_pslverr             (                )
  );

  // ------------------------------------------------------------------------
  // PTW 0, connected as in neigh_channel.v: slot MIN_PER_PTW is the icache
  // requestor, slots MIN_PER_PTW-1..0 are the data caches (idle here).
  // ------------------------------------------------------------------------
  minion_ptw_req [NR_PREQ-1:0]  ptw0_req_data;
  logic [NR_PREQ-1:0]           ptw0_req_valid;
  logic [NR_PREQ-1:0]           ptw0_req_ready;
  logic [NR_PREQ-1:0]           ptw0_invalidate;
  logic [NR_PREQ-1:0]           ptw0_resp_valid;
  minion_ptw_pte                ptw0_resp_data;

  et_link_neigh_req_info_t      pt_req;
  logic                         pt_req_valid;
  et_link_rsp_info_t            pt_rsp;
  logic                         pt_rsp_valid;

  always_comb begin
    ptw0_req_data                = '0;
    ptw0_req_valid               = '0;
    ptw0_invalidate              = '0;
    ptw0_req_data[`MIN_PER_PTW]  = ptw_req_data[0];
    ptw0_req_valid[`MIN_PER_PTW] = ptw_req_valid[0];
    ptw0_invalidate[`MIN_PER_PTW] = ptw_invalidate[0];
  end

  assign ptw_req_ready  = {1'b0, ptw0_req_ready[`MIN_PER_PTW]};
  assign ptw_resp_valid = {1'b0, ptw0_resp_valid[`MIN_PER_PTW]};
  assign ptw_resp_data  = {ptw0_resp_data, ptw0_resp_data};

  neigh_shared_ptw #(
    .N_REQS ( NR_PREQ )
  ) ptw0 (
    .clock                     ( clock             ),
    .reset                     ( reset             ),
    .ioshire                   ( 1'b0              ),
    .req_data                  ( ptw0_req_data     ),
    .req_valid                 ( ptw0_req_valid    ),
    .req_ready                 ( ptw0_req_ready    ),
    .invalidate                ( ptw0_invalidate   ),
    .mprot                     ( '0                ),
    .vmspagesize               ( tlb_entry_type_2M ),
    .resp_data                 ( ptw0_resp_data    ),
    .resp_valid                ( ptw0_resp_valid   ),
    .mem_miss_req_disable_next ( 1'b0              ),
    .mem_miss_req_info         ( pt_req            ),
    .mem_miss_req_valid        ( pt_req_valid      ),
    .mem_miss_req_ready        ( 1'b1              ),
    .mem_fill_req_info         ( pt_rsp            ),
    .mem_fill_req_valid        ( pt_rsp_valid      ),
    .mem_fill_req_ready        (                   ),
    .dbg_sm_signals            (                   )
  );

  // ------------------------------------------------------------------------
  // Memory model
  //   Code: 32-bit word w of the line at PA a is {a[31:6], w}, so word 0 of
  //   the fetched chunk is the line address.
  //   Page table: 64-bit PTEs in a sparse array.
  // ------------------------------------------------------------------------
  logic [63:0] pte_mem [logic [`PA_RANGE]];

  function automatic logic [63:0] pte(logic [`PA_RANGE] pa, bit leaf);
    minion_ptw_pte p;
    p     = '0;
    p.ppn = (`CSR_SATP_PPN_SZ)'(pa >> 12);
    p.v   = 1'b1;
    if (leaf) begin
      p.r = 1'b1; p.x = 1'b1; p.a = 1'b1; p.d = 1'b1;
    end
    return 64'(p);
  endfunction

  function automatic logic [`ICACHE_BLOCK_BITS-1:0] code_line(logic [`PA_RANGE] pa);
    for (int w = 0; w < `ICACHE_BLOCK_BITS/32; w++)
      code_line[w*32 +: 32] = {pa[31:6], 6'(w)};
  endfunction

  function automatic logic [`ET_LINE_DATA_SIZE-1:0] pt_line(logic [`PA_RANGE] pa);
    logic [`PA_RANGE] base;
    base = {pa[`PA_MSB:6], 6'b0};
    for (int e = 0; e < 8; e++) begin
      logic [`PA_RANGE] ea;
      ea = base + `PA_SIZE'(e * 8);
      pt_line[e*64 +: 64] = pte_mem.exists(ea) ? pte_mem[ea] : 64'b0;
    end
  endfunction

  // Correct RISC-V translation of a VA inside the 2 MB page
  function automatic logic [`PA_RANGE] ref_pa(logic [47:0] va);
    return {PAGE_PA[`PA_MSB:21], va[20:0]};
  endfunction

  // Code fills to the I-cache (and the L1 data SRAM wrap)
  int               l2_due_q [$];
  logic [`PA_RANGE] l2_pa_q  [$];
  logic [`PA_RANGE] l2_log_pa  [$];
  int               l2_log_cyc [$];

  always @(posedge clock) begin
    if (!reset && l2_req_valid) begin
      l2_due_q.push_back(cyc + L2_LAT);
      l2_pa_q.push_back(l2_req.address[`PA_RANGE]);
      l2_log_pa.push_back(l2_req.address[`PA_RANGE]);
      l2_log_cyc.push_back(cyc);
    end

    l2_rsp_valid <= 1'b0;
    if (l2_due_q.size() != 0 && l2_due_q[0] == cyc + 1) begin
      et_link_rsp_info_t rsp;
      rsp        = '0;
      rsp.dest   = `ET_LINK_DEST_SIZE'(ET_LINK_NEIGH_SRC_Icache);
      rsp.wdata  = 1'b1;
      rsp.opcode = ET_LINK_RSP_AckData;
      rsp.data   = code_line(l2_pa_q[0]);
      rsp.size   = ET_LINK_Line;
      l2_rsp       <= rsp;
      l2_rsp_valid <= 1'b1;
      void'(l2_due_q.pop_front());
      void'(l2_pa_q.pop_front());
    end
  end

  // Page-table reads from the PTW
  int               pt_due_q [$];
  logic [`PA_RANGE] pt_pa_q  [$];
  int               pt_reads = 0;

  always @(posedge clock) begin
    if (!reset && pt_req_valid) begin
      pt_due_q.push_back(cyc + L2_LAT);
      pt_pa_q.push_back(pt_req.address);
      pt_reads++;
      $display("  cyc %4d: PTW reads page-table line 0x%010h", cyc, pt_req.address);
    end

    pt_rsp_valid <= 1'b0;
    if (pt_due_q.size() != 0 && pt_due_q[0] == cyc + 1) begin
      et_link_rsp_info_t rsp;
      rsp        = '0;
      rsp.wdata  = 1'b1;
      rsp.opcode = ET_LINK_RSP_AckData;
      rsp.data   = pt_line(pt_pa_q[0]);
      rsp.size   = ET_LINK_Line;
      pt_rsp       <= rsp;
      pt_rsp_valid <= 1'b1;
      void'(pt_due_q.pop_front());
      void'(pt_pa_q.pop_front());
    end
  end

  // ------------------------------------------------------------------------
  // Monitors (requestor 0). One request is in flight at a time.
  // ------------------------------------------------------------------------
  typedef struct {
    int               step;
    int               th;
    logic [47:0]      va;
    int               t_issue;
    int               t_f2;
    logic [`PA_RANGE] f2_paddr;
    int               tlb_miss;
    int               tag_hit;
    int               t_f4;
    int               resp_miss;
    logic [`PA_RANGE] data_pa;     // line address decoded from returned data
    int               t_fill_done;
    int               l2_reqs;     // L2 code reads issued for this request
  } txn_t;

  txn_t txn [$];
  int   cur = -1;                  // open transaction
  int   fill_done_cnt = 0;
  int   ptw_ppn_seen  = -1;
  logic [`PA_RANGE] ptw_resp_pa;

  // Waveform helpers
  int               tb_step = 0;
  logic [`PA_RANGE] tb_expected_pa = '0;

  always @(posedge clock) begin
    if (!reset) begin
      if (f5_resp_fill_done[0]) begin
        fill_done_cnt++;
        if (cur >= 0 && txn[cur].t_fill_done < 0) txn[cur].t_fill_done = cyc;
      end

      if (ptw_resp_valid[0]) begin
        ptw_resp_pa = {ptw_resp_data[0].ppn[`PA_TRANS_SIZE-1:0], 12'h000};
        $display("  cyc %4d: PTW response PPN 0x%07h (PA 0x%010h), low 9 bits = 0x%03h",
                 cyc, ptw_resp_data[0].ppn[`PA_TRANS_SIZE-1:0], ptw_resp_pa,
                 ptw_resp_data[0].ppn[8:0]);
        ptw_ppn_seen = 1;
      end

      if (cur >= 0) begin
        if (dut.icache.UCACHE[0].micro_cache.f2_valid &&
            !dut.icache.UCACHE[0].micro_cache.f2_is_prefetch && txn[cur].t_f2 < 0) begin
          txn[cur].t_f2     = cyc;
          txn[cur].f2_paddr = dut.icache.UCACHE[0].micro_cache.f2_paddr;
          txn[cur].tlb_miss = dut.icache.UCACHE[0].micro_cache.f2_tlb_resp_data.miss;
          txn[cur].tag_hit  = dut.icache.UCACHE[0].micro_cache.f2_hit;
        end
        if (l2_req_valid) txn[cur].l2_reqs++;
        if (f4_resp_valid[0] && txn[cur].t_f4 < 0) begin
          txn[cur].t_f4      = cyc;
          txn[cur].resp_miss = f4_resp_miss[0];
          txn[cur].data_pa   = `PA_SIZE'({f4_resp[0].data[31:6], 6'b0});
        end
      end
    end
  end

  // ------------------------------------------------------------------------
  // Stimulus helpers. tick() returns half a cycle after a posedge.
  // ------------------------------------------------------------------------
  task automatic tick();
    @(posedge clock);
    #0.5;
  endtask

  // Minion 0 issues one fetch for thread th and waits for the F4 response.
  // On a miss it also waits for f5_resp_fill_done (the thread sleeps).
  task automatic fetch(int step, int th, logic [47:0] va);
    txn_t t;
    t.step = step; t.th = th; t.va = va; t.t_issue = cyc;
    t.t_f2 = -1; t.f2_paddr = '0; t.tlb_miss = -1; t.tag_hit = -1;
    t.t_f4 = -1; t.resp_miss = -1; t.data_pa = '0; t.t_fill_done = -1; t.l2_reqs = 0;
    txn.push_back(t);
    cur = txn.size() - 1;
    tb_step        = step;
    tb_expected_pa = ref_pa(va);

    f0_req_valid[0]            = 1'b1;
    f0_req[0]                  = '0;
    f0_req[0].thread_id        = th[`CORE_NR_THREADS_R];
    f0_req[0].vm_status.prv    = `CSR_PRV_S;
    f0_req[0].addr             = (`VA_EXT_MSB+1)'(va);
    tick();
    f0_req_valid[0] = 1'b0;

    while (txn[cur].t_f4 < 0) begin
      tick();
      if (cyc > 5000) begin $display("ERROR timeout waiting for F4"); $finish; end
    end
    if (txn[cur].resp_miss == 1)
      while (txn[cur].t_fill_done < 0) begin
        tick();
        if (cyc > 5000) begin $display("ERROR timeout waiting for fill done"); $finish; end
      end
    cur = -1;
  endtask

  // ------------------------------------------------------------------------
  // Checks and report
  // ------------------------------------------------------------------------
  int errors  = 0;
  int defects = 0;

  task automatic check(string what, longint got, longint exp, bit is_defect = 0);
    if (got == exp) $display("PASS  %-58s = 0x%0h", what, got);
    else begin
      $display("FAIL  %-58s = 0x%0h (expected 0x%0h)", what, got, exp);
      if (is_defect) defects++; else errors++;
    end
  endtask

  task automatic print_txn();
    $display("\n  %-4s %-3s %-14s %-5s %-5s %-12s %-12s %-4s %-7s %-4s %-12s %-5s %-3s",
             "step", "th", "VA", "issue", "F2", "f2_paddr", "expected PA", "TLB", "L0 tag",
             "F4", "data line PA", "fill", "L2");
    foreach (txn[k])
      $display("  %-4d %-3d 0x%012h %-5d %-5d %-12s 0x%010h %-4s %-7s %-4s %-12s %-5s %-3d",
               txn[k].step, txn[k].th, txn[k].va, txn[k].t_issue, txn[k].t_f2,
               txn[k].tlb_miss ? "-" : $sformatf("0x%010h", txn[k].f2_paddr), ref_pa(txn[k].va),
               txn[k].tlb_miss ? "miss" : "hit",
               txn[k].tlb_miss ? "-" : (txn[k].tag_hit ? "hit" : "miss"),
               txn[k].resp_miss ? "miss" : "hit",
               txn[k].resp_miss ? "-" : $sformatf("0x%010h", txn[k].data_pa),
               txn[k].t_fill_done < 0 ? "-" : $sformatf("%0d", txn[k].t_fill_done),
               txn[k].l2_reqs);
  endtask

  // ------------------------------------------------------------------------
  // Test
  // ------------------------------------------------------------------------
  initial begin
    f0_req_valid   = '0;
    f0_req         = '0;
    f0_flush_data  = '0;
    tlb_invalidate = '0;
    l2_rsp_valid   = 1'b0;
    l2_rsp         = '0;
    pt_rsp_valid   = 1'b0;
    pt_rsp         = '0;

    // Sv48 page table: L3[0] -> L2 table, L2[0] -> L1 table, L1[0] = 2 MB leaf
    pte_mem[PT_L3] = pte(PT_L2,   1'b0);
    pte_mem[PT_L2] = pte(PT_L1,   1'b0);
    pte_mem[PT_L1] = pte(PAGE_PA, 1'b1);

    satp_info = '0;
    for (int m = 0; m < NR_MIN; m++) begin
      satp_info[m].mode = `CSR_SATP_MODE_SV48;
      satp_info[m].ppn  = PT_L3[`PA_MSB:12];
    end

    $display("\n2 MB superpage alias test: esr_vmspagesize = 2 MB, Sv48, S-mode, Minion 0");
    $display("  VA_A 0x%012h -> correct PA 0x%010h", VA_A, ref_pa(VA_A));
    $display("  VA_B 0x%012h -> correct PA 0x%010h", VA_B, ref_pa(VA_B));

    repeat (10) tick();
    reset = 1'b0;
    repeat (20) tick();

    // ---- Step 0: invalidate the TLBs and flush the I-cache, once ----------
    $display("\n=== Step 0: invalidate TLBs, flush I-cache (cycle %0d) ===", cyc);
    tb_step        = 0;
    tlb_invalidate = '1;
    f0_flush_data  = '1;
    tick();
    tlb_invalidate = '0;
    f0_flush_data  = '0;
    repeat (5) tick();

    // ---- Step 1: TLB miss -------------------------------------------------
    $display("\n=== Step 1: M0/TH0 fetches VA_A (TLB miss, PTW walk) ===");
    fetch(1, 0, VA_A);

    // ---- Step 2: TLB hit, L0 tag miss ------------------------------------
    $display("\n=== Step 2: M0/TH0 fetches VA_A again (L0 tag miss, L1/L2 fill) ===");
    fetch(2, 0, VA_A);

    // ---- Step 3: TLB hit, L0 tag hit -------------------------------------
    $display("\n=== Step 3: M0/TH0 fetches VA_A again (L0 hit) ===");
    fetch(3, 0, VA_A);

    // ---- Step 4: other thread, same 2 MB page, VA[20:12] = 0x1FF ---------
    repeat (GAP) tick();
    $display("\n=== Step 4: M0/TH1 fetches VA_B, %0d cycles later ===", GAP);
    fetch(4, 1, VA_B);
    // A correct design misses here; follow it until TH1 gets its data
    if (txn[txn.size()-1].resp_miss == 1) fetch(4, 1, VA_B);

    repeat (10) tick();

    print_txn();
    $display("");

    // Sanity: steps 1-3 behave as the user flow describes
    check("step 1: TLB result (1 = miss)",                   txn[0].tlb_miss, 1);
    check("step 1: F4 miss",                                 txn[0].resp_miss, 1);
    check("step 1: f5_resp_fill_done seen",                  txn[0].t_fill_done >= 0, 1);
    check("step 1: PTW page-table reads",                    pt_reads, 3);
    check("step 2: TLB result (0 = hit)",                    txn[1].tlb_miss, 0);
    check("step 2: L0 tag hit",                              txn[1].tag_hit, 0);
    check("step 2: L2 code reads",                           txn[1].l2_reqs, 1);
    check("step 2: L2 read address",                         l2_log_pa[0], ref_pa(VA_A) & ~40'h3F);
    check("step 2: f5_resp_fill_done seen",                  txn[1].t_fill_done >= 0, 1);
    check("step 3: TLB result (0 = hit)",                    txn[2].tlb_miss, 0);
    check("step 3: F4 miss",                                 txn[2].resp_miss, 0);
    check("step 3: data line PA",                            txn[2].data_pa, ref_pa(VA_A) & ~40'h3F);
    check("step 4: TLB result (0 = hit, same 2 MB entry)",   txn[3].tlb_miss, 0);

    // The superpage checks: the defect makes these fail
    $display("");
    check("step 4: f2_paddr of VA_B",                        txn[3].f2_paddr, ref_pa(VA_B), 1);
    check("step 4: L0 tag hit (0 = miss expected)",          txn[3].tag_hit, 0, 1);
    check("step 4: data line PA returned to TH1",            txn[txn.size()-1].data_pa,
                                                             ref_pa(VA_B) & ~40'h3F, 1);

    $display("\nL2 code reads issued:");
    foreach (l2_log_pa[k]) $display("  cyc %4d: 0x%010h", l2_log_cyc[k], l2_log_pa[k]);

    $display("\n================================================");
    if (errors != 0)
      $display("TEST INVALID, %0d sanity error(s) in steps 1-3", errors);
    else if (defects != 0)
      $display("TEST FAILED: superpage alias, VA 0x%0h -> PA 0x%0h (expected 0x%0h)",
               VA_B, txn[3].f2_paddr, ref_pa(VA_B));
    else
      $display("TEST PASSED");
    $display("================================================");
    $finish;
  end

endmodule
