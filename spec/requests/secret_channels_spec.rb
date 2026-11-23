# frozen_string_literal: true

require "spec_helper"

# A value the request, query or outgoing-request record removes must not
# leave the app in another field or record of the same execution: a log
# line, an exception message, a header, a locals snapshot, an event payload.
RSpec.describe "secrets in sibling channels", type: :request do
  def in_command
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    yield
  ensure
    Railwatch.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  describe "Active Storage signed ids, which download the file on their own" do
    let(:blob) do
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new("customer file"), filename: "invoice.txt", content_type: "text/plain")
    end

    it "are filtered from the request's path and url" do
      get "/rails/active_storage/blobs/redirect/#{blob.signed_id}/invoice.txt"

      req = railwatch_records(:request).sole
      expect(req[:path]).to eq("/rails/active_storage/blobs/redirect/[FILTERED]/invoice.txt")
      expect(req[:url]).to eq("http://www.example.com/rails/active_storage/blobs/redirect/[FILTERED]/invoice.txt")
      expect(railwatch_records.to_s).not_to include(blob.signed_id)
    end

    it "are filtered from a Referer and from blob, proxy and representation URLs of this app" do
      get "/widgets", headers: { "Referer" => "http://www.example.com/rails/active_storage/blobs/redirect/SIGNEDBLOBID--abc/invoice.pdf" }

      expect(railwatch_records(:request).sole[:headers]["Referer"])
        .to eq("http://www.example.com/rails/active_storage/blobs/redirect/[FILTERED]/invoice.pdf")
      expect(Railwatch.redactor.filter_url("/rails/active_storage/blobs/proxy/SIGNEDBLOBID--abc/invoice.pdf"))
        .to eq("/rails/active_storage/blobs/proxy/[FILTERED]/invoice.pdf")
      expect(Railwatch.redactor.filter_url("/rails/active_storage/representations/redirect/SIGNEDBLOBID--abc/VARIATIONKEY--def/photo.png"))
        .to eq("/rails/active_storage/representations/redirect/[FILTERED]/[FILTERED]/photo.png")
    end
  end

  describe "Rails' own log lines, which repeat URLs the request record cleans" do
    it "filter the reset token from 'Redirected to'" do
      get "/redirect_to_reset"

      expect(railwatch_records(:request).sole[:redirect_to]).to eq("http://www.example.com/passwords/[FILTERED]/edit")
      expect(railwatch_records(:log).map { |l| l[:message] })
        .to include("Redirected to http://www.example.com/passwords/[FILTERED]/edit")
      expect(railwatch_records.to_s).not_to include("RESET_TOKEN_IN_REDIRECT")
    end

    it "drop userinfo, query and fragment from 'Redirected to'" do
      get "/redirected_with_credentials"

      line = railwatch_records(:log).map { |l| l[:message] }.find { |m| m.start_with?("Redirected to") }
      expect(line).to eq("Redirected to http://www.example.com/widgets")
    end

    it "filter the token from the routing error a request no route answered logs" do
      delete "/passwords/RESET_TOKEN_404/edit"

      messages = railwatch_records(:log).map { |l| l[:message] }
      expect(messages.join("\n")).to include('No route matches [DELETE] "/passwords/[FILTERED]/edit"')
      expect(railwatch_records.to_s).not_to include("RESET_TOKEN_404")
    end

    it "bound the work a line with many URLs costs: the first ones cleaned, the rest cut to their origin" do
      text = (1..25).map { |i| "https://u:p@api.example.test/v#{i}?key=K#{i}" }.join(" ")
      cleaned = Railwatch.redactor.filter_text_urls(text).split(" ")

      expect(cleaned.first).to eq("https://api.example.test/v1")
      expect(cleaned[19]).to eq("https://api.example.test/v20")
      expect(cleaned[20..]).to all(eq("https://api.example.test"))
      expect(cleaned.join).not_to match(/K\d|key=|u:p@/)
    end

    it "clean a URL that prose wraps in punctuation, and keep the punctuation" do
      get "/widgets" # routes load lazily in the dummy app
      cleaned = Railwatch.redactor.filter_text_urls("failed (https://app.example/reset_boom/RESET_PAREN_1). Retry.")

      expect(cleaned).to eq("failed (https://app.example/reset_boom/[FILTERED]). Retry.")
      expect(Railwatch.redactor.filter_text_urls("see https://app.example/wiki/A_(b)")).to eq("see https://app.example/wiki/A_(b)")
    end

    it "leave a line with no URL in it as it is" do
      in_command { Rails.logger.info(%(user said "hello" at a://)) }

      expect(railwatch_records(:log).sole[:message]).to eq(%(user said "hello" at a://))
    end
  end

  describe "credential header names as Hash keys" do
    let(:headers) do
      { "Authorization" => "Bearer DUMMY-BEARER", "Cookie" => "_app_session=DUMMYSESSION",
        "X-Api-Key" => "DUMMY-API-KEY", api_key: "DUMMY-SYMBOL-KEY", "Accept" => "application/json" }
    end

    it "are masked in an exception local" do
      Railwatch.config.capture_exception_locals = true
      Railwatch::Subscribers::Exceptions::Locals.install!
      in_command do
        outbound = headers
        raise ArgumentError, "partner said no (#{outbound.size})"
      rescue ArgumentError => e
        Rails.error.report(e, handled: true)
      end

      local = railwatch_records(:exception).sole[:locals]["outbound"]
      expect(local).to include('"Accept" => "application/json"')
      expect(local).not_to include("DUMMY-BEARER")
      expect(local).not_to include("DUMMYSESSION")
      expect(local).not_to include("DUMMY-API-KEY")
      expect(local).not_to include("DUMMY-SYMBOL-KEY")
    ensure
      Railwatch::Subscribers::Exceptions::Locals.uninstall!
      Railwatch.config.capture_exception_locals = false
    end

    it "are masked when an identity part sits beside a credential part in the name" do
      scrubbed = Railwatch.redactor.scrub({ "X-Remote-User-Authorization" => "Bearer DUMMY-COMBINED", "Remote-User" => "jane" })

      expect(scrubbed["X-Remote-User-Authorization"]).to eq("[FILTERED]")
      expect(scrubbed["Remote-User"]).to eq("jane")
    end

    it "are masked in a span attribute" do
      in_command { Railwatch.span("partner.call", headers: headers) { nil } }

      attribute = railwatch_records(:span).sole[:attributes]["headers"]
      expect(attribute).to include("application/json")
      expect(attribute).not_to match(/DUMMY-BEARER|DUMMYSESSION|DUMMY-API-KEY|DUMMY-SYMBOL-KEY/)
    end
  end

  describe "library error text" do
    it "masks a SQL literal in a database error's message, cause and preview when capture_sql_values is off" do
      in_command do
        Widget.where("missing_column = 'DUMMY-4111-CARD'").to_a
      rescue ActiveRecord::StatementInvalid => e
        Rails.error.report(e, handled: false)
      end

      exc = railwatch_records(:exception).sole
      expect(exc[:message]).to include("no such column: missing_column")
      expect(exc[:message]).to include("missing_column = ?")
      expect(railwatch_records.to_s).not_to include("DUMMY-4111-CARD")
    end

    it "masks a literal in a database error whose statement is longer than the message cut" do
      # The statement alone is far past the 8,192-character cut, and the
      # secret literal comes first, inside the part the cut keeps.
      ids = (1..2_500).map { "'ID-#{_1}'" }.join(",")
      in_command do
        Widget.where("missing_column = 'DUMMY-LONG-CARD' OR id IN (#{ids})").to_a
      rescue ActiveRecord::StatementInvalid => e
        Rails.error.report(e, handled: false)
      end

      exc = railwatch_records(:exception).sole
      expect(exc[:message]).to include("no such column: missing_column")
      expect(railwatch_records.to_s).not_to include("DUMMY-LONG-CARD")
    end

    it "keeps the literal when capture_sql_values is on, as the query record does" do
      Railwatch.config.capture_sql_values = true
      in_command do
        Widget.where("missing_column = 'DUMMY-4111-CARD'").to_a
      rescue ActiveRecord::StatementInvalid => e
        Rails.error.report(e, handled: true)
      end

      expect(railwatch_records(:exception).sole[:message]).to include("DUMMY-4111-CARD")
    ensure
      Railwatch.config.capture_sql_values = false
    end

    it "drops a URL's query from a Faraday error, in the exception and in outgoing_request.error" do
      stub_request(:get, %r{https://api\.example\.test/}).to_return(status: 401, body: "{}")
      conn = ::Faraday.new("https://api.example.test") do |f|
        f.use Railwatch::Faraday
        f.response :raise_error
      end
      in_command do
        conn.get("/v1/things", api_key: "DUMMYQUERYKEY")
      rescue ::Faraday::Error => e
        Rails.error.report(e, handled: false)
      end

      expect(railwatch_records(:exception).sole[:message])
        .to eq("the server responded with status 401 for GET https://api.example.test/v1/things")
      expect(railwatch_records(:outgoing_request).sole[:error])
        .to eq("Faraday::UnauthorizedError: the server responded with status 401 for GET https://api.example.test/v1/things")
      expect(railwatch_records.to_s).not_to include("DUMMYQUERYKEY")
    end
  end

  describe "structured payloads" do
    it "filters a Rails.event payload with redact_params, and an event object by member name" do
      stub_const("UserSignedUp", Struct.new(:plan, :password, keyword_init: true))
      stub_const("CardCharged", Data.define(:last4, :national_id))
      Railwatch.config.redact_params += %w[national_id]
      Railwatch.instance_variable_set(:@redactor, nil)
      in_command do
        Rails.event.notify("user.verified", national_id: "DUMMY-NID-HASH", user_id: 1)
        Rails.event.notify(UserSignedUp.new(plan: "pro", password: "hunter2-EVENT"))
        Rails.event.notify(CardCharged.new(last4: "4242", national_id: "DUMMY-NID-DATA"))
      end

      contexts = railwatch_records(:log).select { |l| l[:level] == "event" }.to_h { |l| [ l[:message], JSON.parse(l[:context]) ] }
      expect(contexts["user.verified"]).to eq("national_id" => "[FILTERED]", "user_id" => 1)
      expect(contexts["UserSignedUp"]).to eq("plan" => "pro", "password" => "[FILTERED]")
      expect(contexts["CardCharged"]).to eq("last4" => "4242", "national_id" => "[FILTERED]")
    ensure
      Railwatch.config.redact_params -= %w[national_id]
      Railwatch.instance_variable_set(:@redactor, nil)
    end

    it "filters a params object given as error context, like the same data as a Hash" do
      in_command do
        raise ArgumentError, "context demo"
      rescue ArgumentError => e
        Rails.error.report(e, handled: true, context: {
          params: ActionController::Parameters.new(user: { name: "a", password: "hunter2-PARAMS" }),
          plain: { user: { password: "hunter2-HASH" } }
        })
      end

      context = JSON.parse(railwatch_records(:exception).sole[:context])
      expect(context["params"]).to eq("user" => { "name" => "a", "password" => "[FILTERED]" })
      expect(context["plain"]).to eq("user" => { "password" => "[FILTERED]" })
    end

    it "filters a params object nested inside error context" do
      in_command do
        raise ArgumentError, "nested context demo"
      rescue ArgumentError => e
        Rails.error.report(e, handled: true, context: {
          request: { params: ActionController::Parameters.new(user: { password: "hunter2-NESTED" }) }
        })
      end

      expect(railwatch_records(:exception).sole[:context]).not_to include("hunter2-NESTED")
    end

    it "sends an event payload too large to keep as {}, never as half an object" do
      events = []
      in_command { Rails.event.notify("big.event", blob: "x" * 20_000) }
      events = railwatch_records(:log).select { _1[:message].to_s.include?("big.event") }
      events.each { |log| expect { JSON.parse(log[:context].to_s.presence || "{}") }.not_to raise_error }
    end

    it "filters LLM tool arguments and results by key when capture_llm_content is on" do
      Railwatch.config.capture_llm_content = true
      in_command do
        ActiveSupport::Notifications.instrument("tool_call.ruby_llm",
          provider: "anthropic", model: "claude-opus-5", tool_name: "lookup_customer", tool_call_id: "toolu_1",
          tool_arguments: { customer: "acme", password: "hunter2-TOOL" },
          result_content: { "card" => { "password" => "hunter2-RESULT" }, "ok" => true }) { nil }
      end

      call = railwatch_records(:llm_call).sole
      expect(call[:prompt]).to include("acme").and include("[FILTERED]")
      expect(call[:completion]).to include("[FILTERED]").and include("true")
      expect(railwatch_records.to_s).not_to match(/hunter2-TOOL|hunter2-RESULT/)
    ensure
      Railwatch.config.capture_llm_content = false
    end
  end

  describe "request headers that carry a URL" do
    let(:page) { "http://www.example.com/passwords/RESET_TOKEN_HX/edit?reset_password_token=DUMMYQUERYTOKEN" }

    it "are cleaned like Referer: query dropped, this app's token segments filtered" do
      get "/widgets", headers: {
        "HX-Current-URL" => page,
        "X-Envoy-Original-Path" => "/passwords/RESET_TOKEN_HX/edit?reset_password_token=DUMMYQUERYTOKEN",
        "X-Forwarded-Uri" => "/passwords/RESET_TOKEN_HX/edit",
        "X-Some-Vendor-Page" => page
      }

      headers = railwatch_records(:request).sole[:headers]
      expect(headers["Hx-Current-Url"]).to eq("http://www.example.com/passwords/[FILTERED]/edit")
      expect(headers["X-Envoy-Original-Path"]).to eq("/passwords/[FILTERED]/edit")
      expect(headers["X-Forwarded-Uri"]).to eq("/passwords/[FILTERED]/edit")
      expect(headers["X-Some-Vendor-Page"]).to eq("http://www.example.com/passwords/[FILTERED]/edit")
      expect(railwatch_records.to_s).not_to match(/RESET_TOKEN_HX|DUMMYQUERYTOKEN/)
    end

    it "keep no path when the request's host could not be read" do
      middleware = Railwatch::Middleware::Request.new(->(_env) { [ 200, {}, [] ] })
      headers = middleware.send(:request_headers, { "HTTP_HX_CURRENT_URL" => page, "HTTP_X_ENVOY_ORIGINAL_PATH" => "/passwords/x/edit" }, nil)

      expect(headers["Hx-Current-Url"]).to eq("http://www.example.com")
      expect(headers["X-Envoy-Original-Path"]).to eq("[FILTERED]")
    end

    it "leave an ordinary header alone" do
      get "/widgets", headers: { "Accept" => "text/html", "X-Request-Id" => "abc-123" }

      headers = railwatch_records(:request).sole[:headers]
      expect(headers["Accept"]).to eq("text/html")
      expect(headers["X-Request-Id"]).to eq("abc-123")
    end
  end

  describe "third-party credentials in an outgoing URL's path" do
    before { stub_request(:any, %r{\Ahttps?://(?:example\.test|hooks\.slack\.com|api\.telegram\.org|discord\.com)/}) }

    it "masks Slack, Telegram and Discord webhook secrets, and keeps an ordinary path" do
      in_command do
        Net::HTTP.post(URI("https://hooks.slack.com/services/T000DUMMY/B000DUMMY/DUMMYSLACKSECRET"), "{}")
        Net::HTTP.post(URI("https://hooks.slack.com/triggers/T000DUMMY/123/DUMMYTRIGGERSECRET"), "{}")
        Net::HTTP.get(URI("https://api.telegram.org/bot123456:DUMMY-TELEGRAM-TOKEN/sendMessage?chat_id=1"))
        Net::HTTP.post(URI("https://discord.com/api/webhooks/123456/DUMMYDISCORDTOKEN"), "{}")
        Net::HTTP.get(URI("http://example.test/v1/widgets/42"))
      end

      expect(railwatch_records(:outgoing_request).map { |r| r[:url] }).to eq([
        "https://hooks.slack.com/services/T000DUMMY/B000DUMMY/[FILTERED]",
        "https://hooks.slack.com/triggers/T000DUMMY/123/[FILTERED]",
        "https://api.telegram.org/bot[FILTERED]/sendMessage",
        "https://discord.com/api/webhooks/123456/[FILTERED]",
        "http://example.test/v1/widgets/42"
      ])
    end

    it "masks the segment after one the parameter filter names" do
      in_command { Net::HTTP.get(URI("http://example.test/api/password/DUMMYPATHSECRET/status")) }

      expect(railwatch_records(:outgoing_request).sole[:url]).to eq("http://example.test/api/password/[FILTERED]/status")
    end
  end
end
