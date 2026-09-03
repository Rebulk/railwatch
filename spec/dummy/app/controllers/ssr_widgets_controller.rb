class SsrWidgetsController < ApplicationController
  include InertiaRails::Controller
  inertia_config ssr_enabled: true, ssr_url: "http://ssr.test", ssr_bundle: nil, layout: false, always_include_errors_hash: false

  def index
    render inertia: "Widgets/Index", props: { a: 1 }
  end
end
