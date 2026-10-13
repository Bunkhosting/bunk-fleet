defmodule ControlPlane.AccountsTotpTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.Totp

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "test-only-password-4f2b9c1e"})
    u
  end

  test "setup -> confirm -> active lifecycle" do
    u = user("t1@bunk.test")
    refute Totp.totp_active?(u)

    u = Totp.start_totp_setup(u)
    assert is_binary(u.totp_secret)
    refute Totp.totp_active?(u), "unconfirmed secret must not count as active"

    {:ok, u} = Totp.confirm_totp(u, NimbleTOTP.verification_code(u.totp_secret))
    assert Totp.totp_active?(u)

    assert Totp.valid_totp?(u, NimbleTOTP.verification_code(u.totp_secret))
    refute Totp.valid_totp?(u, "000000")

    {:ok, u} = Totp.disable_totp(u)
    refute Totp.totp_active?(u)
    assert is_nil(u.totp_secret)
  end

  test "confirm with a wrong code fails" do
    u = user("t2@bunk.test") |> Totp.start_totp_setup()
    assert {:error, :invalid_code} = Totp.confirm_totp(u, "000000")
    refute Totp.totp_active?(Accounts.get_user!(u.id))
  end

  test "valid_totp? is false for users without TOTP" do
    refute Totp.valid_totp?(user("t3@bunk.test"), "123456")
  end
end
