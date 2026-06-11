defmodule Beam2Wasm.CodegenTest do
  use ExUnit.Case, async: false

  alias Beam2Wasm.Codegen.{Common, Emit}

  describe "resolve_trims/1" do
    test "shifts Y references past a trim (trim renumbers the stack)" do
      ops = [{:move, {:x, 0}, {:y, 1}}, {:trim, 1, 1}, {:put_list, {:y, 0}, {:x, 0}, {:x, 0}}]
      assert [{:move, {:x, 0}, {:y, 1}}, {:put_list, {:y, 1}, {:x, 0}, {:x, 0}}] = Emit.resolve_trims(ops)
    end
  end

  describe "TRMC rewrite" do
    # the canonical lists:map_1 tail: call self; test_heap; put_list H, x0, x0; deallocate; return
    test "rewrites the cons-building self-call into {:trmc_cons, head}" do
      self_mfa = {:m, :f, 2}

      ops = [
        {:call, 2, {:m, :f, 2}},
        {:test_heap, 2, 1},
        {:put_list, {:y, 0}, {:x, 0}, {:x, 0}},
        {:deallocate, 1},
        :return
      ]

      {[{1, rewritten}], true} = Emit.trmc_rewrite([{1, ops}], self_mfa)
      assert [{:trmc_cons, {:y, 0}}] = rewritten
    end

    test "leaves non-matching call sites alone" do
      self_mfa = {:m, :f, 2}
      ops = [{:call, 2, {:other, :g, 2}}, {:put_list, {:y, 0}, {:x, 0}, {:x, 0}}, :return]
      assert {[{1, ^ops}], false} = Emit.trmc_rewrite([{1, ops}], self_mfa)
    end

    test "self TAIL calls become loop re-entries once any cons site exists" do
      self_mfa = {:m, :f, 1}

      ops = [
        {:call, 1, {:m, :f, 1}},
        {:put_list, {:y, 0}, {:x, 0}, {:x, 0}},
        :return,
        {:call_only, 1, {:m, :f, 1}}
      ]

      {[{1, rewritten}], true} = Emit.trmc_rewrite([{1, ops}], self_mfa)
      assert {:trmc_self_tail} in rewritten
    end
  end

  describe "i64 chain fusion" do
    setup do
      Process.put(:bignum, true)
      :ok
    end

    defp t(lo, hi), do: {:t_integer, {lo, hi}}
    @pow64 18_446_744_073_709_551_616

    test "fuses the mod-2^64 PRNG shape into one plan with boxed live-outs" do
      ops = [
        {:gc_bif, :*, {:f, 0}, 2, [{:tr, {:x, 0}, t(0, :"+inf")}, {:integer, 6_364_136_223_846_793_005}],
         {:x, 0}},
        {:gc_bif, :+, {:f, 0}, 2, [{:tr, {:x, 0}, t(0, :"+inf")}, {:integer, 1_442_695_040_888_963_407}],
         {:x, 0}},
        {:gc_bif, :rem, {:f, 0}, 2, [{:tr, {:x, 0}, {:t_integer, :any}}, {:integer, @pow64}], {:x, 0}},
        {:test_heap, 3, 1}
      ]

      [{1, [{:i64fused, plan}, {:test_heap, 3, 1}]}] = Emit.i64fuse_blocks([{1, ops}])
      assert [{{:x, 0}, _, :u64}] = plan.outs
    end

    test "REGRESSION (genfuzz GENSEED=11): a fused PREFIX re-emits its unfused tail ops" do
      # third op is unfusable (negative band operand); the first two fuse, the tail MUST survive
      bad =
        {:gc_bif, :band, {:f, 0}, 2, [{:tr, {:x, 0}, t(-100, 100)}, {:integer, -9_223_372_036_854_775_808}],
         {:x, 1}}

      ops = [
        {:gc_bif, :*, {:f, 0}, 2, [{:tr, {:x, 2}, t(0, 1000)}, {:integer, 7}], {:x, 0}},
        {:gc_bif, :+, {:f, 0}, 2, [{:tr, {:x, 0}, t(0, 7000)}, {:integer, 1}], {:x, 0}},
        bad,
        :return
      ]

      [{1, rewritten}] = Emit.i64fuse_blocks([{1, ops}])
      assert Enum.count(rewritten, &match?({:i64fused, _}, &1)) == 1
      assert bad in rewritten, "the unfusable tail op must be re-emitted, not deleted"
    end

    test "variable bsl without proven shift bounds <= 63 does not fuse into the congruence domain" do
      ops = [
        {:gc_bif, :*, {:f, 0}, 2, [{:tr, {:x, 0}, t(0, :"+inf")}, {:integer, 3}], {:x, 0}},
        {:gc_bif, :bsl, {:f, 0}, 2, [{:tr, {:x, 0}, {:t_integer, :any}}, {:tr, {:x, 1}, t(0, 200)}], {:x, 0}},
        {:gc_bif, :rem, {:f, 0}, 2, [{:tr, {:x, 0}, {:t_integer, :any}}, {:integer, @pow64}], {:x, 0}},
        :return
      ]

      [{1, rewritten}] = Emit.i64fuse_blocks([{1, ops}])

      refute Enum.any?(rewritten, fn
               {:i64fused, plan} -> Enum.any?(plan.nodes, &match?({_, _, {:shl, _, _}}, &1))
               _ -> false
             end)
    end
  end

  describe "binary literals" do
    test "small literals build via array.new_fixed; >10k bytes go through a data segment" do
      small = Common.bin_literal("hi")
      assert small =~ "array.new_fixed $bytes 2"
      Process.put(:datasegs, [])
      big = Common.bin_literal(String.duplicate("a", 10_001))
      assert big =~ "array.new_data $bytes $dataseg0"
      assert [{0, _}] = Process.get(:datasegs)
    end

    test "dataseg_string escapes non-printables as \\XX hex" do
      assert Common.dataseg_string(<<0, ?a, ?", 255>>) == "\\00a\\22\\ff"
    end
  end
end
