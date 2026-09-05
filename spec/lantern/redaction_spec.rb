# frozen_string_literal: true

require "spec_helper"

RSpec.describe "redaction and rejection", type: :request do
  before do
    Rails.cache.clear
    3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }
  end

  after do
    Lantern.config.redactors.clear
    Lantern.config.rejectors.clear
    Lantern.config.ignored_cache_key_prefixes.clear
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
      req = lantern_records(:request).sole
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

  describe "payload masking" do
    it "masks Rails filter_parameters fields in the payload, including nested hashes and arrays" do
      Lantern.config.capture_request_payload = true
      get "/boom", params: {
        secret_code: "shh",
        user: { ssn: "111-22-3333" },
        items: [ { secret_code: "x" }, { secret_code: "y" } ]
      }

      payload = lantern_records(:request).sole[:payload]
      expect(payload["secret_code"]).to eq("[FILTERED]")
      expect(payload["user"]["ssn"]).to eq("111-22-3333")
      expect(payload["items"].map { |i| i["secret_code"] }).to eq(%w[[FILTERED] [FILTERED]])
    ensure
      Lantern.config.capture_request_payload = false
    end

    it "omits the payload when capture_request_payload is off, even though the request raised" do
      Lantern.config.capture_request_payload = false
      get "/boom", params: { secret_code: "shh" }
      expect(lantern_records(:request).sole[:payload]).to be_nil
    end

    it "omits the payload when the request didn't raise, even with capture_request_payload on" do
      Lantern.config.capture_request_payload = true
      get "/widgets"
      expect(lantern_records(:request).sole[:payload]).to be_nil
    ensure
      Lantern.config.capture_request_payload = false
    end
  end

  describe "Lantern.redact_queries" do
    it "mutates the sql of the shipped query record" do
      Lantern.redact_queries { |rec| rec[:sql] = "REDACTED SQL" }
      get "/widgets"

      queries = lantern_records(:query)
      expect(queries).not_to be_empty
      expect(queries.map { |q| q[:sql] }.uniq).to eq([ "REDACTED SQL" ])
    end

    it "drops the record instead of shipping it when the redactor raises" do
      Lantern.redact_queries { |_rec| raise "boom in redactor" }
      get "/widgets"

      expect(lantern_records(:query)).to be_empty
      expect(lantern_records(:request)).not_to be_empty
    end
  end

  describe "Lantern.redact_requests / redact_exceptions / redact_commands" do
    it "runs the request redactor on the shipped request record" do
      Lantern.redact_requests { |rec| rec[:url] = "REDACTED URL" }
      get "/widgets"

      expect(lantern_records(:request).sole[:url]).to eq("REDACTED URL")
    end

    it "runs the exception redactor on the shipped exception record" do
      Lantern.redact_exceptions { |rec| rec[:message] = "REDACTED MESSAGE" }
      get "/boom"

      expect(lantern_records(:exception).sole[:message]).to eq("REDACTED MESSAGE")
    end

    it "runs the command redactor on the shipped command record" do
      require "rake"
      Lantern.redact_commands { |rec| rec[:command] = "REDACTED COMMAND" }
      Rake::Task.define_task(:lantern_redact_demo) { Widget.count }
      Rake::Task[:lantern_redact_demo].execute

      expect(lantern_records(:command).sole[:command]).to eq("REDACTED COMMAND")
    end
  end

  describe "reject_* hooks" do
    it "drops a query when reject_queries returns true for it" do
      Lantern.reject_queries { |rec| rec[:sql].to_s.include?("gadgets") }
      get "/widgets"

      queries = lantern_records(:query)
      expect(queries).not_to be_empty
      expect(queries.map { |q| q[:sql] }).to all(satisfy { |sql| !sql.include?("gadgets") })
    end

    it "drops a cache_event when reject_cache_events returns true for it" do
      Lantern.reject_cache_events { |rec| rec[:type] == "hit" }
      get "/cached"

      types = lantern_records(:cache_event).map { |e| e[:type] }
      expect(types).not_to include("hit")
      expect(types).to include("write")
    end

    it "drops an outgoing_request when reject_outgoing_requests returns true for it" do
      Lantern.reject_outgoing_requests { |rec| rec[:host] == "example.test" }
      get "/outbound"

      expect(lantern_records(:outgoing_request)).to be_empty
    end
  end

  describe "Lantern.reject_cache_keys" do
    it "rejects an exact string match" do
      Lantern.reject_cache_keys([ "widgets/count" ])
      get "/cached"
      expect(lantern_records(:cache_event)).to be_empty
    end

    it "rejects by a trailing-star prefix" do
      Lantern.reject_cache_keys([ "widgets/*" ])
      get "/cached"
      expect(lantern_records(:cache_event)).to be_empty
    end

    it "rejects by a leading-caret regexp string" do
      Lantern.reject_cache_keys([ "^widgets/" ])
      get "/cached"
      expect(lantern_records(:cache_event)).to be_empty
    end

    it "rejects by a literal Regexp" do
      Lantern.reject_cache_keys([ /\Awidgets\// ])
      get "/cached"
      expect(lantern_records(:cache_event)).to be_empty
    end

    it "does not treat a partial string as a prefix match" do
      Lantern.reject_cache_keys([ "widgets/coun" ])
      get "/cached"
      expect(lantern_records(:cache_event)).not_to be_empty
    end
  end
end
