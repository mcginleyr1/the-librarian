defmodule Librarian.SettingsTest do
  use Librarian.DataCase, async: true

  alias Librarian.Settings

  describe "get_settings/0" do
    test "returns nil when no settings exist" do
      assert Settings.get_settings() == nil
    end
  end

  describe "save_settings/1" do
    test "creates settings when none exist" do
      attrs = %{
        b2_key_id: "key123",
        b2_application_key: "appsecret",
        b2_bucket_name: "my-bucket",
        b2_endpoint: "s3.us-west-004.backblazeb2.com"
      }

      assert {:ok, settings} = Settings.save_settings(attrs)
      assert settings.id == 1
      assert settings.b2_key_id == "key123"
      assert settings.b2_bucket_name == "my-bucket"
    end

    test "updates existing settings (upsert)" do
      Settings.save_settings(%{b2_key_id: "old", b2_bucket_name: "bucket"})
      {:ok, updated} = Settings.save_settings(%{b2_key_id: "new", b2_bucket_name: "bucket"})

      assert updated.b2_key_id == "new"
      assert Settings.get_settings().b2_key_id == "new"
    end
  end

  describe "configured?/0" do
    test "returns false when no settings" do
      refute Settings.configured?()
    end

    test "returns false when key fields are nil" do
      Settings.save_settings(%{b2_key_id: nil, b2_application_key: nil})
      refute Settings.configured?()
    end

    test "returns true when key fields are present" do
      Settings.save_settings(%{
        b2_key_id: "key",
        b2_application_key: "secret",
        b2_bucket_name: "bucket",
        b2_endpoint: "s3.us-west-004.backblazeb2.com"
      })

      assert Settings.configured?()
    end
  end
end
