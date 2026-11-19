# frozen_string_literal: true

require "spec_helper"

RSpec.describe "redaction and rejection", type: :request do
  before do
    Rails.cache.clear
    3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }
  end

  after do
    Railwatch.config.redactors.clear
    Railwatch.config.rejectors.clear
    Railwatch.config.ignored_cache_key_prefixes.clear
    Rails.cache.clear
  end

  describe "header masking" do
    it "masks exact and credential-shaped header names, leaving ordinary headers intact" do
      get "/widgets", headers: {
        "Authorization" => "Bearer secret",
        "Cookie" => "session=abc",
        "X-CSRF-Token" => "tok123",
        "X-API-Key" => "api-secret",
        "X-Auth-Token" => "auth-secret",
        "X-Hub-Signature-256" => "github-secret",
        "Stripe-Signature" => "stripe-secret",
        "X-Shopify-Hmac-Sha256" => "shopify-secret",
        "X-Aws-Credential" => "aws-credential",
        "X-Access-Key" => "access-key",
        "X-Jwt-Assertion" => "jwt-secret",
        "X-Bearer" => "bearer-secret",
        "X-Private-Key" => "private-key",
        "X-AuthToken" => "concatenated-auth-secret",
        "X-AccessToken" => "concatenated-access-secret",
        "X-BearerToken" => "concatenated-bearer-secret",
        "X-HmacSignature" => "concatenated-hmac-secret",
        "X-CSRFToken" => "concatenated-csrf-secret",
        "X-XSRFToken" => "concatenated-xsrf-secret",
        "X-ApiToken" => "concatenated-api-secret",
        "X-ClientToken" => "concatenated-client-secret",
        "X-SessionToken" => "concatenated-session-secret",
        "X-RefreshToken" => "concatenated-refresh-secret",
        "X-SecurityToken" => "concatenated-security-secret",
        "X-ServiceToken" => "concatenated-service-secret",
        "X-IdentityToken" => "concatenated-identity-secret",
        "X-IdToken" => "concatenated-id-secret",
        "X-SecretKey" => "concatenated-secret-key",
        "X-SigningKey" => "concatenated-signing-key",
        "X-EncryptionKey" => "concatenated-encryption-key",
        "X-Authenticated-User" => "diagnostic-user",
        "X-Tokenizer-Version" => "v2",
        "X-ApiTokenizer" => "v3",
        "X-ClientTokenization" => "enabled",
        "X-SessionTokenizer" => "v4",
        "X-RefreshTokenizer" => "v5",
        "X-SecretKeyboard" => "diagnostic",
        "X-Secretariat" => "office",
        "X-Custom" => "keep-me"
      }
      req = railwatch_records(:request).sole
      expect(req[:headers]["Authorization"]).to eq("[FILTERED]")
      expect(req[:headers]["Cookie"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Csrf-Token"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Api-Key"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Auth-Token"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Hub-Signature-256"]).to eq("[FILTERED]")
      expect(req[:headers]["Stripe-Signature"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Shopify-Hmac-Sha256"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Aws-Credential"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Access-Key"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Jwt-Assertion"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Bearer"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Private-Key"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Authtoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Accesstoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Bearertoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Hmacsignature"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Csrftoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Xsrftoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Apitoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Clienttoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Sessiontoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Refreshtoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Securitytoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Servicetoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Identitytoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Idtoken"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Secretkey"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Signingkey"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Encryptionkey"]).to eq("[FILTERED]")
      expect(req[:headers]["X-Authenticated-User"]).to eq("diagnostic-user")
      expect(req[:headers]["X-Tokenizer-Version"]).to eq("v2")
      expect(req[:headers]["X-Apitokenizer"]).to eq("v3")
      expect(req[:headers]["X-Clienttokenization"]).to eq("enabled")
      expect(req[:headers]["X-Sessiontokenizer"]).to eq("v4")
      expect(req[:headers]["X-Refreshtokenizer"]).to eq("v5")
      expect(req[:headers]["X-Secretkeyboard"]).to eq("diagnostic")
      expect(req[:headers]["X-Secretariat"]).to eq("office")
      expect(req[:headers]["X-Custom"]).to eq("keep-me")
    end
  end

  describe "identity and credential headers a proxy or gateway adds" do
    it "masks the user, email, client certificate, gateway key, session id and password headers" do
      sensitive = {
        "X-Forwarded-Email" => "alice@example.com",
        "X-Forwarded-User" => "alice",
        "X-Remote-User" => "alice",
        "X-Client-Cert" => "-----BEGIN CERTIFICATE-----",
        "X-Forwarded-Client-Cert" => "Hash=abc;Subject=alice",
        "Ocp-Apim-Subscription-Key" => "azure-gateway-key",
        "X-Session-Id" => "session-abc",
        "X-Password" => "hunter2"
      }
      get "/widgets", headers: sensitive.merge("User-Agent" => "Mozilla/5.0", "X-Request-Id" => "req-1")

      headers = railwatch_records(:request).sole[:headers]
      sensitive.each_key { |name| expect(headers[name]).to eq("[FILTERED]"), name }
      expect(headers["User-Agent"]).to eq("Mozilla/5.0")
      expect(headers["X-Request-Id"]).to eq("req-1")
    end
  end

  describe "identity headers from cloud load balancers and identity proxies (GA review finding 6)" do
    it "masks ALB OIDC data, Azure client principal, DPoP proofs, bare session and email/username headers" do
      sensitive = {
        "X-Amzn-Oidc-Data" => "eyJalb.oidc",
        "X-Amzn-Oidc-Identity" => "alb-subject",
        "X-Ms-Client-Principal" => "eyJazure",
        "X-Ms-Client-Principal-Name" => "alice@example.com",
        "Dpop" => "eyJdpop",
        "X-Session" => "sess",
        "Session" => "sess2",
        "X-User-Email" => "alice@example.com",
        "X-Email" => "alice@example.com",
        "X-Forwarded-Preferred-Username" => "alice"
      }
      get "/widgets", headers: sensitive.merge("X-Sessions-Count" => "3", "X-Request-Id" => "req-1")

      headers = railwatch_records(:request).sole[:headers]
      sensitive.each_key { |name| expect(headers[name]).to eq("[FILTERED]"), name }
      expect(headers["X-Request-Id"]).to eq("req-1")
      expect(headers["X-Sessions-Count"]).to eq("3"), "only a whole session segment"
    end

    it "keeps the path of a rewriting proxy's original-URL headers, never their query" do
      original = {
        "X-Original-Url" => "/reset?token=abc",
        "X-Original-Uri" => "/reset?token=abc#frag",
        "X-Rewrite-Url" => "https://user:pw@www.example.com/reset?token=abc"
      }
      get "/widgets", headers: original

      headers = railwatch_records(:request).sole[:headers]
      expect(headers["X-Original-Url"]).to eq("/reset")
      expect(headers["X-Original-Uri"]).to eq("/reset")
      expect(headers["X-Rewrite-Url"]).to eq("https://www.example.com/reset")
    end

    it "filters a reset token in the path of an original-URL header" do
      get "/widgets", headers: { "X-Original-Url" => "/passwords/RESET_TOKEN_abc/edit?x=1" }

      expect(railwatch_records(:request).sole[:headers]["X-Original-Url"]).to eq("/passwords/[FILTERED]/edit")
    end
  end

  describe "Referer and Origin (GA review finding 5)" do
    it "never stores a reset, magic-link or OAuth secret riding in the Referer's query or fragment" do
      get "/widgets", headers: {
        "Referer" => "https://user:pw@customer.test/password/reset/edit?token=SECRET_RESET_TOKEN_123#frag",
        "Origin" => "https://customer.test"
      }

      headers = railwatch_records(:request).sole[:headers]
      expect(headers["Referer"]).to eq("https://customer.test/password/reset/edit")
      expect(headers["Origin"]).to eq("https://customer.test")
    end

    it "keeps the Referer's query, not its fragment, when the app opts in to browser query strings" do
      Railwatch.config.capture_browser_query_strings = true
      get "/widgets", headers: { "Referer" => "https://customer.test/search?q=boots#results" }

      expect(railwatch_records(:request).sole[:headers]["Referer"]).to eq("https://customer.test/search?q=boots")
    ensure
      Railwatch.config.capture_browser_query_strings = false
    end
  end

  describe "payload masking" do
    it "masks Rails filter_parameters fields in the payload, including nested hashes and arrays" do
      Railwatch.config.capture_request_payload = true
      get "/boom", params: {
        secret_code: "shh",
        user: { ssn: "111-22-3333" },
        items: [ { secret_code: "x" }, { secret_code: "y" } ]
      }

      payload = railwatch_records(:request).sole[:payload]
      expect(payload["secret_code"]).to eq("[FILTERED]")
      expect(payload["user"]["ssn"]).to eq("111-22-3333")
      expect(payload["items"].map { |i| i["secret_code"] }).to eq(%w[[FILTERED] [FILTERED]])
    ensure
      Railwatch.config.capture_request_payload = false
    end

    it "omits the payload when capture_request_payload is off, even though the request raised" do
      Railwatch.config.capture_request_payload = false
      get "/boom", params: { secret_code: "shh" }
      expect(railwatch_records(:request).sole[:payload]).to be_nil
    end

    it "omits the payload when the request didn't raise, even with capture_request_payload on" do
      Railwatch.config.capture_request_payload = true
      get "/widgets"
      expect(railwatch_records(:request).sole[:payload]).to be_nil
    ensure
      Railwatch.config.capture_request_payload = false
    end
  end

  describe "Railwatch.redact_queries" do
    it "mutates the sql of the shipped query record" do
      Railwatch.redact_queries { |rec| rec[:sql] = "REDACTED SQL" }
      get "/widgets"

      queries = railwatch_records(:query)
      expect(queries).not_to be_empty
      expect(queries.map { |q| q[:sql] }.uniq).to eq([ "REDACTED SQL" ])
    end

    it "drops the record instead of shipping it when the redactor raises" do
      Railwatch.redact_queries { |_rec| raise "boom in redactor" }
      get "/widgets"

      expect(railwatch_records(:query)).to be_empty
      expect(railwatch_records(:request)).not_to be_empty
    end
  end

  describe "Railwatch.redact_requests / redact_exceptions / redact_commands" do
    it "runs the request redactor on the shipped request record" do
      Railwatch.redact_requests { |rec| rec[:url] = "REDACTED URL" }
      get "/widgets"

      expect(railwatch_records(:request).sole[:url]).to eq("REDACTED URL")
    end

    it "runs the exception redactor on the shipped exception record" do
      Railwatch.redact_exceptions { |rec| rec[:message] = "REDACTED MESSAGE" }
      get "/boom"

      expect(railwatch_records(:exception).sole[:message]).to eq("REDACTED MESSAGE")
    end

    it "runs the command redactor on the shipped command record" do
      require "rake"
      Railwatch.redact_commands { |rec| rec[:command] = "REDACTED COMMAND" }
      Rake::Task.define_task(:railwatch_redact_demo) { Widget.count }
      Rake::Task[:railwatch_redact_demo].execute

      expect(railwatch_records(:command).sole[:command]).to eq("REDACTED COMMAND")
    end
  end

  describe "reject_* hooks" do
    it "drops a query when reject_queries returns true for it" do
      Railwatch.reject_queries { |rec| rec[:sql].to_s.include?("gadgets") }
      get "/widgets"

      queries = railwatch_records(:query)
      expect(queries).not_to be_empty
      expect(queries.map { |q| q[:sql] }).to all(satisfy { |sql| !sql.include?("gadgets") })
    end

    it "drops a cache_event when reject_cache_events returns true for it" do
      Railwatch.reject_cache_events { |rec| rec[:type] == "hit" }
      get "/cached"

      types = railwatch_records(:cache_event).map { |e| e[:type] }
      expect(types).not_to include("hit")
      expect(types).to include("write")
    end

    it "drops an outgoing_request when reject_outgoing_requests returns true for it" do
      Railwatch.reject_outgoing_requests { |rec| rec[:host] == "example.test" }
      get "/outbound"

      expect(railwatch_records(:outgoing_request)).to be_empty
    end
  end

  describe "Railwatch.reject_cache_keys" do
    it "rejects an exact string match" do
      Railwatch.reject_cache_keys([ "widgets/count" ])
      get "/cached"
      expect(railwatch_records(:cache_event)).to be_empty
    end

    it "rejects by a trailing-star prefix" do
      Railwatch.reject_cache_keys([ "widgets/*" ])
      get "/cached"
      expect(railwatch_records(:cache_event)).to be_empty
    end

    it "rejects by a leading-caret regexp string" do
      Railwatch.reject_cache_keys([ "^widgets/" ])
      get "/cached"
      expect(railwatch_records(:cache_event)).to be_empty
    end

    it "rejects by a literal Regexp" do
      Railwatch.reject_cache_keys([ /\Awidgets\// ])
      get "/cached"
      expect(railwatch_records(:cache_event)).to be_empty
    end

    it "does not treat a partial string as a prefix match" do
      Railwatch.reject_cache_keys([ "widgets/coun" ])
      get "/cached"
      expect(railwatch_records(:cache_event)).not_to be_empty
    end
  end
end
