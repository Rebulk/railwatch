# frozen_string_literal: true

require "spec_helper"

# A reset, invite or magic-link token that is a route segment, not a query
# parameter, as Rails 8's authentication generator writes it
# (`resources :passwords, param: :token` => /passwords/:token/edit).
RSpec.describe "secrets in the request path", type: :request do
  let(:token) { "RESET_TOKEN_SECRET_abc123" }

  it "never stores a password-reset token from the path in the request's path or url" do
    get "/passwords/#{token}/edit"

    req = railwatch_records(:request).sole
    expect(req[:path]).to eq("/passwords/[FILTERED]/edit")
    expect(req[:url]).to eq("http://www.example.com/passwords/[FILTERED]/edit")
    expect(req[:route]).to eq("/passwords/:token/edit(.:format)")
    expect(req.to_s).not_to include(token)
  end

  it "filters the token on the update the reset form submits, format suffix kept" do
    patch "/passwords/#{token}.json"

    req = railwatch_records(:request).sole
    expect(req[:path]).to eq("/passwords/[FILTERED].json")
  end

  it "filters a percent-encoded token" do
    get "/passwords/a%2Bb%20c/edit"

    expect(railwatch_records(:request).sole[:path]).to eq("/passwords/[FILTERED]/edit")
  end

  it "filters any segment whose name is credential-shaped, an invite code too" do
    get "/invitations/INVITE_CODE_123/accept"

    expect(railwatch_records(:request).sole[:path]).to eq("/invitations/[FILTERED]/accept")
  end

  it "filters a segment the app's filter_parameters names" do
    get "/widgets/#{Widget.create!(name: 'w', gadget: Gadget.create!(name: 'g')).id}"
    expect(railwatch_records(:request).last[:path]).to match(%r{\A/widgets/\d+\z}), "an :id is not a secret"

    Rails.application.config.filter_parameters << :id
    Railwatch.instance_variable_set(:@redactor, nil)
    get "/widgets/1"
    expect(railwatch_records(:request).last[:path]).to eq("/widgets/[FILTERED]")
  ensure
    Rails.application.config.filter_parameters.delete(:id)
    Railwatch.instance_variable_set(:@redactor, nil)
  end

  it "filters the token when the request raised and the exceptions app rendered it" do
    get "/reset_boom/#{token}"

    req = railwatch_records(:request).sole
    expect(req[:status_code]).to eq(500)
    expect(req[:path]).to eq("/reset_boom/[FILTERED]")
    expect(req[:url]).not_to include(token)
  end

  it "filters the token of a request no route answered for its verb, which still lands in the 404 log" do
    delete "/passwords/#{token}/edit"

    req = railwatch_records(:request).sole
    expect(req[:status_code]).to eq(404)
    expect(req[:path]).to eq("/passwords/[FILTERED]/edit")
  end

  it "leaves ordinary paths alone, including one shaped like a token route that names another" do
    expect(Railwatch.redactor.filter_url("/widgets/42")).to eq("/widgets/42")
    expect(Railwatch.redactor.filter_url("/passwords/new")).to eq("/passwords/new"), "GET /passwords/new is #new, not #update"
  end

  it "filters a path no route takes for the method but a token route has the shape of" do
    expect(Railwatch.redactor.filter_url("/passwords/RESET_TOKEN_abc", method: "GET")).to eq("/passwords/[FILTERED]")
  end

  it "filters the token from a redirect to the app's own reset page" do
    get "/redirect_to_reset"

    expect(railwatch_records(:request).sole[:redirect_to]).to eq("http://www.example.com/passwords/[FILTERED]/edit")
  end

  it "leaves a redirect to another site's path alone, which this app's routes cannot describe" do
    expect(Railwatch.redactor.filter_url("https://elsewhere.example/passwords/abc/edit", host: "www.example.com"))
      .to eq("https://elsewhere.example/passwords/abc/edit")
  end

  it "filters the token from a Referer that is the app's reset page" do
    get "/widgets", headers: { "Referer" => "http://www.example.com/passwords/#{token}/edit" }

    expect(railwatch_records(:request).sole[:headers]["Referer"]).to eq("http://www.example.com/passwords/[FILTERED]/edit")
  end

  # PR #169 review follow-ups.
  it "recognises a 307 redirect target with the request's own method, which the browser keeps" do
    post "/redirect_to_reset_preserving"

    req = railwatch_records(:request).sole
    expect(req[:status_code]).to eq(307)
    expect(req[:redirect_to]).to eq("http://www.example.com/resets/[FILTERED]")
  end

  it "filters a glob token however its characters, slashes included, are percent-encoded" do
    expect(Railwatch.redactor.filter_url("/files/a/b")).to eq("/files/[FILTERED]")
    expect(Railwatch.redactor.filter_url("/files/%61/b")).to eq("/files/[FILTERED]")
    expect(Railwatch.redactor.filter_url("/files/a%2Fb")).to eq("/files/[FILTERED]")

    get "/files/%61/b"
    expect(railwatch_records(:request).sole[:path]).to eq("/files/[FILTERED]")
  end

  it "filters a token in a URL with a trailing slash, which the router ignores" do
    expect(Railwatch.redactor.filter_url("/passwords/#{token}/edit/")).to eq("/passwords/[FILTERED]/edit/")
    expect(Railwatch.redactor.filter_url("/passwords/#{token}/edit")).to eq("/passwords/[FILTERED]/edit")
  end

  it "recognises a URL on its own host, so a token route constrained to that host is the one picked" do
    expect(Railwatch.redactor.filter_url("https://auth.example.com/magic/MAGIC_TOKEN/edit", host: "auth.example.com"))
      .to eq("https://auth.example.com/magic/[FILTERED]/edit")
    expect(Railwatch.redactor.filter_url("/magic/42/edit", host: "www.example.com")).to eq("/magic/42/edit"),
      "on another host the ordinary sibling route is the one, and its :id is kept"

    host! "auth.example.com"
    get "/widgets", headers: { "Referer" => "https://auth.example.com/magic/MAGIC_TOKEN/edit" }
    expect(railwatch_records(:request).sole[:headers]["Referer"]).to eq("https://auth.example.com/magic/[FILTERED]/edit")
  end

  it "filters a token captured beside literal text in its segment" do
    get "/reset/prefix-PREFIXED_SECRET"

    req = railwatch_records(:request).sole
    expect(req[:path]).to eq("/reset/[FILTERED]")
    expect(req.to_s).not_to include("PREFIXED_SECRET")
    expect(Railwatch.redactor.filter_url("http://www.example.com/reset/prefix-PREFIXED_SECRET", host: "www.example.com"))
      .to eq("http://www.example.com/reset/[FILTERED]")
  end

  describe "beacon URLs, which the browser sends without knowing the routes" do
    def post_beacon(payload)
      post "/railwatch/beacon", params: payload.to_json, headers: { "Content-Type" => "application/json" }
    end

    it "filters the token from a visit's url" do
      post_beacon(visits: [ { component: "Passwords/Edit", url: "/passwords/#{token}/edit", method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1 } ])

      expect(railwatch_records(:visit).sole[:url]).to eq("/passwords/[FILTERED]/edit")
    end

    it "filters the token from a visit's absolute url on this app, recognised by the visit's method" do
      post_beacon(visits: [ { component: "Passwords/Edit", url: "http://www.example.com/passwords/#{token}", method: "patch", started_at: Time.now.to_f * 1000, duration_ms: 1 } ])

      expect(railwatch_records(:visit).sole[:url]).to eq("http://www.example.com/passwords/[FILTERED]")
    end

    it "filters the token from an error's page url, visit and navigation breadcrumbs" do
      post_beacon(errors: [ {
        name: "TypeError", message: "x is undefined", stack: "",
        url: "/passwords/#{token}/edit", visit: "/passwords/#{token}/edit",
        breadcrumbs: [ { kind: "navigate", text: "GET /passwords/#{token}/edit", at: 1 } ]
      } ])

      ex = railwatch_records(:exception).sole
      browser = JSON.parse(ex[:context])["browser"]
      expect(browser["url"]).to eq("/passwords/[FILTERED]/edit")
      expect(browser["visit"]).to eq("/passwords/[FILTERED]/edit")
      expect(browser["breadcrumbs"].map { |c| c["text"] }).to eq([ "GET /passwords/[FILTERED]/edit" ])
      expect(ex.to_s).not_to include(token)
    end
  end
end
