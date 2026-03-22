defmodule Traitee.DoctorTest do
  use ExUnit.Case, async: true

  alias Traitee.Doctor

  import Traitee.Fixtures

  describe "format_report/1" do
    test "formats a report with all checks" do
      results = doctor_results()
      report = Doctor.format_report(results)

      assert is_binary(report)
      assert report =~ "Traitee Doctor"
      assert report =~ "[OK]"
      assert report =~ "passed"
    end

    test "shows warnings" do
      results = [
        %{check: :channels, status: :warning, message: "No channels enabled"}
      ]

      report = Doctor.format_report(results)
      assert report =~ "[WARN]"
      assert report =~ "channels"
    end

    test "shows errors" do
      results = [
        %{check: :database, status: :error, message: "SQLite error: connection refused"}
      ]

      report = Doctor.format_report(results)
      assert report =~ "[ERR]"
      assert report =~ "database"
    end

    test "summary includes counts" do
      results = doctor_results()
      report = Doctor.format_report(results)
      assert report =~ "passed"
      assert report =~ "warnings"
    end

    test "shows 'issues found' when errors present" do
      results = [
        %{check: :database, status: :error, message: "down"},
        %{check: :elixir, status: :ok, message: "1.17"}
      ]

      report = Doctor.format_report(results)
      assert report =~ "issues found"
    end

    test "shows 'system healthy' when no errors" do
      results = [
        %{check: :elixir, status: :ok, message: "1.17"},
        %{check: :channels, status: :warning, message: "none"}
      ]

      report = Doctor.format_report(results)
      assert report =~ "system healthy"
    end
  end
end
