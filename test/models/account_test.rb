require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "accounts are not superusers by default" do
    account = create_account
    assert_equal false, account.superuser?
  end

  test "an account can be made a superuser" do
    account = create_account(superuser: true)
    assert_equal true, account.superuser?
  end

  test "superuser can be toggled after creation" do
    account = create_account
    account.update(superuser: true)
    assert_equal true, account.reload.superuser?
  end
end
