class WidgetMailer < ActionMailer::Base
  default from: "railwatch@example.com"

  def notify(email)
    mail(to: email, subject: "Widget ready", body: "ready", content_type: "text/plain")
  end
end
