# Realistic differential cases for `mix wasm.verify --cases verify/cases.exs`.
# Each is one full JSON request; the generated random-bin cases cover the malformed path.
%{
  "rebalance" => [
    # the canonical three-fund portfolio with an off-target legacy holding
    [
      ~s({"cash":5000,"tolerance":0.0025,"targets":{"VTI":0.6,"VXUS":0.3,"BND":0.1},"positions":[{"symbol":"VTI","shares":120,"price":262.41},{"symbol":"VXUS","shares":140,"price":64.77},{"symbol":"BND","shares":95,"price":73.12},{"symbol":"ARKK","shares":30,"price":51.05}]})
    ],
    # perfectly balanced already + tolerance band suppresses noise trades
    [
      ~s({"cash":0,"tolerance":0.01,"targets":{"A":0.5,"B":0.5},"positions":[{"symbol":"A","shares":100,"price":100.0},{"symbol":"B","shares":100,"price":100.0}]})
    ],
    # all cash, nothing held yet (initial buy-in)
    [
      ~s({"cash":100000,"targets":{"VTI":0.7,"BND":0.3},"positions":[{"symbol":"VTI","shares":0,"price":262.41},{"symbol":"BND","shares":0,"price":73.12}]})
    ],
    # zero tolerance, fractional prices, odd lots
    [
      ~s({"cash":137.55,"targets":{"X":0.333333,"Y":0.333333,"Z":0.333334},"positions":[{"symbol":"X","shares":7,"price":19.99},{"symbol":"Y","shares":3,"price":501.27},{"symbol":"Z","shares":211,"price":1.07}]})
    ],
    # large account: values cross the i31 and i64 integer tiers
    [
      ~s({"cash":2500000000,"targets":{"BRK":1.0},"positions":[{"symbol":"BRK","shares":4000,"price":745000.0}]})
    ],
    # sell-everything: target moves to a symbol with a tiny weight elsewhere
    [
      ~s({"cash":0,"targets":{"NEW":1.0},"positions":[{"symbol":"OLD","shares":500,"price":42.5},{"symbol":"NEW","shares":1,"price":310.0}]})
    ],
    # error paths are part of the API contract
    [~s({"targets":{"A":0.6,"B":0.6},"positions":[]})],
    [~s({"targets":{"A":1.0},"positions":[{"symbol":"A","shares":-5,"price":10}]})],
    [~s({"targets":{"A":1.0},"positions":[{"symbol":"A","shares":1,"price":10},{"symbol":"A","shares":2,"price":11}]})],
    [~s({"cash":-1,"targets":{"A":1.0},"positions":[{"symbol":"A","shares":1,"price":10}]})],
    [~s({"targets":{"MISSING":1.0},"positions":[{"symbol":"OTHER","shares":1,"price":10}]})],
    [~s([1,2,3])],
    [~s({{{)]
  ]
}
