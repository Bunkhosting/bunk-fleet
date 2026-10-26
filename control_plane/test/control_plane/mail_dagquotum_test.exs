defmodule ControlPlane.MailDagquotumTest do
  @moduledoc """
  Klantmail en storingsmeldingen delen het dagquotum van de mailserver.

  Is dat quotum op, dan weigert de server alles, ook de melding dat er iets mis
  is -- en dat is precies het moment waarop die melding ertoe doet. Daarom stopt
  klantmail in de app al een stukje voor de grens, en gaat een melding altijd.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias ControlPlane.Accounts.User
  alias ControlPlane.Notifier
  alias ControlPlane.RateLimiter

  # Server laat er vijf per dag toe, twee daarvan houden we vrij voor meldingen:
  # klantmail mag er dus drie.
  @limiet 5
  @reserve 2

  setup do
    RateLimiter.reset()

    eerder =
      for sleutel <- [:ops_email, :mail_daily_limit, :mail_ops_reserve],
          do: {sleutel, Application.get_env(:control_plane, sleutel)}

    Application.put_env(:control_plane, :ops_email, "ops@bunk.test")
    Application.put_env(:control_plane, :mail_daily_limit, @limiet)
    Application.put_env(:control_plane, :mail_ops_reserve, @reserve)

    on_exit(fn ->
      Enum.each(eerder, fn {sleutel, waarde} -> herstel(sleutel, waarde) end)
      RateLimiter.reset()
    end)

    %{klant: %User{name: "Klant", email: "klant@example.com"}}
  end

  defp herstel(sleutel, nil), do: Application.delete_env(:control_plane, sleutel)
  defp herstel(sleutel, waarde), do: Application.put_env(:control_plane, sleutel, waarde)

  # Haalt de mails van eerdere stappen uit de mailbox van dit proces, zodat
  # refute_email_sent/0 daarna alleen nog over de volgende stap gaat.
  defp drain_emails do
    receive do
      {:email, _} -> drain_emails()
    after
      0 -> :ok
    end
  end

  # Een bevestigingsmail, en geen resetmail: die heeft daarbinnen nog een eigen,
  # kleiner deel (zie de test daarvoor onderaan).
  defp stuur_klantmail(klant), do: Notifier.deliver_confirmation_instructions(klant, "token")

  defp assert_klantmail_verstuurd do
    assert_email_sent(fn email -> assert [{_, "klant@example.com"}] = email.to end)
  end

  test "onder de grens gaat klantmail gewoon", %{klant: klant} do
    # De tegenproef: zonder deze zou de test hieronder ook slagen als klantmail
    # nooit meer wegging.
    for _ <- 1..(@limiet - @reserve) do
      assert stuur_klantmail(klant) == :ok
      assert_klantmail_verstuurd()
    end
  end

  test "met een bijna volle teller stopt klantmail, maar gaat een melding wel", %{klant: klant} do
    for _ <- 1..(@limiet - @reserve), do: assert(stuur_klantmail(klant) == :ok)
    # De drie hierboven gingen terecht weg; refute_email_sent/0 kijkt naar de
    # hele mailbox, dus die moeten er eerst af voor hij iets betekent.
    drain_emails()

    log =
      capture_log(fn ->
        assert stuur_klantmail(klant) == {:error, :daily_quota_reserved_for_ops}
      end)

    refute_email_sent()
    # Hetzelfde spoor als een mail die de server weigert: een fout in de log.
    assert log =~ "mail delivery failed"

    for _ <- 1..@reserve do
      onderwerp = "Node stil #{System.unique_integer([:positive])}"
      assert Notifier.deliver_operational_alert(onderwerp, "bewijs") == :ok
      assert_email_sent(subject: "[Bunk] " <> onderwerp)
    end
  end

  test "zonder eigen reservering is die een vijfde van de limiet, minstens vijf", %{
    klant: klant
  } do
    # Bij 100 per dag (Resend) zou een vaste vijftig de helft van de klantmail
    # wegnemen. Limiet 10 geeft een vijfde van 2, dus de bodem van 5: klantmail
    # mag er vijf, de zesde niet.
    Application.delete_env(:control_plane, :mail_ops_reserve)
    Application.put_env(:control_plane, :mail_daily_limit, 10)

    for _ <- 1..5, do: assert(stuur_klantmail(klant) == :ok)

    capture_log(fn ->
      assert stuur_klantmail(klant) == {:error, :daily_quota_reserved_for_ops}
    end)
  end

  test "een melding gaat ook als de klantgrens al ver voorbij is", %{klant: klant} do
    # De reservering is geen tweede quotum voor meldingen: de app houdt een
    # melding nooit tegen. Of hij aankomt, beslist de server.
    for _ <- 1..(@limiet * 2), do: stuur_klantmail(klant)
    drain_emails()

    assert Notifier.deliver_operational_alert("Schijf vol", "bewijs") == :ok
    assert_email_sent(subject: "[Bunk] Schijf vol")
  end

  test "resetmails kunnen het klantquotum niet in hun eentje opmaken", %{klant: klant} do
    # Een reset vragen kan iedereen, zonder in te loggen. Met een handvol adressen
    # kon één aanvrager zo de hele dag aan klantmail opmaken. Limiet 10, reserve 2:
    # klantmail mag er acht, resetmail daarvan hooguit vier.
    Application.put_env(:control_plane, :mail_daily_limit, 10)

    for _ <- 1..4 do
      assert Notifier.deliver_reset_password_instructions(klant, "token") == :ok
    end

    capture_log(fn ->
      assert Notifier.deliver_reset_password_instructions(klant, "token") ==
               {:error, :daily_quota_reserved_for_ops}
    end)

    drain_emails()
    assert stuur_klantmail(klant) == :ok
    assert_klantmail_verstuurd()
  end

  defmodule VolleServer do
    @moduledoc false
    use Swoosh.Adapter

    # Zo antwoordt een server waarvan het quotum op is: hij weigert, hij hangt niet.
    @impl true
    def deliver(_email, _config), do: {:error, {:permanent_failure, "daily quota exceeded"}}
  end

  test "een melding die de server weigert, staat met inhoud in de log" do
    # Komt hij er ondanks de reservering niet door, dan mag hij niet stil
    # verdwijnen: wie later zoekt, moet nog kunnen lezen wat er gemeld werd.
    vorige_mailer = Application.get_env(:control_plane, ControlPlane.Mailer)
    Application.put_env(:control_plane, ControlPlane.Mailer, adapter: VolleServer)
    on_exit(fn -> Application.put_env(:control_plane, ControlPlane.Mailer, vorige_mailer) end)

    log =
      capture_log(fn ->
        assert {:error, _} = Notifier.deliver_operational_alert("Uitrol staat stil", "node 7")
      end)

    assert log =~ "operationele melding NIET verstuurd"
    assert log =~ "Uitrol staat stil"
    assert log =~ "node 7"
  end

  test "zonder MAIL_DAILY_LIMIT is er geen teller", %{klant: klant} do
    Application.delete_env(:control_plane, :mail_daily_limit)

    for _ <- 1..(@limiet * 2) do
      assert stuur_klantmail(klant) == :ok
      assert_klantmail_verstuurd()
    end
  end
end
