defmodule TermTest do
  def s3len, do: length(Enum.sort([3, 1, 2]))      # literal ints, length
  def s3hd, do: hd(Enum.sort([3, 1, 2]))           # literal ints, hd
  def argsort_hd(a), do: hd(Enum.sort(a))          # arg list, hd
  def argsort_len(a), do: length(Enum.sort(a))     # arg list, length
end
