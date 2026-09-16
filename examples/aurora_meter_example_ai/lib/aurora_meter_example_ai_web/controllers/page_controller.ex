defmodule AuroraMeterExampleAiWeb.PageController do
  use AuroraMeterExampleAiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
