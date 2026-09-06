class WidgetsController < ApplicationController
  nightrail_sample 0.0, only: :sampled

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
    request.env["nightrail.inertia_component"] = "widgets/index"
    response.set_header("X-Inertia", "true")
    render json: { component: "widgets/index", props: { a: 1 } }
  end

  def sampled
    render plain: "unsampled"
  end

  def ignored
    Nightrail.ignore { Widget.count }
    render plain: "ok"
  end

  def many
    @gadgets = Gadget.all
    render :many
  end

  def storage
    ActiveStorage::Current.url_options = { host: "example.com" }
    widget = Widget.first
    widget.photo.attach(io: StringIO.new("fake image bytes"), filename: "photo.png", content_type: "image/png")
    widget.photo.download
    widget.photo.url
    widget.photo.purge
    render plain: "ok"
  end

  def override_sample
    Nightrail.dont_sample if params[:mode] == "dont"
    Nightrail.sample(1.0) if params[:mode] == "on"
    Widget.count
    render plain: "ok"
  end

  def upload
    render plain: params[:attachment].original_filename
  end

  def deprecated_action
    old_widget_method
    render plain: "ok"
  end

  before_action :halt_it, only: :halted
  rate_limit to: 1, within: 1.minute, only: :rate_limited

  def redirected
    redirect_to "/widgets"
  end

  def redirected_with_credentials
    redirect_to "http://api-key:api-secret@www.example.com/widgets?password=secret&token=reset-token&code=oauth-code&X-Amz-Signature=signed-secret#private-fragment"
  end

  def halted
    render plain: "unreachable"
  end

  def unpermitted
    params.permit(:allowed)
    render plain: "ok"
  end

  def rate_limited
    render plain: "ok"
  end

  private

  # Rendering here (not throw(:abort)) is what halts the process_action
  # callback chain -- its terminator checks controller.performed?, it does
  # not catch :abort the way the default ActiveSupport::Callbacks terminator
  # does.
  def halt_it
    render plain: "halted", status: :forbidden
  end

  # Deprecation callstacks report the caller of the deprecated method, not
  # the method's own definition site, so this needs its own frame between
  # the controller action and Deprecation#warn to produce a real app :source.
  def old_widget_method
    deprecator = ActiveSupport::Deprecation.new("2.0", "Rails")
    deprecator.behavior = :notify
    deprecator.warn("old_widget_method is deprecated")
  end
end
