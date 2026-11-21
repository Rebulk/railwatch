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

  it "filters the capture beside literal text even when the token equals a literal word of the route" do
    get "/reset/prefix-reset"

    path = railwatch_records(:request).sole[:path]
    expect(path.split("/").last).to eq("[FILTERED]"), "the token, not only the literal it equals, is hidden"
    expect(path).not_to include("prefix-reset")
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

    # Cleaning a URL matches it against the app's routes. One beacon can name
    # 1,150 of them (a visit's, two per error, one per navigation crumb), and
    # the beacon takes no credential.
    describe "the work one beacon can ask for" do
      def recognitions
        count = 0
        allow(Rails.application.routes).to receive(:recognize_path).and_wrap_original do |original, *args, **options|
          count += 1
          original.call(*args, **options)
        end
        yield
        count
      end

      def beacon_of(urls)
        url = urls.each
        { visits: Array.new(50) { { component: "Passwords/Edit", url: url.next, method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1 } },
          errors: Array.new(50) do
            { name: "TypeError", message: "x is undefined", stack: "", url: url.next, visit: url.next,
              breadcrumbs: Array.new(20) { { kind: "navigate", text: "GET #{url.next}", at: 1 } } }
          end }
      end

      it "recognises a URL the beacon repeats only once" do
        count = recognitions { post_beacon(beacon_of([ "/passwords/#{token}/edit" ].cycle)) }

        expect(response).to have_http_status(:no_content)
        expect(count).to eq(1)
        expect(railwatch_records(:visit).map { |v| v[:url] }.uniq).to eq([ "/passwords/[FILTERED]/edit" ])
        crumbs = railwatch_records(:exception).flat_map { |ex| JSON.parse(ex[:context])["browser"]["breadcrumbs"] }
        expect(crumbs.size).to eq(1_000)
        expect(crumbs.map { |c| c["text"] }.uniq).to eq([ "GET /passwords/[FILTERED]/edit" ])
      end

      it "stops at a ceiling when every URL is different, and stores none of the rest as sent" do
        urls = (1..).lazy.map { |n| "/passwords/#{token}#{n}/edit" }
        count = recognitions { post_beacon(beacon_of(urls)) }

        expect(response).to have_http_status(:no_content)
        expect(count).to eq(Railwatch::BeaconController::MAX_URL_CLEANINGS)
        # Errors are read first, so they are the ones cleaned properly: the
        # first error's own URLs keep their shape, and everything after the
        # ceiling (the later errors, every visit) is masked whole.
        browsers = railwatch_records(:exception).map { |ex| JSON.parse(ex[:context])["browser"] }
        urls = railwatch_records(:visit).map { |v| v[:url] } + browsers.flat_map { |b| b.values_at("url", "visit") } +
          browsers.flat_map { |b| b["breadcrumbs"].map { |c| c["text"].delete_prefix("GET ") } }
        expect(urls.size).to eq(1_150)
        expect(urls.uniq).to contain_exactly("/passwords/[FILTERED]/edit", "[FILTERED]")
        expect(urls.count("/passwords/[FILTERED]/edit")).to eq(Railwatch::BeaconController::MAX_URL_CLEANINGS)
        expect(browsers.first.values_at("url", "visit")).to eq([ "/passwords/[FILTERED]/edit" ] * 2)
        expect(railwatch_records(:visit).map { |v| v[:url] }.uniq).to eq([ "[FILTERED]" ])
        expect((railwatch_records(:visit) + railwatch_records(:exception)).map(&:to_s).join).not_to include(token)
      end
    end
  end
end
