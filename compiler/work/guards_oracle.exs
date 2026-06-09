for {label, v} <- [{"int", 5}, {"binary", "hi"}, {"list", [1,2]}, {"emptylist", []}] do
  IO.puts("#{label}\t#{Guards.t(v)}")
end
