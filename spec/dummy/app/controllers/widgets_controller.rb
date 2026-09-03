class WidgetsController < ApplicationController
  lantern_sample 0.0, only: :sampled

  def index
    # N+1 on purpose: each widget loads its gadget.
    names = Widget.all.map { |w| w.gadget&.name }
    Rails.logger.info("listed #{names.size} widgets")
    render plain: names.join(",")
  end

  def show
    render plain: Widget.find(params[:id]).name
  end

  def boom
    raise ArgumentError, "kaboom"
  end

  def handled
    Rails.error.handle(context: { section: "handled" }) { raise "swallowed" }
    render plain: "ok"
  end

  def cached
    Rails.cache.fetch("widgets/count") { Widget.count }
    Rails.cache.fetch("widgets/count") { Widget.count }
    Rails.cache.write("rack::attack:1", 1)
    render plain: "ok"
  end

  def outbound
    Net::HTTP.get_response(URI("http://example.test/api/v1/things?x=1"))
    render plain: "ok"
  end

  def mail
    WidgetMailer.notify("a@example.com").deliver_now
    render plain: "ok"
  end

  def enqueue
    WidgetJob.perform_later("hello")
    render plain: "ok"
  end

  def inertia
    request.env["lantern.inertia_component"] = "widgets/index"
    response.set_header("X-Inertia", "true")
    render json: { component: "widgets/index", props: { a: 1 } }
  end

  def sampled
    render plain: "unsampled"
  end

  def ignored
    Lantern.ignore { Widget.count }
    render plain: "ok"
  end
end
