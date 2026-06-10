-module(seed).
-behaviour(gen_server).
-export([start_link/0, capture/2, refund/2, total/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link(?MODULE, [], []).
capture(Pid, Amt) -> gen_server:call(Pid, {capture, Amt}).
refund(Pid, Amt)  -> gen_server:call(Pid, {refund, Amt}).
total(Pid)        -> gen_server:call(Pid, total).

init([]) -> {ok, #{status => new, ledger => [], amount => 0}}.

handle_call({capture, Amt}, _From, #{status := authorized} = S) ->
    E = #{type => capture, amount => Amt},
    {reply, ok, S#{status := captured, ledger := [E | maps:get(ledger, S)]}};
handle_call({capture, _}, _From, S) ->
    {reply, {error, invalid_transition}, S};
handle_call({refund, Amt}, _From, #{status := captured} = S) ->
    E = #{type => refund, amount => -Amt},
    {reply, ok, S#{status := refunded, ledger := [E | maps:get(ledger, S)]}};
handle_call(total, _From, S) ->
    T = lists:sum([maps:get(amount, X) || X <- maps:get(ledger, S)]),
    {reply, T, S};
handle_call(_, _From, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.
