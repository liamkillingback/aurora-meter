defmodule AuroraMeterExampleAiWeb.PageControllerTest do
  use AuroraMeterExampleAiWeb.ConnCase, async: true

  test "GET / says what this is and what it is not", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Aurora Meter, in an application"
    assert html =~ "There is no AI here and there is no payment here"
    assert html =~ "mix sample.seed"
  end
end
