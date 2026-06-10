-module(smoke).
-export([add/2, dbl/1, fact/1, fib/1]).

add(A, B) -> A + B.

dbl(X) -> X * 2.

fact(0) -> 1;
fact(N) when N > 0 -> N * fact(N - 1).

fib(0) -> 0;
fib(1) -> 1;
fib(N) when N > 1 -> fib(N - 1) + fib(N - 2).
