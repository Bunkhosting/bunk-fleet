defmodule ControlPlane.Console.FlowControlTest do
  @moduledoc """
  Het SSH-venster gaat pas weer open als de browserkant bijhoudt.

  Het ging na elk stuk uitvoer meteen open, en dan liet een klant met `yes` over
  een trage verbinding de mailbox van het control plane onbegrensd groeien.
  """
  use ExUnit.Case, async: true

  alias ControlPlane.Console.Session

  test "bij een korte wachtrij gaat alles meteen vrij, inclusief wat er nog openstond" do
    assert Session.vrij_te_geven(0, 512, 0) == {:nu, 512}
    assert Session.vrij_te_geven(4096, 512, 3) == {:nu, 4608}
  end

  test "bij een volle wachtrij wordt het venster vastgehouden en opgespaard" do
    assert Session.vrij_te_geven(0, 512, 100) == {:wacht, 512}
    assert Session.vrij_te_geven(512, 512, 5_000) == {:wacht, 1024}
  end

  test "een herstelronde zonder nieuwe uitvoer geeft precies de achterstand vrij" do
    assert Session.vrij_te_geven(1024, 0, 0) == {:nu, 1024}
  end
end
