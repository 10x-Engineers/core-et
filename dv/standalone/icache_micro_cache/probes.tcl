# Copyright (c) 2026 Ainekko
# SPDX-License-Identifier: Apache-2.0
#
# Xcelium probe setup for the icache_micro_cache testbenches.
# Loaded by Makefile.xcelium through -input. The testbench module name comes
# from the TB environment variable exported by the Makefile.
#
# Batch runs add -run -exit on the xrun command line. In the GUI the
# simulation waits at time 0 with the waveform window already open.

set tb $::env(TB)

database -open waves -into waves.shm -default -event
# Whole testbench hierarchy, DUT internals included, so the prefetch, nomh and
# miss FSM states are available without re-running. -all leaves out unpacked
# arrays; -memories adds them (m_state, m_kick and the other per-minion arrays
# of the testbench model)
probe -create $tb -depth all -all -memories -shm -database waves
