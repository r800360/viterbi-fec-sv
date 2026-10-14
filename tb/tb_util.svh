// tb_util.svh - checking helpers shared by every testbench in this workspace.
// A testbench declares `TB_COUNTERS once, compares with `CHECK_EQ / `CHECK, and ends with `TB_FINISH, which prints
// exactly one line "RESULT: PASS <n> checks" or "RESULT: FAIL <k> of <n> checks". The run scripts read that line.
// Comparisons use !== so an X or Z on the DUT side is always a mismatch. Macro arguments have unusual names
// (ACT_, EXP_, WHAT_) because Icarus substitutes macro arguments even inside string literals. Arguments are
// evaluated more than once, so they must not have side effects (no pop_front(), $urandom, ++ in them).
`ifndef TB_UTIL_SVH
`define TB_UTIL_SVH

`define TB_COUNTERS int tb_checks = 0; int tb_errors = 0; int tb_max_print = 25;

`define CHECK_EQ(ACT_, EXP_, WHAT_) \
  begin \
    tb_checks++; \
    if ((ACT_) !== (EXP_)) begin \
      tb_errors++; \
      if (tb_errors <= tb_max_print) \
        $display("[%0t] MISMATCH %s: got %0h, expected %0h", $time, WHAT_, ACT_, EXP_); \
    end \
  end

`define CHECK(COND_, WHAT_) \
  begin \
    tb_checks++; \
    if (!(COND_)) begin \
      tb_errors++; \
      if (tb_errors <= tb_max_print) $display("[%0t] FAILED %s", $time, WHAT_); \
    end \
  end

`define TB_FINISH \
  begin \
    if (tb_errors > tb_max_print) $display("... %0d further mismatches not printed", tb_errors - tb_max_print); \
    if (tb_errors == 0) $display("RESULT: PASS %0d checks", tb_checks); \
    else $display("RESULT: FAIL %0d of %0d checks", tb_errors, tb_checks); \
    $finish; \
  end

`endif
