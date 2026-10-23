defmodule StressTester.TemplateTest do
  use ExUnit.Case, async: true

  alias StressTester.Template

  defp render(text, vars \\ %{}), do: text |> Template.compile() |> Template.render(vars)

  test "text with no holes stays text" do
    assert Template.compile("plain") == "plain"
    assert render("plain") == "plain"
  end

  test "user and iteration" do
    vars = %{"vu" => 42, "iteration" => 3}
    assert render("u{{vu}}-{{iteration}}", vars) == "u42-3"
    assert render("{{vu:4}}", vars) == "0042"
    assert render("{{ vu }}", vars) == "42"
  end

  test "random numbers stay in range" do
    for _ <- 1..200 do
      n = render("{{rand:6}}") |> String.to_integer()
      assert n in 1..6
    end
  end

  test "uuids look like uuids and differ" do
    a = render("{{uuid}}")
    assert a =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    refute a == render("{{uuid}}")
  end

  test "the clock and the environment" do
    now = render("{{now}}") |> String.to_integer()
    assert_in_delta now, System.os_time(:millisecond), 1_000
    System.put_env("STRESS_TEMPLATE_TEST", "hello")
    assert render("{{env:STRESS_TEMPLATE_TEST}}!") == "hello!"
    assert render("{{env:STRESS_TEMPLATE_UNSET}}") == ""
  end

  test "captured variables and missing ones" do
    assert render("Bearer {{token}}", %{"token" => "abc"}) == "Bearer abc"
    assert render("[{{nothing}}]") == "[]"
    assert render("{{n}}", %{"n" => 5}) == "5"
    assert render("{{o}}", %{"o" => %{"a" => 1}}) == ~s({"a":1})
  end

  test "values nested in JSON are filled" do
    value = Template.compile_value(%{"name" => "u{{vu}}", "tags" => ["a", "{{vu}}"], "n" => 1})

    assert Template.render_value(value, %{"vu" => 7}) == %{
             "name" => "u7",
             "tags" => ["a", "7"],
             "n" => 1
           }
  end

  test "dig walks maps and lists" do
    data = %{"a" => %{"b" => [%{"c" => "x"}, %{"c" => "y"}]}}
    assert Template.dig(data, "a.b.1.c") == "y"
    assert Template.dig(data, "a.zzz") == nil
    assert Template.dig(data, "a.b.nine") == nil
    assert Template.dig(data, "") == data
    assert Template.dig(nil, "a") == nil
  end
end
