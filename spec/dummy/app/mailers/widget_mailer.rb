class WidgetMailer < ActionMailer::Base
  default from: "nightrail@example.com"

  def notify(email)
    mail(to: email, subject: "Widget ready", body: "ready", content_type: "text/plain")
  end
end
