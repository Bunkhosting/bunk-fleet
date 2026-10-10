defmodule ControlPlane.CreditsTest do
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Credits

  # Every user here is a CONFIRMED one: the signup bonus is granted on email
  # confirmation, not at registration, so an unconfirmed account has an empty
  # wallet and would make these balance assertions meaningless.

  test "new user receives the signup bonus" do
    u = confirmed_user_fixture("c1@bunk.test")
    assert Credits.balance_cents(u.id) == Credits.signup_bonus_cents()
  end

  test "the signup bonus is granted at most once, whatever the caller does" do
    u = confirmed_user_fixture("c1b@bunk.test")
    assert Credits.balance_cents(u.id) == Credits.signup_bonus_cents()

    # A pre-confirmation-era account carries a bonus but no confirmed_at, so
    # confirming later must not top it up a second time.
    assert {:ok, nil} = Credits.grant_signup_bonus(u.id)
    assert Credits.balance_cents(u.id) == Credits.signup_bonus_cents()
  end

  test "charge debits when affordable, rejects when not, and is atomic" do
    u = confirmed_user_fixture("c2@bunk.test")
    assert {:ok, _} = Credits.charge(u.id, 300, "vps_charge", "x")
    assert Credits.balance_cents(u.id) == Credits.signup_bonus_cents() - 300

    {:ok, _} = Credits.charge(u.id, Credits.balance_cents(u.id), "vps_charge", "x")
    assert Credits.balance_cents(u.id) == 0
    assert {:error, :insufficient_credits} = Credits.charge(u.id, 1, "vps_charge", "x")
    # rejected charge left no entry
    assert Credits.balance_cents(u.id) == 0
  end

  test "zero/under charge is a free no-op" do
    u = confirmed_user_fixture("c3@bunk.test")
    assert {:ok, nil} = Credits.charge(u.id, 0, "free", "x")
    assert Credits.balance_cents(u.id) == Credits.signup_bonus_cents()
  end

  test "refund credits back" do
    u = confirmed_user_fixture("c4@bunk.test")
    {:ok, _} = Credits.charge(u.id, 300, "vps_charge", "x")
    {:ok, _} = Credits.refund(u.id, 300, "vps_refund", "x")
    assert Credits.balance_cents(u.id) == Credits.signup_bonus_cents()
  end

  test "list_entries returns newest first" do
    u = confirmed_user_fixture("c5@bunk.test")
    {:ok, _} = Credits.charge(u.id, 100, "vps_charge", "second")
    assert hd(Credits.list_entries(u.id)).kind == "vps_charge"
  end
end
