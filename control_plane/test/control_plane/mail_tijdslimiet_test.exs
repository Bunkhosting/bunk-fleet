defmodule ControlPlane.MailTijdslimietTest do
  @moduledoc """
  Een mailserver die niet antwoordt, houdt het control plane niet vast.

  gen_smtp wacht tot twintig minuten op een antwoord, en dat is niet in te
  stellen. Meldingen gaan midden in de reconciler-ronde de deur uit: een relay
  die de verbinding aannam en zweeg, legde twintig minuten lang alles stil wat
  die ronde doet.
  """
  use ControlPlane.DataCase, async: false

  alias ControlPlane.Notifier

  defmodule ZwijgendeServer do
    @moduledoc false
    use Swoosh.Adapter

    @impl true
    def deliver(_email, _config) do
      Process.sleep(:infinity)
    end
  end

  setup do
    vorige_mailer = Application.get_env(:control_plane, ControlPlane.Mailer)
    vorige_ops = Application.get_env(:control_plane, :ops_email)
    vorige_timeout = Application.get_env(:control_plane, :mail_timeout_ms)

    Application.put_env(:control_plane, ControlPlane.Mailer, adapter: ZwijgendeServer)
    Application.put_env(:control_plane, :ops_email, "ops@bunk.test")
    Application.put_env(:control_plane, :mail_timeout_ms, 200)

    on_exit(fn ->
      Application.put_env(:control_plane, ControlPlane.Mailer, vorige_mailer)
      herstel(:ops_email, vorige_ops)
      herstel(:mail_timeout_ms, vorige_timeout)
    end)
  end

  defp herstel(sleutel, nil), do: Application.delete_env(:control_plane, sleutel)
  defp herstel(sleutel, waarde), do: Application.put_env(:control_plane, sleutel, waarde)

  test "een zwijgende server geeft na de tijdslimiet een fout, geen hang" do
    {tijd, uitkomst} =
      :timer.tc(fn ->
        Notifier.deliver_operational_alert("proef #{System.unique_integer()}", "x")
      end)

    assert uitkomst == {:error, :timeout}
    assert tijd < 2_000_000
  end
end
