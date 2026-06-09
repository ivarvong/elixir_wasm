defmodule Hav do
  @r 3440.065
  def dist(lat1, lon1, lat2, lon2) do
    p1 = lat1 * :math.pi() / 180.0
    p2 = lat2 * :math.pi() / 180.0
    dp = (lat2 - lat1) * :math.pi() / 180.0
    dl = (lon2 - lon1) * :math.pi() / 180.0
    a = :math.sin(dp / 2.0) * :math.sin(dp / 2.0) +
        :math.cos(p1) * :math.cos(p2) * :math.sin(dl / 2.0) * :math.sin(dl / 2.0)
    c = 2.0 * :math.atan2(:math.sqrt(a), :math.sqrt(1.0 - a))
    @r * c
  end
end
