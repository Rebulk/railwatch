# frozen_string_literal: true

require "spec_helper"

# Railwatch's middleware runs in front of ActionDispatch::Static, so it sees
# every bundle and stylesheet public/ serves. Those are not requests anyone
# investigates; an unmatched 404 is, because a probe looks exactly like one.
RSpec.describe "static files", type: :request do
  ASSET = "/vite/assets/dist-DedfDSJv.js"

  it "does not record a bundle served from public/" do
    get ASSET

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("dist")
    expect(railwatch_records(:request)).to be_empty
  end

  it "does not record the 304 a browser revalidating that bundle gets" do
    get ASSET
    get ASSET, headers: { "If-Modified-Since" => response.headers["Last-Modified"] }

    expect(response).to have_http_status(:not_modified)
    expect(railwatch_records(:request)).to be_empty
  end

  # Vite's compression plugin can leave only app.js.br; Static serves it
  # for GET /app.js to a client that accepts Brotli.
  it "does not record a bundle Static serves from its precompressed copy alone" do
    get "/vite/assets/precompressed-Cq9mR2xT.js", headers: { "Accept-Encoding" => "br" }

    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Encoding"]).to eq("br")
    expect(railwatch_records(:request)).to be_empty
  end

  it "still records an unmatched path that is not a file, so a probe stays visible" do
    get "/vite/assets/.env"

    expect(response).to have_http_status(:not_found)
    expect(railwatch_records(:request).sole).to include(route: "unmatched", path: "/vite/assets/.env", status_code: 404)
  end

  it "still records a POST to a file's path, which Static does not serve" do
    post ASSET

    expect(railwatch_records(:request).sole).to include(method: "POST", route: "unmatched", status_code: 404)
  end

  it "still records a file request Static answered with an error" do
    get ASSET, headers: { "Range" => "bytes=9999-" }

    expect(response).to have_http_status(:range_not_satisfiable)
    expect(railwatch_records(:request).sole).to include(route: "unmatched", status_code: 416)
  end

  it "records a routed request as before, without looking in public/ for it" do
    allow(Rails).to receive(:public_path).and_call_original

    get "/widgets"

    expect(railwatch_records(:request).sole).to include(route: "/widgets(.:format)", status_code: 200)
    expect(Rails).not_to have_received(:public_path)
  end
end
