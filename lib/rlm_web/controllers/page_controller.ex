defmodule RLMWeb.PageController do
  use RLMWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
