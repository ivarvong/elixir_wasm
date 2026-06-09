
defmodule NavAbi do
  @earth_radius_nm 3440.065

  def haversine_nm(lat1, lng1, lat2, lng2) do
    dlat = rad(lat2 - lat1)
    dlng = rad(lng2 - lng1)
    rlat1 = rad(lat1)
    rlat2 = rad(lat2)

    a = :math.sin(dlat / 2.0) * :math.sin(dlat / 2.0) +
      :math.cos(rlat1) * :math.cos(rlat2) * :math.sin(dlng / 2.0) * :math.sin(dlng / 2.0)

    c = 2.0 * :math.atan2(:math.sqrt(a), :math.sqrt(1.0 - a))
    @earth_radius_nm * c
  end

  defp rad(degrees), do: degrees * :math.pi() / 180.0
end
