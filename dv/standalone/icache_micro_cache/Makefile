# Copyright (c) 2026 Ainekko
# SPDX-License-Identifier: Apache-2.0

BUILD_DIR ?= .

all: sim

DESIGN := icache_micro_cache
TEST_DIR := $(REPOROOT)/dv/standalone/$(DESIGN)
BUILD_LOG := $(BUILD_DIR)/build.log
SIMV_LOG := $(BUILD_DIR)/simv.log
TB_TOP := $(DESIGN)_tb

TRACE := -kdb -lca -debug_access+all
TRACE += +vcs+fsdbon # verdi -ssf novas.fsdb &
TRACE += +vcs+vcdpluson # dve -full64 -vpd vcdplus.vpd

# ET_USE_ASIC_MEMS is deliberately left undefined so the generic behavioural
# models under rtl/libs/rf_latches are used for the micro tag and micro data
# arrays.
VCS_OPTS := -sverilog -full64 $(DEFINES) $(TRACE) -timescale=1ns/1ps +lint=PCWM
# No concurrent assertions in this testbench; the lost-request check is procedural.

# neigh_top_rtl.f brings in libs (rf_latch_1r_1w_par, rf_latch_1r_1w_dec),
# neigh_channel (-y over shire/neigh/icache), esr and minion (tlb_top).
FILE_LIST_VCS := -f $(RTLROOT)/shire/neigh/neigh_top_rtl.f \
                 -f $(RTLROOT)/shire/neigh/neigh_top_vcs_defines.f \
                 +incdir+$(RTLROOT)/inc +libext+.v+.sv

FILE_LIST := $(TEST_DIR)/$(TB_TOP).sv +incdir+$(RTLROOT)/inc +libext+.v+.sv \
			 $(RTLROOT)/shire/neigh/icache/*.v

$(BUILD_DIR)/simv: FORCE
	vcs $(VCS_OPTS) $(TEST_DIR)/$(TB_TOP).sv $(FILE_LIST_VCS) -o $(BUILD_DIR)/simv -Mdir=$(BUILD_DIR)/csrc > $(BUILD_LOG)

sim: $(BUILD_DIR)/simv
	$(BUILD_DIR)/simv | tee $(SIMV_LOG)

FORCE:

# slang version 9.1.214+68cad5ea0
# export PATH="/home/alilic/tools/slang/build/bin:$PATH"
slang:
	slang --top $(TB_TOP) $(FILE_LIST) -Wno-unconnected-port -Wno-duplicate-definition --std 1800-2017 --error-limit=1000

.phony: FORCE clean sim slang

clean:
	rm -rf $(BUILD_DIR)/csrc/ $(BUILD_DIR)/simv $(BUILD_DIR)/simv.daidir/ $(BUILD_DIR)/verdi_config_file $(BUILD_DIR)/DVEfiles/ $(BUILD_DIR)/dve_report* $(BUILD_DIR)/novas* $(BUILD_DIR)/ucli.key $(BUILD_DIR)/vcdplus.vpd $(BUILD_DIR)/novas.fsdb $(BUILD_DIR)/verdiLog/ $(SIMV_LOG) $(BUILD_LOG)
