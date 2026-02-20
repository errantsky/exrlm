defmodule RlmWebWeb.PageController do
  use RlmWebWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
