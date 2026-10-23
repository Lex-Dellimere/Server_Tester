defmodule StressTester.Reach.Bot do
  @moduledoc """
  What a load bot does with a fight, once per tick: walk toward the nearest
  enemy it can see (or the middle of the map), aim, and fire when close. It
  stays inside the server's movement envelope, snaps to corrections, asks to
  respawn when it may, and says something to its team now and then.

  This is the same behaviour as the backend's own bots, because that is the
  load the server is built for: movement checks, hit tracing with lag
  compensation, and snapshots to everyone nearby.
  """

  import Bitwise

  alias StressTester.Metrics
  alias StressTester.Reach.{Fight, Wire}

  # cm/s; the server allows 850 standing, with some tolerance
  @speed 600
  @stop_short 800
  @fire_range 4_000
  @fire 1 <<< 0

  def new(shared, now) do
    %{
      asked: false,
      next_chat: shared.chat_ms && now + shared.chat_ms + :rand.uniform(max(shared.chat_ms, 1))
    }
  end

  def tick(fight, bot, shared, now) do
    fight = Fight.resend(fight, now)
    {fight, bot} = respawn(fight, bot, now)
    {fight, bot} = chat(fight, bot, shared, now)
    {drive(fight), bot}
  end

  # ask for a spawn once each time the server offers one
  defp respawn(fight, bot, now) do
    cond do
      fight.me && fight.me.can_spawn && not bot.asked ->
        {Fight.say(fight, Wire.spawn_request(0), now), %{bot | asked: true}}

      fight.me && not fight.me.can_spawn && bot.asked ->
        {fight, %{bot | asked: false}}

      true ->
        {fight, bot}
    end
  end

  defp chat(fight, %{next_chat: nil} = bot, _shared, _now), do: {fight, bot}

  defp chat(fight, bot, shared, now) when now >= bot.next_chat do
    Metrics.count("reach.chat_sent")
    {Fight.say(fight, Wire.say_team("hi"), now), %{bot | next_chat: now + shared.chat_ms}}
  end

  defp chat(fight, bot, _shared, _now), do: {fight, bot}

  # one input frame; nothing until the bot knows where it stands
  def drive(fight) do
    me = Fight.self(fight)
    pos = fight.pos || (me && {me.x, me.y, me.z})

    cond do
      pos == nil -> fight
      fight.me && (fight.me.dead || fight.me.no_body) -> Fight.input(fight, idle(pos))
      true -> Fight.input(fight, chase(fight, me, pos))
    end
  end

  defp idle({x, y, z}), do: %{x: x, y: y, z: z, vx: 0, vy: 0, vz: 0, yaw: 0, pitch: 0, buttons: 0}

  defp chase(fight, me, {x, y, z}) do
    team = me && me.team

    foe =
      fight
      |> Fight.entities()
      |> Map.values()
      |> Enum.filter(&(&1.kind in [1, 2] and &1.team != team and (&1.flags &&& 1) == 1))
      |> Enum.min_by(&dist2(&1, x, z), fn -> nil end)

    {tx, tz} = if foe, do: {foe.x, foe.z}, else: {0, 0}
    dx = tx - x
    dz = tz - z
    d = :math.sqrt(dx * dx + dz * dz)
    step = min(@speed * (fight.tick_ms || 33) / 1_000, max(d - @stop_short, 0))
    moving = step > 0 and d > 1
    {nx, nz} = if moving, do: {x + dx / d * step, z + dz / d * step}, else: {x, z}
    speed = if moving, do: @speed, else: 0

    yaw = Integer.mod(round(:math.atan2(dx, dz) / (2 * :math.pi()) * 65_536), 65_536)

    pitch =
      if foe do
        round(:math.atan2(foe.y + 120 - (y + 160), max(d, 1)) / (:math.pi() / 2) * 16_384)
        |> max(-16_384)
        |> min(16_384)
      else
        0
      end

    %{
      x: round(nx),
      y: y,
      z: round(nz),
      vx: if(moving, do: round(dx / d * speed), else: 0),
      vy: 0,
      vz: if(moving, do: round(dz / d * speed), else: 0),
      yaw: yaw,
      pitch: pitch,
      buttons: if(foe && d < @fire_range, do: @fire, else: 0)
    }
  end

  defp dist2(e, x, z), do: (e.x - x) * (e.x - x) + (e.z - z) * (e.z - z)
end
